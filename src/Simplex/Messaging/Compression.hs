{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Compression where

import qualified Codec.Compression.Zstd as Z1
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Simplex.Messaging.Encoding

data Compressed
  = -- | Short messages are left intact to skip copying and FFI festivities.
    Passthrough ByteString
  | -- | Generic compression using no extra context.
    Compressed Large

-- | Messages below this length are not encoded to avoid compression overhead.
maxLengthPassthrough :: Int
maxLengthPassthrough = 180 -- Sampled from real client data. Messages with length > 180 rapidly gain compression ratio.

compressionLevel :: Num a => a
compressionLevel = 3

instance Encoding Compressed where
  smpEncode = \case
    Passthrough bytes -> "0" <> smpEncode bytes
    Compressed bytes -> "1" <> smpEncode bytes
  smpP =
    smpP >>= \case
      '0' -> Passthrough <$> smpP
      '1' -> Compressed <$> smpP
      x -> fail $ "unknown Compressed tag: " <> show x

compress1 :: ByteString -> Compressed
compress1 bs
  | B.length bs <= maxLengthPassthrough = Passthrough bs
  | otherwise = Compressed . Large $ Z1.compress compressionLevel bs

decompress1 :: Int -> Compressed -> Either String ByteString
decompress1 limit = \case
  Passthrough bs -> Right bs
  Compressed (Large bs) -> case Z1.decompressedSize bs of
    Just sz | sz <= limit -> case Z1.decompress bs of
      Z1.Error e -> Left e
      Z1.Skip -> Right mempty
      Z1.Decompress bs' -> Right bs'
    _ -> Left $ "compressed size not specified or exceeds " <> show limit
