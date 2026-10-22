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
import Control.Monad (zipWithM)
import qualified Crypto.PubKey.RSA as RSA
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
x509validate _ _ (X.CertificateChain []) = pure [XV.EmptyChain]
x509validate caCert serviceID (X.CertificateChain certs)
  | all (supportedKey . X.certPubKey . X.getCertificate) certs = concat <$> zipWithM validateIssued certs (drop 1 certs <> [caCert])
  | otherwise = pure [XV.InvalidSignature XV.SignatureUnimplemented]
  where
    validateIssued cert issuer = XV.validate X.HashSHA256 XV.defaultHooks checks (XS.makeCertificateStore [issuer]) noCache serviceID (X.CertificateChain [cert])
    checks = XV.defaultChecks {XV.checkFQHN = False}
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
