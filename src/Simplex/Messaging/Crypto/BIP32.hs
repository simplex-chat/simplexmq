{-# LANGUAGE OverloadedStrings #-}

-- | BIP-32 HD derivation over secp256k1, private only: we hold the seed, so CKDpub, xpub and fingerprints are not implemented.
module Simplex.Messaging.Crypto.BIP32
  ( ExtendedKey (..),
    masterKey,
    derivePath,
    renderPath,
    hardenedOffset,
    hardened,
  )
where

import Control.Monad (foldM)
import qualified Crypto.Hash as H
import qualified Crypto.MAC.HMAC as HMAC
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.List (intercalate)
import Data.Word (Word32)
import qualified Simplex.Messaging.Crypto.Secp256k1 as S
import Simplex.Messaging.Encoding (smpEncode)

-- | An extended private key: the key plus its chain code, secret too, as it and one child derive the siblings.
data ExtendedKey = ExtendedKey
  { xkKey :: S.Secp256k1PrivateKey,
    xkChainCode :: ScrubbedBytes
  }
  deriving (Eq)

-- | Child indexes at or above this are hardened.
hardenedOffset :: Word32
hardenedOffset = 0x80000000

-- | @hardened 44 == 44'@. An index at or above 'hardenedOffset' is returned unchanged, so this is idempotent rather than overflowing.
hardened :: Word32 -> Word32
hardened i
  | isHardened i = i
  | otherwise = i + hardenedOffset

isHardened :: Word32 -> Bool
isHardened i = i >= hardenedOffset

-- | Derive the master key from a BIP-39 seed (BIP-32 allows 16 to 64 bytes).
masterKey :: ByteString -> Either String ExtendedKey
masterKey seed
  | seedLen < 16 || seedLen > 64 =
      Left $ "seed: expected 16 to 64 bytes, got " <> show seedLen
  | otherwise = case S.mkPrivateKey il of
      Left _ -> Left "seed: invalid master key, use a different seed"
      Right k -> Right ExtendedKey {xkKey = k, xkChainCode = ir}
  where
    seedLen = B.length seed
    i = hmacSHA512 "Bitcoin seed" seed
    il = B.take 32 i
    ir = B.drop 32 i

-- | CKDpriv. 'Left' only in the negligible case BIP-32 calls "proceed with the next index", which no real seed reaches.
deriveChild :: ExtendedKey -> Word32 -> Either String ExtendedKey
deriveChild xk i =
  case S.privateKeyTweakAdd (xkKey xk) il of
    Nothing -> Left $ "derivation: invalid child at index " <> show i <> ", use the next index"
    Just k -> Right ExtendedKey {xkKey = k, xkChainCode = ir}
  where
    dat
      | isHardened i = B.singleton 0 <> S.unPrivateKey (xkKey xk) <> smpEncode i
      | otherwise = S.serializePublicKey S.Compressed (S.secp256k1PublicKey (xkKey xk)) <> smpEncode i
    hm = hmacSHA512 (xkChainCode xk) dat
    il = B.take 32 hm
    ir = B.drop 32 hm

derivePath :: ExtendedKey -> [Word32] -> Either String ExtendedKey
derivePath = foldM deriveChild



renderPath :: [Word32] -> ByteString
renderPath is = BC.pack $ intercalate "/" ("m" : map component is)
  where
    component i
      | isHardened i = show (i - hardenedOffset) <> "'"
      | otherwise = show i

hmacSHA512 :: ByteString -> ByteString -> ByteString
hmacSHA512 key msg = BA.convert (HMAC.hmac key msg :: HMAC.HMAC H.SHA512)
