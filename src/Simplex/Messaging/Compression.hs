{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Compression where

import qualified Codec.Compression.Zstd.FFI as Z
import Control.Monad (forM)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as B
import Data.List.NonEmpty (NonEmpty)
import Foreign
import Foreign.C.Types
import GHC.IO (unsafePerformIO)
import Simplex.Messaging.Encoding
import UnliftIO.Exception (bracket)
import Foreign.C (CStringLen)

data BatchItem
  = Empty
  | -- | Compressed output can sometimes be larger than the original due to headers etc. Send as-is when that happens.
    Passthrough ByteString
  | -- | Generic compression using no extra context.
    Compressed ByteString

instance Encoding BatchItem where
  smpEncode = \case
    Empty -> "_"
    Passthrough bytes -> "0" <> smpEncode bytes
    Compressed bytes -> "1" <> smpEncode (Large bytes)
  smpP =
    smpP >>= \case
      '_' -> pure Empty
      '0' -> Passthrough <$> smpP
      '1' -> Compressed . unLarge <$> smpP
      x -> fail $ "unknown BatchItem tag: " <> show x

withPackCtx :: Int -> (Ptr Z.CCtx -> CStringLen -> IO a) -> IO a
withPackCtx scratchSize action =
  bracket Z.createCCtx Z.freeCCtx $ \cctx ->
    allocaBytes scratchSize $ \scratchPtr ->
      action cctx (scratchPtr, scratchSize)

-- | Efficiently pack a collection of bytes.
batchPackZstd :: Int -> NonEmpty ByteString -> NonEmpty BatchItem
batchPackZstd scratchSize blocks =
  unsafePerformIO $
    withPackCtx scratchSize $ \cctx scratchBuf ->
      mapM (packZstd cctx scratchBuf) blocks
{-# NOINLINE batchPackZstd #-}

packZstd :: Ptr Z.CCtx -> CStringLen -> ByteString -> IO BatchItem
packZstd cctx (scratchPtr, scratchSize) bs
  | B.null bs = pure Empty
  | otherwise =
      B.unsafeUseAsCStringLen bs $ \(sourcePtr, sourceSize) -> do
        res <- Z.checkError $ Z.compressCCtx cctx scratchPtr (fromIntegral scratchSize) sourcePtr (fromIntegral sourceSize) 3
        case res of
          Right dstSize | fromIntegral dstSize < B.length bs -> Compressed <$> B.packCStringLen (scratchPtr, fromIntegral dstSize)
          _ -> pure $ Passthrough bs

-- | Defensive unpacking of multiple similar buffers.
--
-- Can't just use library-provided wrappers as they trust decompressed size from header.
batchUnpackZstd :: Int -> NonEmpty BatchItem -> NonEmpty (Either String ByteString)
batchUnpackZstd maxUnpackedSize items =
  unsafePerformIO $
    bracket Z.createDCtx Z.freeDCtx $ \dctx ->
      allocaBytes maxUnpackedSize $ \scratchBuf ->
        forM items $ \case
          Empty -> pure $ Right mempty
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
{-# NOINLINE batchUnpackZstd #-}
