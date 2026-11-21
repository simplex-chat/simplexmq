{-# LANGUAGE LambdaCase #-}

-- | Recursive Length Prefix, the encoding of Ethereum transactions.
module Simplex.Messaging.Eth.RLP
  ( RLPItem (..),
    scalarItem,
  )
where

import Control.Monad (when)
import qualified Data.Attoparsec.ByteString as A
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Word (Word32, Word8)
import Simplex.Messaging.Encoding (Encoding (..))
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Util ((<$?>))

data RLPItem = RLPBytes ByteString | RLPList [RLPItem]

instance Encoding RLPItem where
  smpEncode = \case
    RLPBytes b
      | B.length b == 1 && B.head b < 0x80 -> b
      | otherwise -> lengthPrefixed 0x80 b
    RLPList items -> lengthPrefixed 0xc0 $ B.concat $ map smpEncode items
    where
      lengthPrefixed offset payload
        | len < 56 = B.cons (offset + fromIntegral len) payload
        | otherwise = B.cons (offset + 55 + fromIntegral (B.length lenBytes)) lenBytes <> payload
        where
          len = B.length payload
          lenBytes = B.dropWhile (== 0) $ smpEncode (fromIntegral len :: Word32)
  smpP = A.anyWord8 >>= item
    where
      item :: Word8 -> A.Parser RLPItem
      item prefix
        | prefix < 0x80 = pure $ RLPBytes $ B.singleton prefix
        | prefix <= 0xb7 = shortBytes $ fromIntegral $ prefix - 0x80
        | prefix < 0xc0 = RLPBytes <$> (longLength (prefix - 0xb7) >>= A.take)
        | prefix <= 0xf7 = RLPList <$> items (fromIntegral $ prefix - 0xc0)
        | otherwise = RLPList <$> (longLength (prefix - 0xf7) >>= items)
      shortBytes n =
        A.take n >>= \b -> case B.unpack b of
          [w] | w < 0x80 -> fail "RLP: a byte below 0x80 with a prefix"
          _ -> pure $ RLPBytes b
      longLength n = do
        when (n > 4) $ fail "RLP: a length over 32 bits"
        lenBytes <- A.take $ fromIntegral n
        when (B.take 1 lenBytes == B.singleton 0) $ fail "RLP: a length with a leading zero"
        let len = B.foldl' (\l w -> l * 256 + fromIntegral w) 0 lenBytes
        when (len < 56) $ fail "RLP: a long form of a short length"
        pure len
      items n = parseAll (A.many' smpP) <$?> A.take n

-- | Big-endian with no leading zeros, and zero as the empty string.
scalarItem :: ByteString -> RLPItem
scalarItem = RLPBytes . B.dropWhile (== 0)
