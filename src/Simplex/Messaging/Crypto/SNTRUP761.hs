{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Crypto.SNTRUP761 where

import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import Simplex.Messaging.Crypto
import Simplex.Messaging.Crypto.SNTRUP761.Bindings
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String

newtype KEMSecretKey = KEMSecretKey SecretKey

newtype KEMPublicKey = KEMPublicKey SecretKey

newtype KEMCiphertext = KEMCiphertext Ciphertext

newtype KEMSharedKey = KEMSharedKey SharedKey

-- Hybrid shared secret for crypto_box is defined as SHA256(DHSecret || KEMSharedKey),
-- similar to https://datatracker.ietf.org/doc/draft-josefsson-ntruprime-hybrid/

newtype KEMHybridSecret = KEMHybridSecret ScrubbedBytes

instance Encoding KEMPublicKey where
  smpEncode (KEMPublicKey pk) = smpEncode (BA.convert pk :: ByteString)
  smpP = KEMPublicKey . BA.convert <$> smpP @ByteString

instance StrEncoding KEMPublicKey where
  strEncode (KEMPublicKey pk) = strEncode (BA.convert pk :: ByteString)
  strP = KEMPublicKey . BA.convert <$> strP @ByteString

instance Encoding KEMCiphertext where
  smpEncode (KEMCiphertext c) = smpEncode (BA.convert c :: ByteString)
  smpP = KEMCiphertext . BA.convert <$> smpP @ByteString

-- | NaCl @crypto_box@ decrypt with a shared hybrid DH + KEM secret and 192-bit nonce.
kcbDecrypt :: KEMHybridSecret -> CbNonce -> ByteString -> Either CryptoError ByteString
kcbDecrypt (KEMHybridSecret secret) = sbDecrypt_ secret

-- | NaCl @crypto_box@ encrypt with a shared hybrid DH + KEM secret and 192-bit nonce.
kcbEncrypt :: KEMHybridSecret -> CbNonce -> ByteString -> Int -> Either CryptoError ByteString
kcbEncrypt (KEMHybridSecret secret) = sbEncrypt_ secret

kemHybridSecret :: DhSecret 'X25519 -> KEMSharedKey -> KEMHybridSecret
kemHybridSecret (DhSecretX25519 k1) (KEMSharedKey k2) =
  KEMHybridSecret $ BA.convert (hash (BA.convert k1 <> k2) :: Digest SHA256)
