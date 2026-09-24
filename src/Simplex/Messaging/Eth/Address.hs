{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Eth.Address
  ( Address,
    addressFromPrivateKey,
    ethereumPath,
  )
where

import Control.Applicative (optional, (<|>))
import Control.Monad (unless, when, (<=<))
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bits (shiftR, (.&.))
import qualified Data.ByteArray.Encoding as BAE
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Char (isHexDigit, isLower, isUpper, toUpper)
import Data.Word (Word32)
import Simplex.Messaging.Crypto (keccak256)
import Simplex.Messaging.Crypto.BIP32 (hardened, isHardened)
import qualified Simplex.Messaging.Crypto.Secp256k1 as S
import Simplex.Messaging.Encoding.String

newtype Address = Address ByteString
  deriving (Eq, Ord, Show)

instance StrEncoding Address where
  strEncode = checksumAddress
  strP = do
    _ <- optional $ A.string "0x" <|> A.string "0X"
    body <- A.takeWhile isHexDigit
    unless (B.length body == addressSize * 2) $ fail $ "address: expected 40 hex digits, got " <> show (B.length body)
    a <- Address <$> either fail pure (BAE.convertFromBase BAE.Base16 body)
    when (mixedCase body && checksumAddress a /= "0x" <> body) $ fail "address: EIP-55 checksum mismatch"
    pure a
    where
      mixedCase s = BC.any isUpper s && BC.any isLower s

addressSize :: Int
addressSize = 20

-- | The low 20 bytes of @keccak256@ of the uncompressed public key with its @0x04@ SEC1 prefix removed.
addressFromPublicKey :: S.Secp256k1PublicKey -> IO Address
addressFromPublicKey pk =
  Address . B.drop 12 . keccak256 . B.drop 1 <$> S.serializePublicKey S.Uncompressed pk

addressFromPrivateKey :: S.Secp256k1PrivateKey -> IO Address
addressFromPrivateKey = addressFromPublicKey <=< S.secp256k1PublicKey

-- | EIP-55: @0x@ and 40 hex digits whose case encodes a checksum over the lowercase hex form.
checksumAddress :: Address -> ByteString
checksumAddress (Address bs) = "0x" <> BC.pack (zipWith adjust [0 ..] (BC.unpack lowerHex))
  where
    lowerHex = BAE.convertToBase BAE.Base16 bs
    hashed = keccak256 lowerHex
    adjust i c = if isLower c && nibbleAt i >= 8 then toUpper c else c
    nibbleAt i =
      let byte = B.index hashed (i `div` 2)
       in if even i then byte `shiftR` 4 else byte .&. 0x0F

ethereumPath :: Word32 -> Word32 -> Maybe [Word32]
ethereumPath account address
  | isHardened account || isHardened address = Nothing
  | otherwise = Just [hardened 44, hardened 60, hardened account, 0, address]
