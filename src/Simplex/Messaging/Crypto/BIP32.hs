{-# LANGUAGE NamedFieldPuns #-}
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
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import qualified Crypto.Hash as H
import qualified Crypto.MAC.HMAC as HMAC
import Data.Bifunctor (bimap)
import Data.Bits ((.|.))
import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.List (intercalate)
import Data.Word (Word32)
import qualified Simplex.Messaging.Crypto.Secp256k1 as S
import Simplex.Messaging.Encoding (smpEncode)

data ExtendedKey = ExtendedKey
  { xkKey :: S.Secp256k1PrivateKey,
    xkChainCode :: ScrubbedBytes
  }
  deriving (Eq)

-- | Child indexes at or above this are hardened.
hardenedOffset :: Word32
hardenedOffset = 0x80000000

hardened :: Word32 -> Word32
hardened = (.|. hardenedOffset)

isHardened :: Word32 -> Bool
isHardened i = i >= hardenedOffset

-- | Derive the master key from a BIP-39 seed (BIP-32 allows 16 to 64 bytes).
masterKey :: ScrubbedBytes -> IO (Either String ExtendedKey)
masterKey seed
  | seedLen < 16 || seedLen > 64 =
      pure $ Left $ "seed: expected 16 to 64 bytes, got " <> show seedLen
  | otherwise =
      bimap (const "seed: invalid master key, use a different seed") (\k -> ExtendedKey {xkKey = k, xkChainCode = ir})
        <$> S.mkPrivateKey il
  where
    seedLen = BA.length seed
    (il, ir) = BA.splitAt 32 $ hmacSHA512 "Bitcoin seed" seed

deriveChild :: ExtendedKey -> Word32 -> IO (Either String ExtendedKey)
deriveChild ExtendedKey {xkKey, xkChainCode} i = do
  dat <-
    if isHardened i
      then pure $ BA.cons 0 (S.unPrivateKey xkKey)
      else BA.convert <$> (S.serializePublicKey S.Compressed =<< S.secp256k1PublicKey xkKey)
  let (il, ir) = BA.splitAt 32 $ hmacSHA512 xkChainCode (dat <> BA.convert (smpEncode i))
  maybe (Left $ "derivation: invalid child at index " <> show i <> ", use the next index") (\k -> Right ExtendedKey {xkKey = k, xkChainCode = ir})
    <$> S.privateKeyTweakAdd xkKey il

derivePath :: ExtendedKey -> [Word32] -> IO (Either String ExtendedKey)
derivePath xk = runExceptT . foldM (\k -> ExceptT . deriveChild k) xk

renderPath :: [Word32] -> ByteString
renderPath is = BC.pack $ intercalate "/" ("m" : map component is)
  where
    component i
      | isHardened i = show (i - hardenedOffset) <> "'"
      | otherwise = show i

hmacSHA512 :: ScrubbedBytes -> ScrubbedBytes -> ScrubbedBytes
hmacSHA512 key msg = BA.convert (HMAC.hmac key msg :: HMAC.HMAC H.SHA512)
