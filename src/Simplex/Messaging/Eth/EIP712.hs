{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Eth.EIP712
  ( Eip712Domain (..),
    Eip712Value (..),
    hashTypedData,
    serializeSignature,
  )
where

import Crypto.Number.Serialize (i2ospOf_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.WideWord.Word256 (Word256)
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
  = VUint Word256
  | VAddress Address
  | VBytes ByteString
  | VArray [Eip712Value]

encodeValue :: Eip712Value -> ByteString
encodeValue = \case
  VUint n -> i2ospOf_ 32 $ toInteger n
  VAddress a -> B.replicate 12 0 <> unAddress a
  VBytes bs -> keccak256 bs
  VArray vs -> keccak256 $ B.concat $ map encodeValue vs

hashStruct :: ByteString -> [Eip712Value] -> ByteString
hashStruct typeString members = keccak256 $ keccak256 typeString <> B.concat (map encodeValue members)

domainSeparator :: Eip712Domain -> ByteString
domainSeparator Eip712Domain {edName, edVersion, edChainId, edVerifyingContract} =
  hashStruct
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    [VBytes edName, VBytes edVersion, VUint $ fromIntegral edChainId, VAddress edVerifyingContract]

hashTypedData :: Eip712Domain -> ByteString -> [Eip712Value] -> ByteString
hashTypedData domain typeString members = keccak256 $ "\x19\x01" <> domainSeparator domain <> hashStruct typeString members

serializeSignature :: RecoverableSignature -> ByteString
serializeSignature RecoverableSignature {rsR, rsS, rsRecId} = rsR <> rsS <> B.singleton (27 + rsRecId)
