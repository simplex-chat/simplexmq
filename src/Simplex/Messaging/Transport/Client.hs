{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Transport.Client
  ( TransportHost (..),
    TransportHosts (..),
    runTransportClient,
    runTLSTransportClient,
    smpClientHandshake,
    defaultSMPPort,
  )
where

import Control.Monad.Except
import Control.Monad.IO.Unlift
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

data TransportHost = THDomainName HostName | THIPv4 (Word8, Word8, Word8, Word8) | THViaSocks OnionHost
  deriving (Eq, Ord, Show)

newtype OnionHost = OnionHost ByteString
  deriving (Eq, Ord, Show)

instance Encoding TransportHost where
  smpEncode = smpEncode . strEncode
  smpP = parseAll strP <$?> smpP

instance StrEncoding TransportHost where
  strEncode = \case
    THIPv4 (a1, a2, a3, a4) -> B.intercalate "." $ map bshow [a1, a2, a3, a4]
    THViaSocks (OnionHost host) -> host
    THDomainName host -> B.pack host
  strP =
    A.choice
      [ THIPv4 <$> ((,,,) <$> ipNum <*> ipNum <*> ipNum <*> A.decimal),
        THViaSocks . OnionHost <$> ((<>) <$> A.takeTill (== '.') <*> A.string ".onion"),
        THDomainName . B.unpack <$> A.takeWhile1 (A.notInClass ":#,;/ ")
      ]
    where
      ipNum = A.decimal <* A.char '.'

newtype TransportHosts = TransportHosts {thList :: NonEmpty TransportHost}

instance StrEncoding TransportHosts where
  strEncode = strEncodeList . L.toList . thList
  strP = TransportHosts . L.fromList <$> strP `A.sepBy1'` A.char ','

instance IsString TransportHost where fromString = parseString strDecode

instance IsString (NonEmpty TransportHost) where fromString = parseString strDecode

-- | Connect to passed TCP host:port and pass handle to the client.
runTransportClient :: (Transport c, MonadUnliftIO m) => Maybe SocksConf -> NonEmpty TransportHost -> ServiceName -> Maybe C.KeyHash -> Maybe KeepAliveOpts -> (c -> m a) -> m a
runTransportClient = runTLSTransportClient supportedParameters Nothing

runTLSTransportClient :: (Transport c, MonadUnliftIO m) => T.Supported -> Maybe XS.CertificateStore -> Maybe SocksConf -> NonEmpty TransportHost -> ServiceName -> Maybe C.KeyHash -> Maybe KeepAliveOpts -> (c -> m a) -> m a
runTLSTransportClient tlsParams caStore_ socksConf_ (pHost :| _) port keyHash keepAliveOpts client = do
  let clientParams = mkTLSClientParams tlsParams caStore_ hostName port keyHash
      connectTCP = maybe (connectTCPClient hostName) (`connectSocksClient` hostAddr) socksConf_
  c <- liftIO $ do
    sock <- connectTCP port
    connectTLSClient sock clientParams keepAliveOpts
  client c `E.finally` liftIO (closeConnection c)
  where
    hostName = B.unpack $ strEncode pHost
    hostAddr = case pHost of
      THViaSocks (OnionHost host) -> SocksAddrDomainName host
      THDomainName host -> SocksAddrDomainName $ B.pack host
      THIPv4 addr -> SocksAddrIPV4 $ tupleToHostAddress addr

connectTLSClient :: forall c. Transport c => Socket -> T.ClientParams -> Maybe KeepAliveOpts -> IO c
connectTLSClient sock clientParams keepAliveOpts = do
  mapM_ (setSocketKeepAlive sock) keepAliveOpts
  ctx <- connectTLS clientParams sock
  getClientConnection ctx

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

connectSocksClient :: SocksConf -> SocksHostAddress -> ServiceName -> IO Socket
connectSocksClient socksProxy hostAddr _port = do
  let port = if null _port then defaultSMPPort else fromMaybe defaultSMPPort $ readMaybe _port
  fst <$> socksConnect socksProxy (SocksAddress hostAddr port)

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
