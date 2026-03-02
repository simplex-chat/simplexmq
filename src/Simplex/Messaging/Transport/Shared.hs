{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Transport.Shared
  ( ChainCertificates (..),
    chainIdCaCerts,
    x509validate,
    takePeerCertChain,
  ) where

import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Logger.Simple (logError)
import Data.ByteString (ByteString)
import qualified Data.X509 as X
import qualified Data.X509.CertificateStore as XS
import qualified Data.X509.Validation as XV
import Network.Socket (HostName)

data ChainCertificates
  = CCEmpty
  | CCSelf X.SignedCertificate
  | CCValid {leafCert :: X.SignedCertificate, idCert :: X.SignedCertificate, caCert :: X.SignedCertificate}
  | CCLong

chainIdCaCerts :: X.CertificateChain -> ChainCertificates
chainIdCaCerts (X.CertificateChain chain) = case chain of
  [] -> CCEmpty
  [cert] -> CCSelf cert
  [leafCert, cert] -> CCValid {leafCert, idCert = cert, caCert = cert} -- current long-term online/offline certificates chain
  [leafCert, idCert, caCert] -> CCValid {leafCert, idCert, caCert} -- with additional operator certificate (preset in the client)
  [leafCert, idCert, _, caCert] -> CCValid {leafCert, idCert, caCert} -- with network certificate
  _ -> CCLong

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
