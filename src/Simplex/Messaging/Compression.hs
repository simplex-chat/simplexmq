{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Compression where

import qualified Codec.Compression.Zstd.FFI as Z
import Control.Exception (bracket)
import Control.Monad (forM)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as B
import Foreign
import Foreign.C.Types
import Simplex.Messaging.Encoding

data BatchItem
  = -- | Compressed output can sometimes be larger than the original due to headers etc. Send as-is when that happens.
    Passthrough ByteString
  | -- | Generic compression using no extra context.
    Compressed ByteString

instance Encoding BatchItem where
  smpEncode = \case
    Passthrough bytes -> "0" <> smpEncode (Large bytes)
    Compressed bytes -> "1" <> smpEncode (Large bytes)
  smpP =
    smpP >>= \case
      '0' -> Passthrough . unLarge <$> smpP
      '1' -> Compressed . unLarge <$> smpP
      x -> fail $ "unknown BatchItem tag: " <> show x

-- | Efficiently pack a collection of bytes.
batchPackZstd :: Traversable t => Int -> t ByteString -> IO (t BatchItem)
batchPackZstd scratchSize blocks = bracket Z.createCCtx Z.freeCCtx $ \cctx ->
  allocaBytes scratchSize $ \scratchBuf ->
    forM blocks $ \bs ->
      B.unsafeUseAsCStringLen bs $ \(sourcePtr, sourceSize) -> do
        res <- Z.checkError $ Z.compressCCtx cctx scratchBuf (fromIntegral scratchSize) sourcePtr (fromIntegral sourceSize) 3
        case res of
          Right dstSize | fromIntegral dstSize < B.length bs -> Compressed <$> B.packCStringLen (scratchBuf, fromIntegral dstSize)
          _ -> pure $ Passthrough bs

-- | Defensive unpacking of multiple similar buffers.
---
-- Can't just use library-provided wrappers as they trust decompressed size from header.
batchUnpackZstd :: Traversable t => Int -> t BatchItem -> IO (t (Either String ByteString))
batchUnpackZstd maxUnpackedSize items =
  bracket Z.createDCtx Z.freeDCtx $ \dctx ->
    allocaBytes maxUnpackedSize $ \scratchBuf ->
      forM items $ \case
        Passthrough bytes -> pure $ Right bytes
        Compressed bytes -> unpackZstd_ dctx scratchBuf bytes
  where
    scratchSize :: CSize
    scratchSize = fromIntegral maxUnpackedSize
    unpackZstd_ :: Ptr Z.DCtx -> Ptr CChar -> ByteString -> IO (Either String ByteString)
    unpackZstd_ dctx scratchBuf bs =
      B.unsafeUseAsCStringLen bs $ \(sourcePtr, sourceSize) -> do
        res <- Z.checkError $ Z.decompressDCtx dctx scratchBuf scratchSize sourcePtr (fromIntegral sourceSize)
        forM res $ \dstSize -> B.packCStringLen (scratchBuf, fromIntegral dstSize)
