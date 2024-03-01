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

data Compressed
  = -- | Can be used as traversal placeholders to retain structure.
    Empty
  | -- | Short messages are left intact to skip copying and FFI festivities.
    Passthrough ByteString
  | -- | Generic compression using no extra context.
    Compressed Large

instance Encoding Compressed where
  smpEncode = \case
    Empty -> "_"
    Passthrough bytes -> "0" <> smpEncode bytes
    Compressed bytes -> "1" <> smpEncode bytes
  smpP =
    smpP >>= \case
      '_' -> pure Empty
      '0' -> Passthrough <$> smpP
      '1' -> Compressed <$> smpP
      x -> fail $ "unknown Compressed tag: " <> show x

type PackCtx = (Ptr Z.CCtx, Ptr CChar, Int)

withPackCtx :: Int -> (PackCtx -> IO a) -> IO a
withPackCtx scratchSize action =
  bracket Z.createCCtx Z.freeCCtx $ \cctx ->
    allocaBytes scratchSize $ \scratchPtr ->
      action (cctx, scratchPtr, scratchSize)

compress :: PackCtx -> ByteString -> IO (Either String Compressed)
compress (cctx, scratchPtr, scratchSize) bs
  | B.null bs = pure $ Right Empty
  | B.length bs < 192 = pure . Right $ Passthrough bs -- too short to bother
  | otherwise =
      B.unsafeUseAsCStringLen bs $ \(sourcePtr, sourceSize) -> do
        res <- Z.checkError $ Z.compressCCtx cctx scratchPtr (fromIntegral scratchSize) sourcePtr (fromIntegral sourceSize) 3
        case res of
          Left e -> pure $ Left e -- should not happen, unless input buff
          Right dstSize -> Right . Compressed . Large <$> B.packCStringLen (scratchPtr, fromIntegral dstSize)

-- | Defensive unpacking of multiple similar buffers.
--
-- Can't just use library-provided wrappers as they trust decompressed size from header.
batchUnpackZstd :: Int -> NonEmpty Compressed -> NonEmpty (Either String ByteString)
batchUnpackZstd maxUnpackedSize items =
  unsafePerformIO $
    bracket Z.createDCtx Z.freeDCtx $ \dctx ->
      allocaBytes maxUnpackedSize $ \scratchBuf ->
        forM items $ \case
          Empty -> pure $ Right mempty
          Passthrough bytes -> pure $ Right bytes
          Compressed (Large bytes) -> unpackZstd_ dctx scratchBuf bytes
  where
    scratchSize :: CSize
    scratchSize = fromIntegral maxUnpackedSize
    unpackZstd_ :: Ptr Z.DCtx -> Ptr CChar -> ByteString -> IO (Either String ByteString)
    unpackZstd_ dctx scratchBuf bs =
      B.unsafeUseAsCStringLen bs $ \(sourcePtr, sourceSize) -> do
        res <- Z.checkError $ Z.decompressDCtx dctx scratchBuf scratchSize sourcePtr (fromIntegral sourceSize)
        forM res $ \dstSize -> B.packCStringLen (scratchBuf, fromIntegral dstSize)
{-# NOINLINE batchUnpackZstd #-} -- prevent double-evaluation under unsafePerformIO
