{-# LANGUAGE MultiWayIf #-}

module Simplex.Messaging.Transport.HTTP2.File where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.ByteString.Builder (Builder, byteString)
import Data.Int (Int64)
import Data.Word (Word32)
import GHC.IO.Handle.Internals (ioe_EOF)
import System.IO (Handle)

fileBlockSize :: Int
fileBlockSize = 16384

hReceiveFile :: (Int -> IO ByteString) -> Handle -> Word32 -> IO Int64
hReceiveFile _ _ 0 = pure 0
hReceiveFile getBody h size = get $ fromIntegral size
  where
    get sz = do
      ch <- getBody fileBlockSize
      let chSize = fromIntegral $ B.length ch
      if
        | chSize > sz -> pure (chSize - sz)
        | chSize > 0 -> B.hPut h ch >> get (sz - chSize)
        | otherwise -> pure (-fromIntegral sz)

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
