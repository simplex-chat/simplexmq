{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Transport.Client
  ( runTransportClient,
    clientHandshake,
  )
where

import Control.Monad.Except
import Control.Monad.IO.Unlift
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Default (def)
import qualified Data.X509 as X
import qualified Data.X509.CertificateStore as XS
import Data.X509.Validation (Fingerprint (..))
import qualified Data.X509.Validation as XV
import GHC.IO.Exception (IOErrorType (..))
import Network.Socket
import qualified Network.TLS as T
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Transport
import System.IO.Error
import UnliftIO.Exception (IOException)
import qualified UnliftIO.Exception as E

-- | Connect to passed TCP host:port and pass handle to the client.
runTransportClient :: Transport c => MonadUnliftIO m => HostName -> ServiceName -> C.KeyHash -> (c -> m a) -> m a
runTransportClient host port keyHash client = do
  let clientParams = mkTLSClientParams host port keyHash
  c <- liftIO $ startTCPClient host port clientParams
  client c `E.finally` liftIO (closeConnection c)

startTCPClient :: forall c. Transport c => HostName -> ServiceName -> T.ClientParams -> IO c
startTCPClient host port clientParams = withSocketsDo $ resolve >>= tryOpen err
  where
    err :: IOException
    err = mkIOError NoSuchThing "no address" Nothing Nothing

    resolve :: IO [AddrInfo]
    resolve =
      let hints = defaultHints {addrSocketType = Stream}
       in getAddrInfo (Just hints) (Just host) (Just port)

    tryOpen :: IOException -> [AddrInfo] -> IO c
    tryOpen e [] = E.throwIO e
    tryOpen _ (addr : as) =
      E.try (open addr) >>= either (`tryOpen` as) pure

    open :: AddrInfo -> IO c
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      connect sock $ addrAddress addr
      ctx <- connectTLS clientParams sock
      getClientConnection ctx

mkTLSClientParams :: HostName -> ServiceName -> C.KeyHash -> T.ClientParams
mkTLSClientParams host port keyHash = do
  let p = B.pack port
  (T.defaultParamsClient host p)
    { T.clientShared = def,
      T.clientHooks = def {T.onServerCertificate = \_ _ _ -> validateCertificateChain keyHash host p},
      T.clientSupported = supportedParameters
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
