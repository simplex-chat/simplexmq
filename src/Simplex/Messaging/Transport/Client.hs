{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Transport.Client
  ( runTransportClient,
    runTLSTransportClient,
    smpClientHandshake,
    defaultSMPPort,
    defaultTcpConnectTimeout,
    defaultTransportClientConfig,
    defaultSocksProxyWithAuth,
    defaultSocksProxy,
    defaultSocksHost,
    TransportClientConfig (..),
    SocksProxy (..),
    SocksProxyWithAuth (..),
    SocksAuth (..),
    TransportHost (..),
    TransportHosts (..),
    TransportHosts_ (..),
    validateCertificateChain,
  )
where

import Control.Applicative (optional, (<|>))
import Control.Logger.Simple (logError)
import Control.Monad
import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isAsciiLower, isDigit, isHexDigit)
import Data.Default (def)
import Data.Functor (($>))
import Data.IORef
import Data.IP
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import Data.Maybe (fromMaybe)
import Data.String
import Data.Word (Word32, Word8)
import qualified Data.X509 as X
import qualified Data.X509.CertificateStore as XS
import Data.X509.Validation (Fingerprint (..))
import qualified Data.X509.Validation as XV
import GHC.IO.Exception (IOErrorType (..))
import Network.Socket
import Network.Socks5
import qualified Network.TLS as T
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (parseAll, parseString)
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.KeepAlive
import Simplex.Messaging.Transport.Shared
import Simplex.Messaging.Util (bshow, catchAll, catchAll_, tshow, (<$?>))
import System.IO.Error
import Text.Read (readMaybe)
import UnliftIO.Exception (IOException)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

data TransportHost
  = THIPv4 (Word8, Word8, Word8, Word8)
  | THIPv6 (Word32, Word32, Word32, Word32)
  | THOnionHost ByteString
  | THDomainName HostName
  deriving (Eq, Ord, Show)

instance Encoding TransportHost where
  smpEncode = smpEncode . strEncode
  smpP = parseAll strP <$?> smpP

instance StrEncoding TransportHost where
  strEncode = \case
    THIPv4 (a1, a2, a3, a4) -> B.intercalate "." $ map bshow [a1, a2, a3, a4]
    THIPv6 addr -> bshow $ toIPv6w addr
    THOnionHost host -> host
    THDomainName host -> B.pack host
  strP =
    A.choice
      [ THIPv4 <$> ((,,,) <$> ipNum <*> ipNum <*> ipNum <*> A.decimal),
        maybe (Left "bad IPv6") (Right . THIPv6 . fromIPv6w) . readMaybe . B.unpack <$?> ipv6StrP,
        THOnionHost <$> ((<>) <$> A.takeWhile (\c -> isAsciiLower c || isDigit c) <*> A.string ".onion"),
        THDomainName . B.unpack <$> (notOnion <$?> A.takeWhile1 (A.notInClass ":#,;/ \n\r\t"))
      ]
    where
      ipNum = validIP <$?> (A.decimal <* A.char '.')
      validIP :: Int -> Either String Word8
      validIP n = if 0 <= n && n <= 255 then Right $ fromIntegral n else Left "invalid IP address"
      ipv6StrP =
        A.char '[' *> A.takeWhile1 (/= ']') <* A.char ']'
          <|> A.takeWhile1 (\c -> isHexDigit c || c == ':')
      notOnion s = if ".onion" `B.isSuffixOf` s then Left "invalid onion host" else Right s

instance ToJSON TransportHost where
  toEncoding = strToJEncoding
  toJSON = strToJSON

instance FromJSON TransportHost where
  parseJSON = strParseJSON "TransportHost"

newtype TransportHosts = TransportHosts {thList :: NonEmpty TransportHost}

instance StrEncoding TransportHosts where
  strEncode = strEncodeList . L.toList . thList
  strP = TransportHosts . L.fromList <$> strP `A.sepBy1'` A.char ','

newtype TransportHosts_ = TransportHosts_ {thList_ :: [TransportHost]}

instance StrEncoding TransportHosts_ where
  strEncode = strEncodeList . thList_
  strP = TransportHosts_ <$> strP `A.sepBy'` A.char ','

instance IsString TransportHost where fromString = parseString strDecode

instance IsString (NonEmpty TransportHost) where fromString = parseString strDecode

data TransportClientConfig = TransportClientConfig
  { socksProxy :: Maybe SocksProxy,
    tcpConnectTimeout :: Int,
    tcpKeepAlive :: Maybe KeepAliveOpts,
    logTLSErrors :: Bool,
    clientCredentials :: Maybe T.Credential,
    clientALPN :: Maybe [ALPN],
    useSNI :: Bool
  }
  deriving (Eq, Show)

