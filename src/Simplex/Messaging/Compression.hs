{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Compression where

import qualified Codec.Compression.Zstd as Z1
import qualified Codec.Compression.Zstd.FFI as Z
import Control.Monad (forM)
import Control.Monad.Except
import Control.Monad.IO.Class
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as B
import Data.Either (fromRight)
import Data.List.NonEmpty (NonEmpty)
import Foreign
import Foreign.C.Types
import GHC.IO (unsafePerformIO)
import Simplex.Messaging.Encoding
import UnliftIO.Exception (bracket)

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

-- | Compress as single chunk using stack-allocated context.
compress1 :: ByteString -> Compressed
compress1 bs
  | B.length bs <= maxLengthPassthrough = Passthrough bs
  | otherwise = Compressed . Large $ Z1.compress compressionLevel bs

type CompressCtx = (Ptr Z.CCtx, Ptr CChar, CSize)

withCompressCtx :: CSize -> (CompressCtx -> IO a) -> IO a
withCompressCtx scratchSize = bracket (createCompressCtx scratchSize) freeCompressCtx

createCompressCtx :: CSize -> IO CompressCtx
createCompressCtx scratchSize = do
  ctx <- Z.createCCtx
  scratch <- mallocBytes (fromIntegral scratchSize)
  pure (ctx, scratch, scratchSize)

freeCompressCtx :: CompressCtx -> IO ()
freeCompressCtx (ctx, scratch, _) = do
  free scratch
  Z.freeCCtx ctx

-- | Compress bytes, falling back to Passthrough in case of some internal error.
compress :: CompressCtx -> ByteString -> IO Compressed
compress ctx bs = fromRight (Passthrough bs) <$> compress_ ctx bs

compress_ :: CompressCtx -> ByteString -> IO (Either String Compressed)
compress_ (cctx, scratchPtr, scratchSize) bs
  | B.length bs <= maxLengthPassthrough = pure . Right $ Passthrough bs
  | otherwise =
      B.unsafeUseAsCStringLen bs $ \(sourcePtr, sourceSize) -> runExceptT $ do
        -- should not fail, unless input buffer is too short
        dstSize <- ExceptT $ Z.checkError $ Z.compressCCtx cctx scratchPtr scratchSize sourcePtr (fromIntegral sourceSize) compressionLevel
        liftIO $ Compressed . Large <$> B.packCStringLen (scratchPtr, fromIntegral dstSize)

type DecompressCtx = (Ptr Z.DCtx, Ptr CChar, CSize)

withDecompressCtx :: Int -> (DecompressCtx -> IO a) -> IO a
withDecompressCtx maxUnpackedSize action =
  bracket Z.createDCtx Z.freeDCtx $ \dctx ->
    allocaBytes maxUnpackedSize $ \scratchPtr ->
      action (dctx, scratchPtr, fromIntegral maxUnpackedSize)

decompress :: DecompressCtx -> Compressed -> IO (Either String ByteString)
decompress (dctx, scratchPtr, scratchSize) = \case
  Passthrough bs -> pure $ Right bs
  Compressed (Large bs) ->
    B.unsafeUseAsCStringLen bs $ \(sourcePtr, sourceSize) -> do
      res <- Z.checkError $ Z.decompressDCtx dctx scratchPtr scratchSize sourcePtr (fromIntegral sourceSize)
      forM res $ \dstSize -> B.packCStringLen (scratchPtr, fromIntegral dstSize)

decompressBatch :: Int -> NonEmpty Compressed -> NonEmpty (Either String ByteString)
decompressBatch maxUnpackedSize items = unsafePerformIO $ withDecompressCtx maxUnpackedSize $ forM items . decompress
{-# NOINLINE decompressBatch #-} -- prevent double-evaluation under unsafePerformIO
