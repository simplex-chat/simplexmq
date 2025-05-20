{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Transport.Shared where

import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Logger.Simple (logError)
import Data.ByteString (ByteString)
import qualified Data.X509 as X
import qualified Data.X509.CertificateStore as XS
import qualified Data.X509.Validation as XV
import Network.Socket (HostName)

x509validate :: X.SignedCertificate -> (HostName, ByteString) -> X.CertificateChain -> IO [XV.FailedReason]
x509validate caCert serviceID = XV.validate X.HashSHA256 XV.defaultHooks checks certStore noCache serviceID
  where
    checks = XV.defaultChecks {XV.checkFQHN = False}
    certStore = XS.makeCertificateStore [caCert]
    noCache = XV.ValidationCache (\_ _ _ -> pure XV.ValidationCacheUnknown) (\_ _ _ -> pure ())

takePeerCertChain :: TMVar (Maybe X.CertificateChain) -> IO (X.CertificateChain)
takePeerCertChain peerCert =
  atomically (tryTakeTMVar peerCert) >>= \case
    Just (Just cc) -> pure cc
    Just Nothing -> logError "peer certificate invalid" >> E.throwIO (userError "peer certificate invalid")
    Nothing -> logError "certificate hook not called" >> E.throwIO (userError "certificate hook not called") -- onServerCertificate / onClientCertificate
