{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | BIP-32 hierarchical deterministic key derivation over secp256k1.
--
-- Private derivation only: we always hold the seed, so the neutered/extended
-- public key half of BIP-32 (CKDpub, xpub serialization, fingerprints) is not
-- implemented. Non-hardened child derivation is supported, because BIP-44 paths
-- end in non-hardened components.
module Simplex.Messaging.Crypto.BIP32
  ( ExtendedKey (..),
    masterKey,
    deriveChild,
    derivePath,
    parsePath,
    renderPath,
    hardenedOffset,
    hardened,
    isHardened,
    chainCodeSize,
  )
where

import Control.Applicative (optional, (<|>))
import qualified Crypto.Hash as H
import qualified Crypto.MAC.HMAC as HMAC
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteArray as BA
import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.List (intercalate)
import Data.Word (Word32)
import qualified Simplex.Messaging.Crypto.Secp256k1 as S
import Simplex.Messaging.Parsers (parseAll)

-- | An extended private key: the key plus its chain code.
--
-- 'Show' is redacting — the chain code plus one child key is enough to derive
-- siblings, so it is secret material too.
data ExtendedKey = ExtendedKey
  { xkKey :: S.Secp256k1PrivateKey,
    xkChainCode :: ByteString
  }
  deriving (Eq)

instance Show ExtendedKey where
  show _ = "ExtendedKey <redacted>"

chainCodeSize :: Int
chainCodeSize = 32

-- | Child indexes at or above this are hardened.
hardenedOffset :: Word32
hardenedOffset = 0x80000000

-- | @hardened 44 == 44'@. Indexes at or above 'hardenedOffset' are returned
-- unchanged, so @hardened . hardened@ is idempotent rather than overflowing.
hardened :: Word32 -> Word32
hardened i
  | i >= hardenedOffset = i
  | otherwise = i + hardenedOffset

isHardened :: Word32 -> Bool
isHardened i = i >= hardenedOffset

-- | Derive the master key from a BIP-39 seed (BIP-32 allows 16 to 64 bytes).
masterKey :: ByteString -> Either String ExtendedKey
masterKey seed
  | seedLen < 16 || seedLen > 64 =
      Left $ "seed: expected 16 to 64 bytes, got " <> show seedLen
  | otherwise = do
      k <- either (const $ Left "seed: invalid master key, use a different seed") Right $ S.mkPrivateKey il
      Right ExtendedKey {xkKey = k, xkChainCode = ir}
  where
    seedLen = B.length seed
    i = hmacSHA512 "Bitcoin seed" seed
    il = B.take 32 i
    ir = B.drop 32 i

-- | CKDpriv. 'Left' only in the negligible case BIP-32 defines as "proceed with
-- the next index"; callers deriving a fixed path should surface it rather than
-- silently skipping, since it never happens for real seeds.
deriveChild :: ExtendedKey -> Word32 -> Either String ExtendedKey
deriveChild xk i =
  case S.privateKeyTweakAdd (xkKey xk) il of
    Nothing -> Left $ "derivation: invalid child at index " <> show i <> ", use the next index"
    Just k -> Right ExtendedKey {xkKey = k, xkChainCode = ir}
  where
    dat
      | isHardened i = B.singleton 0 <> S.unPrivateKey (xkKey xk) <> ser32 i
      | otherwise = S.serializePublicKey S.Compressed (S.secp256k1PublicKey (xkKey xk)) <> ser32 i
    hm = hmacSHA512 (xkChainCode xk) dat
    il = B.take 32 hm
    ir = B.drop 32 hm

derivePath :: ExtendedKey -> [Word32] -> Either String ExtendedKey
derivePath = foldl (\acc i -> acc >>= (`deriveChild` i)) . Right

-- | Parse a path such as @m\/44'\/60'\/0'\/0\/0@. A leading @m@ or @M@ is
-- optional; both @'@ and @h@ mark a hardened index.
parsePath :: ByteString -> Either String [Word32]
parsePath = parseAll pathP

pathP :: A.Parser [Word32]
pathP =
  optional (A.satisfy $ \c -> c == 'm' || c == 'M')
    *> ((A.char '/' *> (indexP `A.sepBy'` A.char '/')) <|> (indexP `A.sepBy1'` A.char '/') <|> pure [])
  where
    indexP = do
      n <- A.decimal :: A.Parser Integer
      hard <- (True <$ A.satisfy (\c -> c == '\'' || c == 'h' || c == 'H')) <|> pure False
      if n >= toInteger hardenedOffset
        then fail $ "path: index out of range: " <> show n
        else pure $ fromInteger n + if hard then hardenedOffset else 0

renderPath :: [Word32] -> ByteString
renderPath is = BC.pack $ intercalate "/" ("m" : map component is)
  where
    component i
      | isHardened i = show (i - hardenedOffset) <> "'"
      | otherwise = show i

hmacSHA512 :: ByteString -> ByteString -> ByteString
hmacSHA512 key msg = BA.convert (HMAC.hmac key msg :: HMAC.HMAC H.SHA512)

ser32 :: Word32 -> ByteString
ser32 i =
  B.pack
    [ fromIntegral (i `shiftR` 24),
      fromIntegral ((i `shiftR` 16) .&. 0xFF),
      fromIntegral ((i `shiftR` 8) .&. 0xFF),
      fromIntegral (i .&. 0xFF)
    ]
