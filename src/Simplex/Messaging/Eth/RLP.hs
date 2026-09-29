{-# LANGUAGE LambdaCase #-}

-- | Recursive Length Prefix, the encoding of Ethereum transactions.
module Simplex.Messaging.Eth.RLP
  ( RLPItem (..),
    rlpEncode,
    rlpNatural,
  )
where

import Crypto.Number.Serialize (i2osp)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Numeric.Natural (Natural)

data RLPItem = RLPBytes ByteString | RLPList [RLPItem]

rlpEncode :: RLPItem -> ByteString
rlpEncode = \case
  RLPBytes b
    | [w] <- B.unpack b, w < 0x80 -> b
    | otherwise -> lengthPrefixed 0x80 b
  RLPList items -> lengthPrefixed 0xc0 $ B.concat $ map rlpEncode items
  where
    lengthPrefixed offset payload
      | len < 56 = B.cons (offset + fromIntegral len) payload
      | otherwise = B.cons (offset + 55 + fromIntegral (B.length lenBytes)) lenBytes <> payload
      where
        len = B.length payload
        lenBytes = i2osp $ toInteger len

-- | Big-endian with no leading zeros, and zero as the empty string.
rlpNatural :: Natural -> RLPItem
rlpNatural 0 = RLPBytes B.empty
rlpNatural n = RLPBytes $ i2osp $ toInteger n
