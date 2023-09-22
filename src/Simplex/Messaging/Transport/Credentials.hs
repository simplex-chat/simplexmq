{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Transport.Credentials
  ( tlsCredentials,
    Credentials,
    genCredentials,
    signCertificate,
  )
where

import qualified Crypto.PubKey.Ed25519 as Ed25519
import Data.ASN1.Types (getObjectID)
import qualified Data.ByteArray as Memory
import Data.Hourglass (Hours (..), timeAdd)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import qualified Data.X509 as X509
import Data.X509.Validation (Fingerprint (..), getFingerprint)
import qualified Network.TLS as TLS
import Simplex.Messaging.Crypto (KeyHash (..))
import qualified Time.System as Hourglass

-- | Generate a certificate chain to be used with TLS fingerprint-pinning
--
-- @
-- genTlsCredentials = do
--   ca <- genCredentials Nothing (-25, 365 * 24) "Root" -- long-lived root cert
--   leaf <- genCredentials (Just ca) (0, 1) "Entity" -- session-signing cert
--   pure $ tlsCredentials (leaf :| [ca])
-- @
tlsCredentials :: NonEmpty Credentials -> (KeyHash, TLS.Credentials)
tlsCredentials credentials = (KeyHash rootFP, TLS.Credentials [creds])
  where
    Fingerprint rootFP = getFingerprint root X509.HashSHA256
    leafSecret = fst $ NE.head credentials
    root = snd $ NE.last credentials
    creds = (X509.CertificateChain certs, X509.PrivKeyEd25519 leafSecret)
    certs = map snd $ NE.toList credentials

type Credentials = (Ed25519.SecretKey, X509.SignedCertificate)

genCredentials :: Maybe Credentials -> (Hours, Hours) -> X509.ASN1CharacterString -> IO Credentials
genCredentials parent (before, after) subjectName = do
  secret <- Ed25519.generateSecretKey
  let public = Ed25519.toPublic secret
  let (issuerSecret, issuerPublic, issuer) = case parent of
        Nothing -> (secret, public, subject)
        Just (key, cert) -> (key, Ed25519.toPublic key, X509.certSubjectDN . X509.signedObject $ X509.getSigned cert)
  today <- Hourglass.dateCurrent
  let signed =
        signCertificate
          (issuerSecret, issuerPublic)
          X509.Certificate
            { X509.certVersion = 2,
              X509.certSerial = 1,
              X509.certSignatureAlg = X509.SignatureALG_IntrinsicHash X509.PubKeyALG_Ed25519,
              X509.certIssuerDN = issuer,
              X509.certValidity = (timeAdd today (-before), timeAdd today after),
              X509.certSubjectDN = subject,
              X509.certPubKey = X509.PubKeyEd25519 public,
              X509.certExtensions = X509.Extensions Nothing
            }
  pure (secret, signed)
  where
    subject = dn subjectName
    dn dnCommonName =
      X509.DistinguishedName
        [ (getObjectID X509.DnCommonName, dnCommonName)
        ]

signCertificate :: (Ed25519.SecretKey, Ed25519.PublicKey) -> X509.Certificate -> X509.SignedCertificate
signCertificate (secret, public) = fst . X509.objectToSignedExact f
  where
    f bytes =
      ( Memory.convert $ Ed25519.sign secret public bytes,
        X509.SignatureALG_IntrinsicHash X509.PubKeyALG_Ed25519,
        ()
      )
