{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Ethereum addresses: derivation from a public key, and EIP-55 mixed-case
-- checksum encoding.
module Simplex.Messaging.Eth.Address
  ( Address,
    unAddress,
    mkAddress,
    addressFromPublicKey,
    addressFromPrivateKey,
    checksumAddress,
    parseAddress,
    addressSize,
    ethereumPath,
  )
where

import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Char (isDigit, isHexDigit, isLower, isUpper, toLower)
import Data.Word (Word32, Word8)
import Simplex.Messaging.Crypto.BIP32 (hardened)
import qualified Simplex.Messaging.Crypto.Secp256k1 as S
import Simplex.Messaging.Eth.Keccak (keccak256)

-- | A 20-byte Ethereum address. 'Show' renders the EIP-55 checksummed form,
-- which is what a user would paste into a block explorer.
newtype Address = Address ByteString
  deriving (Eq, Ord)

instance Show Address where
  show = BC.unpack . checksumAddress

addressSize :: Int
addressSize = 20

unAddress :: Address -> ByteString
unAddress (Address bs) = bs

mkAddress :: ByteString -> Either String Address
mkAddress bs
  | B.length bs /= addressSize = Left $ "address: expected 20 bytes, got " <> show (B.length bs)
  | otherwise = Right (Address bs)

-- | The low 20 bytes of @keccak256@ of the uncompressed public key with its
-- @0x04@ SEC1 prefix removed.
addressFromPublicKey :: S.PublicKey -> Address
addressFromPublicKey pk =
  Address . B.drop 12 . keccak256 . B.drop 1 $ S.serializePublicKey S.Uncompressed pk

addressFromPrivateKey :: S.PrivateKey -> Address
addressFromPrivateKey = addressFromPublicKey . S.publicKey

-- | EIP-55: @0x@ followed by 40 hex digits whose case encodes a checksum over
-- the lowercase hex form.
checksumAddress :: Address -> ByteString
checksumAddress (Address bs) = "0x" <> B.pack (zipWith adjust [0 ..] lowerHex)
  where
    lowerHex = B.unpack (toHex bs)
    hashed = keccak256 (B.pack lowerHex)
    adjust :: Int -> Word8 -> Word8
    adjust i c
      | isHexLetter c && nibbleAt i >= 8 = upper c
      | otherwise = c
    nibbleAt i =
      let byte = B.index hashed (i `div` 2)
       in if even i then byte `shiftR` 4 else byte .&. 0x0F
    isHexLetter c = c >= 0x61 && c <= 0x66 -- 'a'..'f'
    upper c = c - 0x20

-- | Parse @0x@-prefixed or bare hex. A mixed-case address is checked against
-- its EIP-55 checksum; an all-lowercase or all-uppercase one carries no
-- checksum and is accepted as-is, which is what every Ethereum client does.
parseAddress :: ByteString -> Either String Address
parseAddress s
  | B.length body /= 40 = Left $ "address: expected 40 hex digits, got " <> show (B.length body)
  | not (BC.all isHexDigit body) = Left "address: not hexadecimal"
  | mixedCase && checksumAddress addr /= "0x" <> body = Left "address: EIP-55 checksum mismatch"
  | otherwise = Right addr
  where
    body = if "0x" `B.isPrefixOf` s || "0X" `B.isPrefixOf` s then B.drop 2 s else s
    bodyC = BC.unpack body
    letters = filter (not . isDigit) bodyC
    mixedCase = any isUpper letters && any isLower letters
    addr = Address (fromHex (BC.map toLower body))

-- | BIP-44 path for Ethereum account @i@: @m\/44'\/60'\/i'\/0\/0@.
ethereumPath :: Word32 -> [Word32]
ethereumPath account = [hardened 44, hardened 60, hardened account, 0, 0]

-- Hex helpers, local so that Address does not depend on a base16 package and
-- the case handling stays explicit (EIP-55 is entirely about case).

toHex :: ByteString -> ByteString
toHex = B.concatMap (\w -> B.pack [hexDigit (w `shiftR` 4), hexDigit (w .&. 0x0F)])
  where
    hexDigit n
      | n < 10 = 0x30 + n
      | otherwise = 0x57 + n -- 'a' - 10

-- | Assumes a validated even-length lowercase hex string.
fromHex :: ByteString -> ByteString
fromHex bs = B.pack $ go (B.unpack bs)
  where
    go (h : l : rest) = (nibble h * 16 + nibble l) : go rest
    go _ = []
    nibble w
      | w >= 0x30 && w <= 0x39 = w - 0x30
      | w >= 0x61 && w <= 0x66 = w - 0x57
      | w >= 0x41 && w <= 0x46 = w - 0x37
      | otherwise = 0
