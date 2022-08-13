{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Transport.Client
  ( runTransportClient,
    runTLSTransportClient,
    smpClientHandshake,
    defaultSMPPort,
    defaultSocksProxy,
    SocksProxy,
    TransportHost (..),
    TransportHosts (..),
    TransportHosts_ (..),
  )
where

import Control.Applicative (optional)
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Default (def)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import Data.Maybe (fromMaybe)
import Data.String
import Data.Word (Word8)
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
import Simplex.Messaging.Util (bshow, (<$?>))
import System.IO.Error
import Text.Read (readMaybe)
import UnliftIO.Exception (IOException)
import qualified UnliftIO.Exception as E

data TransportHost
  = THIPv4 (Word8, Word8, Word8, Word8)
  | THOnionHost ByteString
  | THDomainName HostName
  deriving (Eq, Ord, Show)

instance Encoding TransportHost where
  smpEncode = smpEncode . strEncode
  smpP = parseAll strP <$?> smpP

instance StrEncoding TransportHost where
  strEncode = \case
    THIPv4 (a1, a2, a3, a4) -> B.intercalate "." $ map bshow [a1, a2, a3, a4]
    THOnionHost host -> host
    THDomainName host -> B.pack host
  strP =
    A.choice
      [ THIPv4 <$> ((,,,) <$> ipNum <*> ipNum <*> ipNum <*> A.decimal),
        THOnionHost <$> ((<>) <$> A.takeTill (== '.') <*> A.string ".onion"),
        THDomainName . B.unpack <$> A.takeWhile1 (A.notInClass ":#,;/ ")
      ]
    where
      ipNum = A.decimal <* A.char '.'

instance ToJSON TransportHost where
  toEncoding = strToJEncoding
  toJSON = strToJSON

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

-- | Connect to passed TCP host:port and pass handle to the client.
runTransportClient :: (Transport c, MonadUnliftIO m) => Maybe SocksProxy -> TransportHost -> ServiceName -> Maybe C.KeyHash -> Maybe KeepAliveOpts -> (c -> m a) -> m a
runTransportClient = runTLSTransportClient supportedParameters Nothing

runTLSTransportClient :: (Transport c, MonadUnliftIO m) => T.Supported -> Maybe XS.CertificateStore -> Maybe SocksProxy -> TransportHost -> ServiceName -> Maybe C.KeyHash -> Maybe KeepAliveOpts -> (c -> m a) -> m a
runTLSTransportClient tlsParams caStore_ socksProxy_ host port keyHash keepAliveOpts client = do
  let clientParams = mkTLSClientParams tlsParams caStore_ (B.unpack $ strEncode host) port keyHash
      connectTCP = case socksProxy_ of
        Just proxy -> connectSocksClient proxy $ hostAddr host
        _ -> connectTCPClient . B.unpack $ strEncode host
  c <- liftIO $ do
    sock <- connectTCP port
    mapM_ (setSocketKeepAlive sock) keepAliveOpts
    connectTLS clientParams sock >>= getClientConnection
  client c `E.finally` liftIO (closeConnection c)
  where
    hostAddr = \case
      THIPv4 addr -> SocksAddrIPV4 $ tupleToHostAddress addr
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
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      connect sock $ addrAddress addr
      pure sock

defaultSMPPort :: PortNumber
defaultSMPPort = 5223

connectSocksClient :: SocksProxy -> SocksHostAddress -> ServiceName -> IO Socket
connectSocksClient (SocksProxy addr) hostAddr _port = do
  let port = if null _port then defaultSMPPort else fromMaybe defaultSMPPort $ readMaybe _port
  fst <$> socksConnect (defaultSocksConf addr) (SocksAddress hostAddr port)

defaultSocksHost :: HostAddress
defaultSocksHost = tupleToHostAddress (127, 0, 0, 1)

defaultSocksProxy :: SocksProxy
defaultSocksProxy = SocksProxy $ SockAddrInet 9050 defaultSocksHost

newtype SocksProxy = SocksProxy SockAddr
  deriving (Eq)

instance Show SocksProxy where show (SocksProxy addr) = show addr

instance StrEncoding SocksProxy where
  strEncode = B.pack . show
  strP = do
    host <- maybe defaultSocksHost tupleToHostAddress <$> optional ipv4P
    port <- fromMaybe 9050 <$> optional (A.char ':' *> (fromInteger <$> A.decimal))
    pure . SocksProxy $ SockAddrInet port host
    where
      ipv4P = (,,,) <$> ipNum <*> ipNum <*> ipNum <*> A.decimal
      ipNum = A.decimal <* A.char '.'

instance ToJSON SocksProxy where
  toJSON = strToJSON
  toEncoding = strToJEncoding

instance FromJSON SocksProxy where
  parseJSON = strParseJSON "SocksProxy"

mkTLSClientParams :: T.Supported -> Maybe XS.CertificateStore -> HostName -> ServiceName -> Maybe C.KeyHash -> T.ClientParams
mkTLSClientParams supported caStore_ host port keyHash_ = do
  let p = B.pack port
  (T.defaultParamsClient host p)
    { T.clientShared = maybe def (\caStore -> def {T.sharedCAStore = caStore}) caStore_,
      T.clientHooks = maybe def (\keyHash -> def {T.onServerCertificate = \_ _ _ -> validateCertificateChain keyHash host p}) keyHash_,
      T.clientSupported = supported
    }

validateCertificateChain :: C.KeyHash -> HostName -> ByteString -> X.CertificateChain -> IO [XV.FailedReason]
validateCertificateChain _ _ _ (X.CertificateChain []) = pure [XV.EmptyChain]
validateCertificateChain _ _ _ (X.CertificateChain [_]) = pure [XV.EmptyChain]
validateCertificateChain (C.KeyHash kh) host port cc@(X.CertificateChain sc@[_, caCert]) =
  if Fingerprint kh == XV.getFingerprint caCert X.HashSHA256
    then x509validate
    else pure [XV.UnknownCA]
  where
    x509validate :: IO [XV.FailedReason]
    x509validate = XV.validate X.HashSHA256 hooks checks certStore cache serviceID cc
      where
        hooks = XV.defaultHooks
        checks = XV.defaultChecks {XV.checkFQHN = False}
        certStore = XS.makeCertificateStore sc
        cache = XV.exceptionValidationCache [] -- we manually check fingerprint only of the identity certificate (ca.crt)
        serviceID = (host, port)
validateCertificateChain _ _ _ _ = pure [XV.AuthorityTooDeep]
