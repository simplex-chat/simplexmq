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
import qualified Crypto.PubKey.RSA as RSA
import Data.ByteString (ByteString)
import qualified Data.X509 as X
import qualified Data.X509.CertificateStore as XS
import qualified Data.X509.Validation as XV
import Network.Socket (HostName)

data ChainCertificates
  = CCEmpty
  | CCSelf X.SignedCertificate
  | CCValid {leafCert :: X.SignedCertificate, idCert :: X.SignedCertificate}
  | CCLong

chainIdCaCerts :: X.CertificateChain -> ChainCertificates
chainIdCaCerts (X.CertificateChain chain) = case chain of
  [] -> CCEmpty
  [cert] -> CCSelf cert
  [leafCert, idCert] -> CCValid {leafCert, idCert} -- current long-term online/offline certificates chain
  [leafCert, idCert, _] -> CCValid {leafCert, idCert} -- with additional operator certificate (preset in the client)
  [leafCert, idCert, _, _] -> CCValid {leafCert, idCert} -- with network certificate
  _ -> CCLong

x509validate :: X.SignedCertificate -> (HostName, ByteString) -> X.CertificateChain -> IO [XV.FailedReason]
x509validate caCert serviceID cc@(X.CertificateChain certs)
  | all (supportedKey . X.certPubKey . X.getCertificate) (caCert : certs) = XV.validate X.HashSHA256 XV.defaultHooks checks certStore noCache serviceID cc
  | otherwise = pure [XV.InvalidSignature XV.SignatureUnimplemented]
  where
    checks = XV.defaultChecks {XV.checkFQHN = False}
    certStore = XS.makeCertificateStore [caCert]
    noCache = XV.ValidationCache (\_ _ _ -> pure XV.ValidationCacheUnknown) (\_ _ _ -> pure ())
    supportedKey = \case
      X.PubKeyEd25519 _ -> True
      X.PubKeyEd448 _ -> True
      X.PubKeyEC X.PubKeyEC_Named {} -> True
      X.PubKeyRSA k -> RSA.public_size k <= 512 && RSA.public_e k > 0 && RSA.public_e k < 2 ^ (32 :: Int)
      _ -> False

takePeerCertChain :: TMVar (Maybe X.CertificateChain) -> IO (X.CertificateChain)
takePeerCertChain peerCert =
  atomically (tryTakeTMVar peerCert) >>= \case
    Just (Just cc) -> pure cc
    Just Nothing -> logError "peer certificate invalid" >> E.throwIO (userError "peer certificate invalid")
    Nothing -> logError "certificate hook not called" >> E.throwIO (userError "certificate hook not called") -- onServerCertificate / onClientCertificate
