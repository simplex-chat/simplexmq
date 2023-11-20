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

newtype KEMHybridSecret = KEMHybridSecret ScrubbedBytes

-- | NaCl @crypto_box@ decrypt with a shared hybrid DH + KEM secret and 192-bit nonce.
kcbDecrypt :: KEMHybridSecret -> CbNonce -> ByteString -> Either CryptoError ByteString
kcbDecrypt (KEMHybridSecret k) = sbDecrypt_ k

-- | NaCl @crypto_box@ encrypt with a shared hybrid DH + KEM secret and 192-bit nonce.
kcbEncrypt :: KEMHybridSecret -> CbNonce -> ByteString -> Int -> Either CryptoError ByteString
kcbEncrypt (KEMHybridSecret k) = sbEncrypt_ k

kemHybridSecret :: PublicKeyX25519 -> PrivateKeyX25519 -> KEMSharedKey -> KEMHybridSecret
kemHybridSecret k pk (KEMSharedKey kem) =
  let DhSecretX25519 dh = C.dh' k pk
   in KEMHybridSecret $ BA.convert (hash $ BA.convert dh <> kem :: Digest SHA256)
