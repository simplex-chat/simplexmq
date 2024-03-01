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

type CompressCtx = (Ptr Z.CCtx, Ptr CChar, Int)

withCompressCtx :: Int -> (CompressCtx -> IO a) -> IO a
withCompressCtx scratchSize action =
  bracket Z.createCCtx Z.freeCCtx $ \cctx ->
    allocaBytes scratchSize $ \scratchPtr ->
      action (cctx, scratchPtr, scratchSize)

compress :: CompressCtx -> ByteString -> IO (Either String Compressed)
compress (cctx, scratchPtr, scratchSize) bs
  | B.null bs = pure $ Right Empty
  | B.length bs < 192 = pure . Right $ Passthrough bs -- too short to bother
  | otherwise =
      B.unsafeUseAsCStringLen bs $ \(sourcePtr, sourceSize) -> do
        res <- Z.checkError $ Z.compressCCtx cctx scratchPtr (fromIntegral scratchSize) sourcePtr (fromIntegral sourceSize) 3
        case res of
          Left e -> pure $ Left e -- should not happen, unless input buff
          Right dstSize -> Right . Compressed . Large <$> B.packCStringLen (scratchPtr, fromIntegral dstSize)

type DecompressCtx = (Ptr Z.DCtx, Ptr CChar, CSize)

withDecompressCtx :: Int -> (DecompressCtx -> IO a) -> IO a
withDecompressCtx maxUnpackedSize action =
  bracket Z.createDCtx Z.freeDCtx $ \dctx ->
    allocaBytes maxUnpackedSize $ \scratchPtr ->
      action (dctx, scratchPtr, fromIntegral maxUnpackedSize)

decompress :: DecompressCtx -> Compressed -> IO (Either String ByteString)
decompress (dctx, scratchPtr, scratchSize) = \case
  Empty -> pure $ Right B.empty
  Passthrough bs -> pure $ Right bs
  Compressed (Large bs) ->
    B.unsafeUseAsCStringLen bs $ \(sourcePtr, sourceSize) -> do
      res <- Z.checkError $ Z.decompressDCtx dctx scratchPtr scratchSize sourcePtr (fromIntegral sourceSize)
      forM res $ \dstSize -> B.packCStringLen (scratchPtr, fromIntegral dstSize)

decompressBatch :: Int -> NonEmpty Compressed -> NonEmpty (Either String ByteString)
decompressBatch maxUnpackedSize items = unsafePerformIO $ withDecompressCtx maxUnpackedSize $ forM items . decompress
{-# NOINLINE decompressBatch #-} -- prevent double-evaluation under unsafePerformIO
