{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Redundant lambda" #-}

-- |
-- Module      : Data.ByteArray.ScrubbedBytes
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : Stable
-- Portability : GHC
module Simplex.Messaging.Crypto.Memory where

import GHC.Ptr
import GHC.Word
#if MIN_VERSION_base(4,15,0)
import           GHC.Exts (unsafeCoerce#)
#endif
import Data.ByteArray (ByteArray (..), ByteArrayAccess (..))
import Data.Foldable (toList)
import Data.Memory.PtrMethods
import Data.Semigroup
import Data.String (IsString (..))
import Data.Typeable
import Foreign.Storable
import GHC.Base
import GHC.IO (unsafeDupablePerformIO)

foreign import ccall "sodium_mlock"
  c_sodium_mlock :: Ptr () -> Int -> IO ()

foreign import ccall "sodium_munlock"
  c_sodium_munlock :: Ptr () -> Int -> IO ()

-- | LockedBytes is a memory chunk which have the properties of:
--
-- * Locked from going into swap on allocation.
-- * Unlocked and scrubbed scrubbed after its goes out of scope.
--
-- * A Show instance that doesn't actually show any content
--
-- * A Eq instance that is constant time
data LockedBytes = LockedBytes (MutableByteArray# RealWorld)
  deriving (Typeable)

instance Show LockedBytes where
  show _ = "<locked-bytes>"

instance Eq LockedBytes where
  (==) = scrubbedBytesEq
instance Ord LockedBytes where
  compare = scrubbedBytesCompare
#if MIN_VERSION_base(4,9,0)
instance Semigroup LockedBytes where
    b1 <> b2      = unsafeDupablePerformIO $ scrubbedBytesAppend b1 b2
    sconcat       = unsafeDupablePerformIO . scrubbedBytesConcat . toList
#endif
instance Monoid LockedBytes where
  mempty = unsafeDupablePerformIO (newLockedBytes 0)
#if !(MIN_VERSION_base(4,11,0))
    mappend b1 b2 = unsafeDupablePerformIO $ scrubbedBytesAppend b1 b2
    mconcat       = unsafeDupablePerformIO . scrubbedBytesConcat
#endif
-- instance NFData LockedBytes where
--     rnf b = b `seq` ()

instance IsString LockedBytes where
  fromString = scrubbedFromChar8

instance ByteArrayAccess LockedBytes where
  length = sizeofScrubbedBytes
  withByteArray = withPtr

instance ByteArray LockedBytes where
  allocRet = scrubbedBytesAllocRet

newLockedBytes :: Int -> IO LockedBytes
newLockedBytes (I# sz)
  | booleanPrim (sz <# 0#) = error "LockedBytes: size must be >= 0"
  | booleanPrim (sz ==# 0#) = IO $ \s ->
      case newAlignedPinnedByteArray# 0# 8# s of
        (# s2, mba #) -> (# s2, LockedBytes mba #)
  | otherwise = IO $ \s ->
      case newAlignedPinnedByteArray# sz 8# s of
        (# s1, mbarr #) ->
          let !locker = getLocker (byteArrayContents# (unsafeCoerce# mbarr))
              !scrubber = getScrubber (byteArrayContents# (unsafeCoerce# mbarr))
              !mba = LockedBytes mbarr
           in
            case mkWeak# mbarr () (finalize scrubber mba) (locker s1) of
                (# s2, _weak #) ->
                  (# s2, mba #)
  where
    getLocker :: Addr# -> State# RealWorld -> State# RealWorld
    getLocker addr s =
      let IO lockBytes = c_sodium_mlock (Ptr addr) (I# sz)
       in case lockBytes s of
            (# s', _ #) -> s'

    getScrubber :: Addr# -> State# RealWorld -> State# RealWorld
    getScrubber addr s =
      let IO scrubBytes = c_sodium_munlock (Ptr addr) (I# sz)
       in case scrubBytes s of
            (# s', _ #) -> s'

    finalize :: (State# RealWorld -> State# RealWorld) -> LockedBytes -> State# RealWorld -> (# State# RealWorld, () #)
    finalize scrubber mba@(LockedBytes _) = \s1 ->
      case scrubber s1 of
        s2 -> case touch# mba s2 of
          s3 -> (# s3, () #)

scrubbedBytesAllocRet :: Int -> (Ptr p -> IO a) -> IO (a, LockedBytes)
scrubbedBytesAllocRet sz f = do
  ba <- newLockedBytes sz
  r <- withPtr ba f
  return (r, ba)

scrubbedBytesAlloc :: Int -> (Ptr p -> IO ()) -> IO LockedBytes
scrubbedBytesAlloc sz f = do
  ba <- newLockedBytes sz
  withPtr ba f
  return ba

scrubbedBytesConcat :: [LockedBytes] -> IO LockedBytes
scrubbedBytesConcat l = scrubbedBytesAlloc retLen (copy l)
  where
    retLen = sum $ map sizeofScrubbedBytes l

    copy [] _ = return ()
    copy (x : xs) dst = do
      withPtr x $ \src -> memCopy dst src chunkLen
      copy xs (dst `plusPtr` chunkLen)
      where
        chunkLen = sizeofScrubbedBytes x

scrubbedBytesAppend :: LockedBytes -> LockedBytes -> IO LockedBytes
scrubbedBytesAppend b1 b2 = scrubbedBytesAlloc retLen $ \dst -> do
  withPtr b1 $ \s1 -> memCopy dst s1 len1
  withPtr b2 $ \s2 -> memCopy (dst `plusPtr` len1) s2 len2
  where
    len1 = sizeofScrubbedBytes b1
    len2 = sizeofScrubbedBytes b2
    retLen = len1 + len2

sizeofScrubbedBytes :: LockedBytes -> Int
sizeofScrubbedBytes (LockedBytes mba) = I# (sizeofMutableByteArray# mba)

withPtr :: LockedBytes -> (Ptr p -> IO a) -> IO a
withPtr b@(LockedBytes mba) f = do
  a <- f (Ptr (byteArrayContents# (unsafeCoerce# mba)))
  touchScrubbedBytes b
  return a

touchScrubbedBytes :: LockedBytes -> IO ()
touchScrubbedBytes (LockedBytes mba) = IO $ \s -> case touch# mba s of s' -> (# s', () #)

scrubbedBytesEq :: LockedBytes -> LockedBytes -> Bool
scrubbedBytesEq a b
  | l1 /= l2 = False
  | otherwise = unsafeDupablePerformIO $ withPtr a $ \p1 -> withPtr b $ \p2 -> memConstEqual p1 p2 l1
  where
    l1 = sizeofScrubbedBytes a
    l2 = sizeofScrubbedBytes b

scrubbedBytesCompare :: LockedBytes -> LockedBytes -> Ordering
scrubbedBytesCompare b1@(LockedBytes m1) b2@(LockedBytes m2) = unsafeDupablePerformIO $ loop 0
  where
    !l1 = sizeofScrubbedBytes b1
    !l2 = sizeofScrubbedBytes b2
    !len = min l1 l2

    loop !i
      | i == len =
          if l1 == l2
            then pure EQ
            else
              if l1 > l2
                then pure GT
                else pure LT
      | otherwise = do
          e1 <- read8 m1 i
          e2 <- read8 m2 i
          if e1 == e2
            then loop (i + 1)
            else
              if e1 < e2
                then pure LT
                else pure GT

    read8 m (I# i) = IO $ \s -> case readWord8Array# m i s of
      (# s2, e #) -> (# s2, W8# e #)

scrubbedFromChar8 :: [Char] -> LockedBytes
scrubbedFromChar8 l = unsafeDupablePerformIO $ scrubbedBytesAlloc len (fill l)
  where
    len = Prelude.length l
    fill :: [Char] -> Ptr Word8 -> IO ()
    fill [] _ = return ()
    fill (x : xs) !p = poke p (fromIntegral $ fromEnum x) >> fill xs (p `plusPtr` 1)

booleanPrim :: Int# -> Bool
booleanPrim v = tagToEnum# v
