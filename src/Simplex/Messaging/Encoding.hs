{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Simplex.Messaging.Encoding where

import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.ByteString.Internal (c2w, w2c)
import Data.Time.Clock (UTCTime)
import Data.Time.ISO8601 (formatISO8601Millis, parseISO8601)
import Data.Word (Word16, Word32, Word8)
import Network.Transport.Internal (decodeWord16, decodeWord32, encodeWord16, encodeWord32)
import Simplex.Messaging.Util (ifM)

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

-- ByteStrings are assumed no longer than 255 bytes
instance Encoding ByteString where
  smpEncode s =
    let len = fromIntegral $ B.length s :: Word8
     in B.cons (w2c len) s
  smpP = A.take . fromIntegral . c2w =<< A.anyChar

newtype LargeBS = LargeBS {unLargeBS :: ByteString}

instance Encoding LargeBS where
  smpEncode (LargeBS s) =
    let len = fromIntegral $ B.length s :: Word16
     in smpEncode len <> s
  smpP = LargeBS <$> (A.take . fromIntegral . decodeWord16 =<< A.take 2)

instance Encoding UTCTime where
  smpEncode = B.pack . formatISO8601Millis
  {-# INLINE smpEncode #-}
  smpP = maybe (fail "timestamp") pure . parseISO8601 . B.unpack =<< A.take 24

instance forall a. Encoding a => Encoding [a] where
  smpEncode = mconcat . map smpEncode
  smpP = listP []
    where
      listP :: [a] -> Parser [a]
      listP xs = ifM A.atEnd (pure $ reverse xs) (smpP >>= listP . (: xs))

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
