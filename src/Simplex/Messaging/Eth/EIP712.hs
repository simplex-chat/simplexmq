{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | EIP-712 typed structured data hashing.
--
-- This implements the hashing half of EIP-712 — @typeHash@, @encodeData@,
-- @hashStruct@ and the final @0x19 0x01@ digest — over an explicit list of
-- member values. It deliberately does *not* derive the canonical type string
-- from a schema: the caller supplies it. Our structs are a handful of fixed
-- shapes agreed with the contracts, and a hand-written type string that is
-- checked against Solidity in a test is both simpler and easier to audit than a
-- schema encoder whose output nobody reads.
--
-- The type string must be the EIP-712 canonical encoding: no spaces after
-- commas, member type and name separated by one space, and any referenced
-- struct types appended in alphabetical order. For example:
--
-- > "TransferName(address from,address to,uint256 tokenId,uint256 nonce,uint256 deadline)"
module Simplex.Messaging.Eth.EIP712
  ( Eip712Domain (..),
    Value (..),
    typeHash,
    encodeValue,
    encodeData,
    hashStruct,
    domainSeparator,
    hashTypedData,
  )
where

import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Simplex.Messaging.Eth.Address (Address, unAddress)
import Simplex.Messaging.Eth.Keccak (keccak256)

-- | The standard EIP-712 domain. All four fields are used; the spec allows
-- omitting any of them, but every contract in this project includes all four,
-- and fixing the shape keeps 'domainSeparator' total.
data Eip712Domain = Eip712Domain
  { edName :: ByteString,
    edVersion :: ByteString,
    edChainId :: Integer,
    edVerifyingContract :: Address
  }
  deriving (Eq, Show)

-- | A struct member value, in the EIP-712 sense.
--
-- 'VStruct' takes an already-computed 'hashStruct' result, which is how nested
-- structs are encoded; 'VArray' hashes the concatenation of its members.
data Value
  = VUint Integer
  | VInt Integer
  | VBool Bool
  | VAddress Address
  | -- | @bytesN@ for @N@ in @[1, 32]@, left-aligned and zero-padded.
    VFixedBytes ByteString
  | -- | Dynamic @bytes@.
    VBytes ByteString
  | -- | @string@; the caller supplies UTF-8 bytes.
    VString ByteString
  | VArray [Value]
  | -- | A nested struct, given as its 32-byte @hashStruct@.
    VStruct ByteString
  deriving (Eq, Show)

-- | @keccak256@ of the canonical type string.
typeHash :: ByteString -> ByteString
typeHash = keccak256

-- | Encode one member as exactly 32 bytes.
encodeValue :: Value -> Either String ByteString
encodeValue = \case
  VUint n
    | n < 0 || n >= two256 -> Left $ "eip712: uint256 out of range: " <> show n
    | otherwise -> Right (word256 n)
  VInt n
    | n < negate two255 || n >= two255 -> Left $ "eip712: int256 out of range: " <> show n
    | otherwise -> Right (word256 (if n < 0 then n + two256 else n))
  VBool b -> Right (word256 (if b then 1 else 0))
  VAddress a -> Right (B.replicate 12 0 <> unAddress a)
  VFixedBytes bs
    | B.null bs || B.length bs > 32 -> Left $ "eip712: bytesN length " <> show (B.length bs)
    | otherwise -> Right (bs <> B.replicate (32 - B.length bs) 0)
  VBytes bs -> Right (keccak256 bs)
  VString bs -> Right (keccak256 bs)
  VArray vs -> keccak256 . B.concat <$> traverse encodeValue vs
  VStruct h
    | B.length h /= 32 -> Left $ "eip712: struct hash must be 32 bytes, got " <> show (B.length h)
    | otherwise -> Right h
  where
    two256 = 2 ^ (256 :: Int) :: Integer
    two255 = 2 ^ (255 :: Int) :: Integer

encodeData :: [Value] -> Either String ByteString
encodeData vs = B.concat <$> traverse encodeValue vs

-- | @keccak256(typeHash ‖ encodeData(members))@.
hashStruct :: ByteString -> [Value] -> Either String ByteString
hashStruct typeString members = keccak256 . (typeHash typeString <>) <$> encodeData members

domainSeparator :: Eip712Domain -> Either String ByteString
domainSeparator d =
  hashStruct
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    [ VString (edName d),
      VString (edVersion d),
      VUint (edChainId d),
      VAddress (edVerifyingContract d)
    ]

-- | The final digest to sign: @keccak256(0x19 ‖ 0x01 ‖ domainSeparator ‖ hashStruct)@.
hashTypedData :: Eip712Domain -> ByteString -> [Value] -> Either String ByteString
hashTypedData d typeString members = do
  ds <- domainSeparator d
  hs <- hashStruct typeString members
  pure $ keccak256 (B.pack [0x19, 0x01] <> ds <> hs)

word256 :: Integer -> ByteString
word256 x = B.pack [fromIntegral ((x `shiftR` (8 * (31 - i))) .&. 0xFF) | i <- [0 .. 31]]
