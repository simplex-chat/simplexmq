{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Transport.Credentials
  ( tlsCredentials,
    Credentials,
    genCredentials,
    C.signCertificate,
  )
where

import Data.ASN1.Types (getObjectID)
import Data.Hourglass (Hours (..), timeAdd)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import qualified Data.X509 as X509
import Data.X509.Validation (Fingerprint (..), getFingerprint)
import qualified Network.TLS as TLS
import qualified Simplex.Messaging.Crypto as C
import qualified Time.System as Hourglass

-- | Generate a certificate chain to be used with TLS fingerprint-pinning
--
-- @
-- genTlsCredentials = do
--   ca <- genCredentials Nothing (-25, 365 * 24) "Root" -- long-lived root cert
--   leaf <- genCredentials (Just ca) (0, 1) "Entity" -- session-signing cert
--   pure $ tlsCredentials (leaf :| [ca])
-- @
tlsCredentials :: NonEmpty Credentials -> (C.KeyHash, TLS.Credentials)
tlsCredentials credentials = (C.KeyHash rootFP, TLS.Credentials [(X509.CertificateChain certs, privateToTls $ snd leafKey)])
  where
    Fingerprint rootFP = getFingerprint root X509.HashSHA256
    leafKey = fst $ NE.head credentials
    root = snd $ NE.last credentials
    certs = map snd $ NE.toList credentials

privateToTls :: C.APrivateSignKey -> TLS.PrivKey
privateToTls (C.APrivateSignKey _ k) = case k of
  C.PrivateKeyEd25519 secret _ -> TLS.PrivKeyEd25519 secret
  C.PrivateKeyEd448 secret _ -> TLS.PrivKeyEd448 secret

type Credentials = (C.ASignatureKeyPair, X509.SignedCertificate)

genCredentials :: Maybe Credentials -> (Hours, Hours) -> X509.ASN1CharacterString -> IO Credentials
genCredentials parent (before, after) subjectName = do
  subjectKeys <- C.generateSignatureKeyPair C.SEd25519
  let (issuerKeys, issuer) = case parent of
        Nothing -> (subjectKeys, subject) -- self-signed
        Just (keys, cert) -> (keys, X509.certSubjectDN . X509.signedObject $ X509.getSigned cert)
  today <- Hourglass.dateCurrent
  let signed =
        C.signCertificate
          (snd issuerKeys)
          X509.Certificate
            { X509.certVersion = 2,
              X509.certSerial = 1,
              X509.certSignatureAlg = C.signatureAlgorithmX509 issuerKeys,
              X509.certIssuerDN = issuer,
              X509.certValidity = (timeAdd today (-before), timeAdd today after),
              X509.certSubjectDN = subject,
              X509.certPubKey = C.toPubKey C.publicToX509 $ fst subjectKeys,
              X509.certExtensions = X509.Extensions Nothing
            }
  pure (subjectKeys, signed)
  where
    subject = dn subjectName
    dn dnCommonName =
      X509.DistinguishedName
        [ (getObjectID X509.DnCommonName, dnCommonName)
        ]
