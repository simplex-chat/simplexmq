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

import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bits (shiftR, (.&.))
import qualified Data.ByteArray.Encoding as BAE
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Char (isDigit, isHexDigit, isLower, isUpper, toLower)
import Data.Word (Word32, Word8)
import Simplex.Messaging.Crypto.BIP32 (hardened)
import qualified Simplex.Messaging.Crypto.Secp256k1 as S
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Eth.Keccak (keccak256)

-- | A 20-byte Ethereum address. 'Show' renders the EIP-55 checksummed form,
-- which is what a user would paste into a block explorer.
newtype Address = Address ByteString
  deriving (Eq, Ord)

instance Show Address where
  show = BC.unpack . checksumAddress

-- | EIP-55 checksummed hex, the form shown in explorers and pasted by users.
-- Parsing accepts bare or @0x@-prefixed hex and verifies a mixed-case checksum.
instance StrEncoding Address where
  strEncode = checksumAddress
  strP = either fail pure . parseAddress =<< A.takeWhile1 isHexOr0x
    where
      isHexOr0x c = isHexDigit c || c == 'x' || c == 'X'

instance ToJSON Address where
  toEncoding = strToJEncoding
  toJSON = strToJSON

instance FromJSON Address where
  parseJSON = strParseJSON "Address"

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
  | otherwise = case fromHex (BC.map toLower body) of
      Left _ -> Left "address: not hexadecimal"
      Right bs
        | mixedCase && checksumAddress (Address bs) /= "0x" <> body ->
            Left "address: EIP-55 checksum mismatch"
        | otherwise -> Right (Address bs)
  where
    body = if "0x" `B.isPrefixOf` s || "0X" `B.isPrefixOf` s then B.drop 2 s else s
    bodyC = BC.unpack body
    letters = filter (not . isDigit) bodyC
    mixedCase = any isUpper letters && any isLower letters

-- | BIP-44 path for Ethereum account @i@: @m\/44'\/60'\/i'\/0\/0@.
ethereumPath :: Word32 -> [Word32]
ethereumPath account = [hardened 44, hardened 60, hardened account, 0, 0]

-- Hex via memory's Base16, which this package already depends on and which
-- Crypto.Secp256k1 already uses. Base16 emits lowercase, which is what EIP-55
-- needs as its starting point - 'checksumAddress' is what introduces case.

toHex :: ByteString -> ByteString
toHex = BAE.convertToBase BAE.Base16

-- | Decodes and validates: a non-hex or odd-length input is a Left, so callers
-- do not have to scan for hex digits themselves.
fromHex :: ByteString -> Either String ByteString
fromHex = BAE.convertFromBase BAE.Base16
