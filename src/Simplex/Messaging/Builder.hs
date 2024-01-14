{-# LANGUAGE StrictData #-}

module Simplex.Messaging.Builder
  ( Builder (length, builder),
    byteString,
    lazyByteString,
    word16BE,
    char8,
    toLazyByteString,
  )
where

import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as LB
import Data.Word (Word16)


-- length-aware builder
data Builder = Builder {length :: Int, builder :: BB.Builder}

unsafeBuilder :: Int -> BB.Builder -> Builder
unsafeBuilder = Builder
{-# INLINE unsafeBuilder #-}

instance Semigroup Builder where
  Builder l1 b1 <> Builder l2 b2 = Builder (l1 + l2) (b1 <> b2)
  {-# INLINE (<>) #-}

instance Monoid Builder where
  mempty = Builder 0 mempty
  {-# INLINE mempty #-}
  mconcat bldrs = Builder (sum ls) (mconcat bs)
    where
      (ls, bs) = foldr (\(Builder l b) ~(ls, bs) -> (l : ls, b : bs)) ([], []) bldrs
  {-# INLINE mconcat #-}

byteString :: B.ByteString -> Builder
byteString s = Builder (B.length s) (BB.byteString s)
{-# INLINE byteString #-}

lazyByteString :: LB.ByteString -> Builder
lazyByteString s = Builder (fromIntegral $ LB.length s) (BB.lazyByteString s)
{-# INLINE lazyByteString #-}

word16BE :: Word16 -> Builder
word16BE = Builder 2 . BB.word16BE
{-# INLINE word16BE #-}

char8 :: Char -> Builder
char8 = Builder 1 . BB.char8
{-# INLINE char8 #-}

toLazyByteString :: Builder -> LB.ByteString
toLazyByteString = BB.toLazyByteString . builder
{-# INLINE toLazyByteString #-}
