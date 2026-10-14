{-# LANGUAGE LambdaCase #-}

-- | Recursive Length Prefix, the encoding of Ethereum transactions.
module Simplex.Messaging.Eth.RLP
  ( RLPItem (..),
    rlpEncode,
    scalarItem,
  )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Word (Word32)
import Simplex.Messaging.Encoding (smpEncode)

data RLPItem = RLPBytes ByteString | RLPList [RLPItem]

rlpEncode :: RLPItem -> ByteString
rlpEncode = \case
  RLPBytes b
    | B.length b == 1 && B.head b < 0x80 -> b
    | otherwise -> lengthPrefixed 0x80 b
  RLPList items -> lengthPrefixed 0xc0 $ B.concat $ map rlpEncode items
  where
    lengthPrefixed offset payload
      | len < 56 = B.cons (offset + fromIntegral len) payload
      | otherwise = B.cons (offset + 55 + fromIntegral (B.length lenBytes)) lenBytes <> payload
      where
        len = B.length payload
        lenBytes = B.dropWhile (== 0) $ smpEncode (fromIntegral len :: Word32)

-- | Big-endian with no leading zeros, and zero as the empty string.
scalarItem :: ByteString -> RLPItem
scalarItem = RLPBytes . B.dropWhile (== 0)