-- time to resolve host, connect socket, set up TLS
defaultTcpConnectTimeout :: Int
defaultTcpConnectTimeout = 25_000_000

defaultTransportClientConfig :: TransportClientConfig
defaultTransportClientConfig =
  TransportClientConfig
    { socksProxy = Nothing,
      tcpConnectTimeout = defaultTcpConnectTimeout,
      tcpKeepAlive = Just defaultKeepAliveOpts,
      logTLSErrors = True,
      clientCredentials = Nothing,
      clientALPN = Nothing,
      useSNI = True
    }

clientTransportConfig :: TransportClientConfig -> TransportConfig
clientTransportConfig TransportClientConfig {logTLSErrors} =
  TransportConfig {logTLSErrors, transportTimeout = Nothing}

-- | Connect to passed TCP host:port and pass handle to the client.
runTransportClient :: Transport c => TransportClientConfig -> Maybe SocksCredentials -> TransportHost -> ServiceName -> Maybe C.KeyHash -> (c 'TClient -> IO a) -> IO a
runTransportClient = runTLSTransportClient defaultSupportedParams Nothing

data ConnectionHandle c
  = CHSocket Socket
  | CHContext T.Context
  | CHTransport (c 'TClient)

runTLSTransportClient :: Transport c => T.Supported -> Maybe XS.CertificateStore -> TransportClientConfig -> Maybe SocksCredentials -> TransportHost -> ServiceName -> Maybe C.KeyHash -> (c 'TClient -> IO a) -> IO a
runTLSTransportClient tlsParams caStore_ cfg@TransportClientConfig {socksProxy, tcpKeepAlive, clientCredentials, clientALPN, useSNI} socksCreds host port keyHash client = do
  serverCert <- newEmptyTMVarIO
  clientCredsSent <- newIORef False
  let hostName = B.unpack $ strEncode host
      clientParams = mkTLSClientParams tlsParams caStore_ hostName port keyHash clientCredentials clientCredsSent clientALPN useSNI serverCert
      connectTCP = case socksProxy of
        Just proxy -> connectSocksClient proxy socksCreds (hostAddr host)
        _ -> connectTCPClient hostName
  h <- newIORef Nothing
  let set hc = (>>= \c -> writeIORef h (Just $ hc c) $> c)
  E.bracket (set CHSocket $ connectTCP port) (\_ -> closeConn h) $ \sock -> do
    mapM_ (setSocketKeepAlive sock) tcpKeepAlive `catchAll` \e -> logError ("Error setting TCP keep-alive " <> tshow e)
    let tCfg = clientTransportConfig cfg
    -- No TLS timeout to avoid failing connections via SOCKS
    tls <- set CHContext $ connectTLS (Just hostName) tCfg clientParams sock
    chain <- takePeerCertChain serverCert
    sent <- readIORef clientCredsSent
    client =<< set CHTransport (getTransportConnection tCfg sent chain tls)
  where
    closeConn = readIORef >=> mapM_ (\c -> E.uninterruptibleMask_ $ closeConn_ c `catchAll_` pure ())
    closeConn_ = \case
      CHSocket sock -> close sock
      CHContext tls -> closeTLS tls
      CHTransport c -> closeConnection c
    hostAddr = \case
      THIPv4 addr -> SocksAddrIPV4 $ tupleToHostAddress addr
      THIPv6 addr -> SocksAddrIPV6 addr
      THOnionHost h -> SocksAddrDomainName h
      THDomainName h -> SocksAddrDomainName $ B.pack h

connectTCPClient :: HostName -> ServiceName -> IO Socket
connectTCPClient host port = withSocketsDo $ resolve >>= tryOpen err
  where
    err :: IOException
    err = mkIOError NoSuchThing "no address" Nothing Nothing

    resolve :: IO [AddrInfo]
    resolve =
      let hints = defaultHints {addrSocketType = Stream}
       in getAddrInfo (Just hints) (Just host) (Just port)

    tryOpen :: IOException -> [AddrInfo] -> IO Socket
    tryOpen e [] = E.throwIO e
    tryOpen _ (addr : as) =
      E.try (open addr) >>= either (`tryOpen` as) pure

    open :: AddrInfo -> IO Socket
    open addr =
      E.bracketOnError
        (socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr))
        close
        (\sock -> connect sock (addrAddress addr) $> sock)

defaultSMPPort :: PortNumber
defaultSMPPort = 5223

connectSocksClient :: SocksProxy -> Maybe SocksCredentials -> SocksHostAddress -> ServiceName -> IO Socket
connectSocksClient (SocksProxy addr) socksCreds hostAddr _port = do
  let port = if null _port then defaultSMPPort else fromMaybe defaultSMPPort $ readMaybe _port
  fst <$> case socksCreds of
    Just creds -> socksConnectAuth (defaultSocksConf addr) (SocksAddress hostAddr port) creds
    _ -> socksConnect (defaultSocksConf addr) (SocksAddress hostAddr port)

defaultSocksHost :: (Word8, Word8, Word8, Word8)
defaultSocksHost = (127, 0, 0, 1)

defaultSocksProxyWithAuth :: SocksProxyWithAuth
defaultSocksProxyWithAuth = SocksProxyWithAuth SocksIsolateByAuth defaultSocksProxy

defaultSocksProxy :: SocksProxy
defaultSocksProxy = SocksProxy $ SockAddrInet 9050 $ tupleToHostAddress defaultSocksHost

newtype SocksProxy = SocksProxy SockAddr
  deriving (Eq)

data SocksProxyWithAuth = SocksProxyWithAuth SocksAuth SocksProxy
  deriving (Eq, Show)

data SocksAuth
  = SocksAuthUsername {username :: ByteString, password :: ByteString}
  | SocksAuthNull
  | SocksIsolateByAuth -- this is default
  deriving (Eq, Show)

instance Show SocksProxy where show (SocksProxy addr) = show addr

instance StrEncoding SocksProxy where
  strEncode = B.pack . show
  strP = do
    host <- fromMaybe (THIPv4 defaultSocksHost) <$> optional strP
    port <- fromMaybe 9050 <$> optional (A.char ':' *> (fromInteger <$> A.decimal))
    SocksProxy <$> socksAddr port host
    where
      socksAddr port = \case
        THIPv4 addr -> pure $ SockAddrInet port $ tupleToHostAddress addr
        THIPv6 addr -> pure $ SockAddrInet6 port 0 addr 0
        _ -> fail "SOCKS5 host should be IPv4 or IPv6 address"

instance StrEncoding SocksProxyWithAuth where
  strEncode (SocksProxyWithAuth auth proxy) = strEncode auth <> strEncode proxy
  strP = SocksProxyWithAuth <$> strP <*> strP

instance ToJSON SocksProxyWithAuth where
  toJSON = strToJSON
  toEncoding = strToJEncoding

instance FromJSON SocksProxyWithAuth where
  parseJSON = strParseJSON "SocksProxyWithAuth"

instance StrEncoding SocksAuth where
  strEncode = \case
    SocksAuthUsername {username, password} -> username <> ":" <> password <> "@"
    SocksAuthNull -> "@"
    SocksIsolateByAuth -> ""
  strP = usernameP <|> (SocksAuthNull <$ A.char '@') <|> pure SocksIsolateByAuth
    where
      usernameP = do
        username <- A.takeTill (== ':') <* A.char ':'
        password <- A.takeTill (== '@') <* A.char '@'
        pure SocksAuthUsername {username, password}

mkTLSClientParams :: T.Supported -> Maybe XS.CertificateStore -> HostName -> ServiceName -> Maybe C.KeyHash -> Maybe T.Credential -> IORef Bool -> Maybe [ALPN] -> Bool -> TMVar (Maybe X.CertificateChain) -> T.ClientParams
mkTLSClientParams supported caStore_ host port cafp_ clientCreds_ clientCredsSent alpn_ sni serverCerts =
  (T.defaultParamsClient host p)
    { T.clientUseServerNameIndication = sni,
      T.clientShared = def {T.sharedCAStore = fromMaybe (T.sharedCAStore def) caStore_},
      T.clientHooks =
        def
          { T.onServerCertificate = onServerCert,
            T.onCertificateRequest = onCertRequest,
            T.onSuggestALPN = pure alpn_
          },
      T.clientSupported = supported
    }
  where
    p = B.pack port
    onServerCert _ _ _ cc = do
      errs <- maybe def (\ca -> validateCertificateChain ca host p cc) cafp_
      atomically $ putTMVar serverCerts $ if null errs then Just cc else Nothing
      pure errs
    onCertRequest = case clientCreds_ of
      Just _ -> \_ -> clientCreds_ <$ writeIORef clientCredsSent True
      Nothing -> \_ -> pure Nothing

validateCertificateChain :: C.KeyHash -> HostName -> ByteString -> X.CertificateChain -> IO [XV.FailedReason]
validateCertificateChain (C.KeyHash kh) host port cc = case chainIdCaCerts cc of
  CCEmpty -> pure [XV.EmptyChain]
  CCSelf _ -> pure [XV.EmptyChain]
  CCValid {idCert, caCert} -> validate idCert caCert
  CCLong -> pure [XV.AuthorityTooDeep]
  where
    validate idCert caCert
      | Fingerprint kh == XV.getFingerprint idCert X.HashSHA256 = x509validate caCert (host, port) cc
      | otherwise = pure [XV.UnknownCA]
