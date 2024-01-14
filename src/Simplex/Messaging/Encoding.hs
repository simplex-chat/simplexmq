{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Simplex.Messaging.Encoding
  ( Encoding (..),
    Tail (..),
    Large (..),
    _smpP,
    smpEncodeList,
    smpListP,
    lenEncode,
  )
where

import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bits (shiftL, shiftR, (.|.))
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.ByteString.Internal (c2w, w2c)
import Data.Int (Int64)
import qualified Data.List.NonEmpty as L
import Data.Time.Clock.System (SystemTime (..))
import Data.Word (Word16, Word32)
import Network.Transport.Internal (decodeWord16, decodeWord32, encodeWord16, encodeWord32)
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Util ((<$?>))

-- | SMP protocol encoding
class Encoding a where
  {-# MINIMAL smpEncode, (smpDecode | smpP) #-}

  -- | protocol encoding of type (default implementation uses protocol ByteString encoding)
  smpEncode :: a -> ByteString

  -- | decoding of type (default implementation uses parser)
  smpDecode :: ByteString -> Either String a
  smpDecode = parseAll smpP

  -- | protocol parser of type (default implementation parses protocol ByteString encoding)
  smpP :: Parser a
  smpP = smpDecode <$?> smpP

instance Encoding Char where
  smpEncode = B.singleton
  {-# INLINE smpEncode #-}
  smpP = A.anyChar
  {-# INLINE smpP #-}

instance Encoding Bool where
  smpEncode = \case
    True -> "T"
    False -> "F"
  {-# INLINE smpEncode #-}
  smpP =
    smpP >>= \case
      'T' -> pure True
      'F' -> pure False
      _ -> fail "invalid Bool"
  {-# INLINE smpP #-}

instance Encoding Word16 where
  smpEncode = encodeWord16
  {-# INLINE smpEncode #-}
  smpP = decodeWord16 <$> A.take 2
  {-# INLINE smpP #-}

instance Encoding Word32 where
  smpEncode = encodeWord32
  {-# INLINE smpEncode #-}
  smpP = decodeWord32 <$> A.take 4
  {-# INLINE smpP #-}

instance Encoding Int64 where
  smpEncode i = w32 (i `shiftR` 32) <> w32 i
  {-# INLINE smpEncode #-}
  smpP = do
    l <- w32P
    r <- w32P
    pure $ (l `shiftL` 32) .|. r
  {-# INLINE smpP #-}

w32 :: Int64 -> ByteString
w32 = smpEncode @Word32 . fromIntegral
{-# INLINE w32 #-}

w32P :: Parser Int64
w32P = fromIntegral <$> smpP @Word32
{-# INLINE w32P #-}

-- ByteStrings are assumed no longer than 255 bytes
instance Encoding ByteString where
  smpEncode s = B.cons (lenEncode $ B.length s) s
  {-# INLINE smpEncode #-}
  smpP = A.take =<< lenP
  {-# INLINE smpP #-}

lenEncode :: Int -> Char
lenEncode = w2c . fromIntegral
{-# INLINE lenEncode #-}

lenP :: Parser Int
lenP = fromIntegral . c2w <$> A.anyChar
{-# INLINE lenP #-}

instance Encoding a => Encoding (Maybe a) where
  smpEncode = maybe "0" (("1" <>) . smpEncode)
  {-# INLINE smpEncode #-}
  smpP =
    smpP >>= \case
      '0' -> pure Nothing
      '1' -> Just <$> smpP
      _ -> fail "invalid Maybe tag"
  {-# INLINE smpP #-}

newtype Tail = Tail {unTail :: ByteString}

instance Encoding Tail where
  smpEncode = unTail
  {-# INLINE smpEncode #-}
  smpP = Tail <$> A.takeByteString
  {-# INLINE smpP #-}

-- newtype for encoding/decoding ByteStrings over 255 bytes with 2-bytes length prefix
newtype Large = Large {unLarge :: ByteString}

instance Encoding Large where
  smpEncode (Large s) = smpEncode @Word16 (fromIntegral $ B.length s) <> s
  {-# INLINE smpEncode #-}
  smpP = do
    len <- fromIntegral <$> smpP @Word16
    Large <$> A.take len
  {-# INLINE smpP #-}

instance Encoding SystemTime where
  smpEncode = smpEncode . systemSeconds
  {-# INLINE smpEncode #-}
  smpP = MkSystemTime <$> smpP <*> pure 0
  {-# INLINE smpP #-}

_smpP :: Encoding a => Parser a
_smpP = A.space *> smpP

-- lists encode/parse as a sequence of items prefixed with list length (as 1 byte)
smpEncodeList :: Encoding a => [a] -> ByteString
smpEncodeList xs = B.cons (lenEncode $ length xs) . B.concat $ map smpEncode xs

smpListP :: Encoding a => Parser [a]
smpListP = (`A.count` smpP) =<< lenP

instance Encoding String where
  smpEncode = smpEncode . B.pack
  {-# INLINE smpEncode #-}
  smpP = B.unpack <$> smpP
  {-# INLINE smpP #-}

instance Encoding a => Encoding (L.NonEmpty a) where
  smpEncode = smpEncodeList . L.toList
  smpP =
    lenP >>= \case
      0 -> fail "empty list"
      n -> L.fromList <$> A.count n smpP

instance (Encoding a, Encoding b) => Encoding (a, b) where
  smpEncode (a, b) = smpEncode a <> smpEncode b
  {-# INLINE smpEncode #-}
  smpP = (,) <$> smpP <*> smpP
  {-# INLINE smpP #-}

instance (Encoding a, Encoding b, Encoding c) => Encoding (a, b, c) where
  smpEncode (a, b, c) = smpEncode a <> smpEncode b <> smpEncode c
  {-# INLINE smpEncode #-}
  smpP = (,,) <$> smpP <*> smpP <*> smpP
  {-# INLINE smpP #-}

instance (Encoding a, Encoding b, Encoding c, Encoding d) => Encoding (a, b, c, d) where
  smpEncode (a, b, c, d) = smpEncode a <> smpEncode b <> smpEncode c <> smpEncode d
  {-# INLINE smpEncode #-}
  smpP = (,,,) <$> smpP <*> smpP <*> smpP <*> smpP
  {-# INLINE smpP #-}

instance (Encoding a, Encoding b, Encoding c, Encoding d, Encoding e) => Encoding (a, b, c, d, e) where
  smpEncode (a, b, c, d, e) = smpEncode a <> smpEncode b <> smpEncode c <> smpEncode d <> smpEncode e
  {-# INLINE smpEncode #-}
  smpP = (,,,,) <$> smpP <*> smpP <*> smpP <*> smpP <*> smpP
  {-# INLINE smpP #-}

instance (Encoding a, Encoding b, Encoding c, Encoding d, Encoding e, Encoding f) => Encoding (a, b, c, d, e, f) where
  smpEncode (a, b, c, d, e, f) = smpEncode a <> smpEncode b <> smpEncode c <> smpEncode d <> smpEncode e <> smpEncode f
  {-# INLINE smpEncode #-}
  smpP = (,,,,,) <$> smpP <*> smpP <*> smpP <*> smpP <*> smpP <*> smpP
  {-# INLINE smpP #-}

instance (Encoding a, Encoding b, Encoding c, Encoding d, Encoding e, Encoding f, Encoding g) => Encoding (a, b, c, d, e, f, g) where
  smpEncode (a, b, c, d, e, f, g) = smpEncode a <> smpEncode b <> smpEncode c <> smpEncode d <> smpEncode e <> smpEncode f <> smpEncode g
  {-# INLINE smpEncode #-}
  smpP = (,,,,,,) <$> smpP <*> smpP <*> smpP <*> smpP <*> smpP <*> smpP <*> smpP
  {-# INLINE smpP #-}

instance (Encoding a, Encoding b, Encoding c, Encoding d, Encoding e, Encoding f, Encoding g, Encoding h) => Encoding (a, b, c, d, e, f, g, h) where
  smpEncode (a, b, c, d, e, f, g, h) = smpEncode a <> smpEncode b <> smpEncode c <> smpEncode d <> smpEncode e <> smpEncode f <> smpEncode g <> smpEncode h
  {-# INLINE smpEncode #-}
  smpP = (,,,,,,,) <$> smpP <*> smpP <*> smpP <*> smpP <*> smpP <*> smpP <*> smpP <*> smpP
  {-# INLINE smpP #-}
