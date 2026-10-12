{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Eth.EIP712
  ( Eip712Domain (..),
    Eip712Value (..),
    domainSeparator,
    hashStruct,
    hashTypedData,
    serializeSignature,
  )
where

import Crypto.Number.Serialize (i2ospOf_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Word (Word64)
import Simplex.Messaging.Crypto (keccak256)
import Simplex.Messaging.Crypto.Secp256k1 (RecoverableSignature (..))
import Simplex.Messaging.Eth.Address (Address, unAddress)

data Eip712Domain = Eip712Domain
  { edName :: ByteString,
    edVersion :: ByteString,
    edChainId :: Word64,
    edVerifyingContract :: Address
  }

data Eip712Value
  = VUint Integer
  | VAddress Address
  | VFixedBytes ByteString
  | VBytes ByteString
  | VString ByteString
  | VArray [Eip712Value]
  | VStruct ByteString

encodeValue :: Eip712Value -> Either String ByteString
encodeValue = \case
  VUint n
    | n < 0 || n >= 2 ^ (256 :: Int) -> Left $ "eip712: uint256 out of range: " <> show n
    | otherwise -> Right $ i2ospOf_ 32 n
  VAddress a -> Right $ B.replicate 12 0 <> unAddress a
  VFixedBytes bs
    | B.null bs || B.length bs > 32 -> Left $ "eip712: bytesN length " <> show (B.length bs)
    | otherwise -> Right $ bs <> B.replicate (32 - B.length bs) 0
  VBytes bs -> Right $ keccak256 bs
  VString s -> Right $ keccak256 s
  VArray vs -> keccak256 . B.concat <$> mapM encodeValue vs
  VStruct h
    | B.length h /= 32 -> Left $ "eip712: struct hash must be 32 bytes, got " <> show (B.length h)
    | otherwise -> Right h

hashStruct :: ByteString -> [Eip712Value] -> Either String ByteString
hashStruct typeString members = keccak256 . (keccak256 typeString <>) . B.concat <$> mapM encodeValue members

domainSeparator :: Eip712Domain -> Either String ByteString
domainSeparator Eip712Domain {edName, edVersion, edChainId, edVerifyingContract} =
  hashStruct
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    [VString edName, VString edVersion, VUint $ fromIntegral edChainId, VAddress edVerifyingContract]

hashTypedData :: Eip712Domain -> ByteString -> [Eip712Value] -> Either String ByteString
hashTypedData domain typeString members = do
  ds <- domainSeparator domain
  hs <- hashStruct typeString members
  pure $ keccak256 $ "\x19\x01" <> ds <> hs

serializeSignature :: RecoverableSignature -> ByteString
serializeSignature RecoverableSignature {rsR, rsS, rsRecId} = rsR <> rsS <> B.singleton (27 + rsRecId)
