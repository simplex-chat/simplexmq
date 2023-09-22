{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Transport.Credentials where

import qualified Crypto.PubKey.Ed25519 as Ed25519
import Data.ASN1.Types (getObjectID)
import qualified Data.ByteArray as Memory
import Data.Hourglass (Hours(..), timeAdd)
import qualified Data.X509 as X509
import Data.X509.Validation (Fingerprint, getFingerprint)
import qualified Network.TLS as TLS
import qualified Time.System as Hourglass

-- | Generate a certificate chain to be used with TLS fingerprint-pinning
genTlsCredentials :: IO (Fingerprint, TLS.Credentials)
genTlsCredentials = do
  ca@(_, root) <- genCertificate Nothing (-25, 365 * 24) "Root" -- long-lived "CA"
  (entitySecret, entity) <- genCertificate (Just ca) (0, 1) "Entity" -- session cert
  pure
    ( getFingerprint root X509.HashSHA256
    , TLS.Credentials
        [ ( X509.CertificateChain [entity, root]
          , X509.PrivKeyEd25519 entitySecret
          )
        ]
    )

genCertificate :: Maybe (Ed25519.SecretKey, X509.SignedCertificate) -> (Hours, Hours) -> X509.ASN1CharacterString -> IO (Ed25519.SecretKey, X509.SignedCertificate)
genCertificate parent (hoursBefore, hoursAfter) subjectName = do
  today <- Hourglass.dateCurrent
  let validity = ( timeAdd today (-hoursBefore :: Hours), timeAdd today (hoursAfter :: Hours))
  secret <- Ed25519.generateSecretKey
  let public = Ed25519.toPublic secret
  let (issuerSecret, issuerPublic, issuer) = case parent of
        Nothing -> (secret, public, subject)
        Just (key, cert) -> (key, Ed25519.toPublic key, X509.certSubjectDN . X509.signedObject $ X509.getSigned cert)
  let signed = signCertificate (issuerSecret, issuerPublic) X509.Certificate
        { X509.certVersion      = 2
        , X509.certSerial       = 1
        , X509.certSignatureAlg = X509.SignatureALG_IntrinsicHash X509.PubKeyALG_Ed25519
        , X509.certIssuerDN     = issuer
        , X509.certValidity     = validity
        , X509.certSubjectDN    = subject
        , X509.certPubKey       = X509.PubKeyEd25519 public
        , X509.certExtensions   = X509.Extensions Nothing
        }
  pure (secret, signed)
  where
    subject = dn subjectName
    dn dnCommonName = X509.DistinguishedName
      [ (getObjectID X509.DnCommonName, dnCommonName)
      ]

signCertificate :: (Ed25519.SecretKey, Ed25519.PublicKey) -> X509.Certificate -> X509.SignedCertificate
signCertificate (secret, public) = fst . X509.objectToSignedExact f
  where
    f bytes =
      ( Memory.convert $ Ed25519.sign secret public bytes
      , X509.SignatureALG_IntrinsicHash X509.PubKeyALG_Ed25519
      , ()
      )
