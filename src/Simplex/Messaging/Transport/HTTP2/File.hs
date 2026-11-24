{-# LANGUAGE MultiWayIf #-}

module Simplex.Messaging.Transport.HTTP2.File
  ( fileBlockSize,
    receiveFileBlocks,
    hSendFile,
    getFileChunk,
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.ByteString.Builder (Builder, byteString)
import Data.Int (Int64)
import Data.Word (Word32)
import GHC.IO.Handle.Internals (ioe_EOF)
import System.IO (Handle)

fileBlockSize :: Int
fileBlockSize = 16384

receiveFileBlocks :: (Int -> IO ByteString) -> (ByteString -> IO ()) -> Word32 -> IO Int64
receiveFileBlocks _ _ 0 = pure 0
receiveFileBlocks getBody write size = get $ fromIntegral size
  where
    get sz = do
      ch <- getBody fileBlockSize
      let chSize = fromIntegral $ B.length ch
      if
        | chSize > sz -> pure (chSize - sz)
        | chSize > 0 -> write ch >> get (sz - chSize)
        | otherwise -> pure (-sz)

hSendFile :: Handle -> (Builder -> IO ()) -> Word32 -> IO ()
hSendFile h send = go
  where
    go 0 = pure ()
    go sz =
      getFileChunk h sz >>= \ch -> do
        send $ byteString ch
        go $ sz - fromIntegral (B.length ch)

getFileChunk :: Handle -> Word32 -> IO ByteString
getFileChunk h sz = do
  ch <- B.hGet h fileBlockSize
  if B.null ch
    then ioe_EOF
    else pure $ B.take (fromIntegral sz) ch -- sz >= xftpBlockSize
