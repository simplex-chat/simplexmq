{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Simplex.Messaging.Encoding (Encoding (..), Tail (..)) where

import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bits (shiftL, shiftR, (.|.))
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.ByteString.Internal (c2w, w2c)
import Data.Int (Int64)
import Data.Time.Clock.System (SystemTime (..))
import Data.Word (Word16, Word32)
import Network.Transport.Internal (decodeWord16, decodeWord32, encodeWord16, encodeWord32)

class Encoding a where
  smpEncode :: a -> ByteString
  smpP :: Parser a

instance Encoding Char where
  smpEncode = B.singleton
  smpP = A.anyChar

instance Encoding Word16 where
  smpEncode = encodeWord16
  smpP = decodeWord16 <$> A.take 2

instance Encoding Word32 where
  smpEncode = encodeWord32
  smpP = decodeWord32 <$> A.take 4

instance Encoding Int64 where
  smpEncode i = w32 (i `shiftR` 32) <> w32 i
  smpP = do
    l <- w32P
    r <- w32P
    pure $ (l `shiftL` 32) .|. r

w32 :: Int64 -> ByteString
w32 = smpEncode @Word32 . fromIntegral

w32P :: Parser Int64
w32P = fromIntegral <$> smpP @Word32

-- ByteStrings are assumed no longer than 255 bytes
instance Encoding ByteString where
  smpEncode s = B.cons (w2c len) s where len = fromIntegral $ B.length s
  smpP = A.take . fromIntegral . c2w =<< A.anyChar

newtype Tail = Tail {unTail :: ByteString}

instance Encoding Tail where
  smpEncode = unTail
  smpP = Tail <$> A.takeByteString

instance Encoding SystemTime where
  smpEncode = smpEncode . systemSeconds
  smpP = MkSystemTime <$> smpP <*> pure 0

instance (Encoding a, Encoding b) => Encoding (a, b) where
  smpEncode (a, b) = smpEncode a <> smpEncode b
  smpP = (,) <$> smpP <*> smpP

instance (Encoding a, Encoding b, Encoding c) => Encoding (a, b, c) where
  smpEncode (a, b, c) = smpEncode a <> smpEncode b <> smpEncode c
  smpP = (,,) <$> smpP <*> smpP <*> smpP

instance (Encoding a, Encoding b, Encoding c, Encoding d) => Encoding (a, b, c, d) where
  smpEncode (a, b, c, d) = smpEncode a <> smpEncode b <> smpEncode c <> smpEncode d
  smpP = (,,,) <$> smpP <*> smpP <*> smpP <*> smpP

instance (Encoding a, Encoding b, Encoding c, Encoding d, Encoding e) => Encoding (a, b, c, d, e) where
  smpEncode (a, b, c, d, e) = smpEncode a <> smpEncode b <> smpEncode c <> smpEncode d <> smpEncode e
  smpP = (,,,,) <$> smpP <*> smpP <*> smpP <*> smpP <*> smpP
