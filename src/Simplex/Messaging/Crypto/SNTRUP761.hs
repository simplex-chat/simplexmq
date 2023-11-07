{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}

module Simplex.Messaging.Crypto.SNTRUP761 where

import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import Simplex.Messaging.Crypto
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.SNTRUP761.Bindings

-- Hybrid shared secret for crypto_box is defined as SHA256(DHSecret || KEMSharedKey),
-- similar to https://datatracker.ietf.org/doc/draft-josefsson-ntruprime-hybrid/

class KEMSharedSecret kem where kemSecretBytes :: kem -> ScrubbedBytes

newtype KEMHybridSecret = KEMHybridSecret ScrubbedBytes

newtype KEMHybridOrDHSecret = KEMHybridOrDHSecret ScrubbedBytes

instance KEMSharedSecret KEMHybridSecret where kemSecretBytes (KEMHybridSecret secret) = secret

instance KEMSharedSecret KEMHybridOrDHSecret where kemSecretBytes (KEMHybridOrDHSecret secret) = secret

-- | NaCl @crypto_box@ decrypt with a shared hybrid DH + KEM secret and 192-bit nonce.
kcbDecrypt :: KEMSharedSecret kem => kem -> CbNonce -> ByteString -> Either CryptoError ByteString
kcbDecrypt = sbDecrypt_ . kemSecretBytes

-- | NaCl @crypto_box@ encrypt with a shared hybrid DH + KEM secret and 192-bit nonce.
kcbEncrypt :: KEMSharedSecret kem => kem -> CbNonce -> ByteString -> Int -> Either CryptoError ByteString
kcbEncrypt = sbEncrypt_ . kemSecretBytes

kemHybridSecret :: PublicKeyX25519 -> PrivateKeyX25519 -> KEMSharedKey -> KEMHybridSecret
kemHybridSecret k pk (KEMSharedKey kem) =
  let DhSecretX25519 dh = C.dh' k pk
   in KEMHybridSecret $ BA.convert (hash $ BA.convert dh <> kem :: Digest SHA256)

kemHybridOrDHSecret :: PublicKeyX25519 -> PrivateKeyX25519 -> Maybe KEMSharedKey -> KEMHybridOrDHSecret
kemHybridOrDHSecret k pk = \case
  Just kem -> KEMHybridOrDHSecret $ kemSecretBytes $ kemHybridSecret k pk kem
  Nothing -> let DhSecretX25519 dh = C.dh' k pk in KEMHybridOrDHSecret $ BA.convert dh
