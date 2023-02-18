{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.FileTransfer.Transport
  ( supportedFileServerVRange,
    sendFile,
    receiveFile,
  )
where

import Data.ByteString.Builder (Builder, byteString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Word (Word32)
import GHC.IO.Handle.Internals (ioe_EOF)
import Simplex.FileTransfer.Protocol (XFTPErrorType (..), xftpBlockSize)
import Simplex.Messaging.Version
import System.IO (Handle)

supportedFileServerVRange :: VersionRange
supportedFileServerVRange = mkVersionRange 1 1

sendFile :: Handle -> (Builder -> IO ()) -> Word32 -> IO ()
sendFile h send = go
  where
    go 0 = pure ()
    go sz =
      B.hGet h xftpBlockSize >>= \case
        "" -> ioe_EOF
        ch -> do
          let ch' = B.take (fromIntegral sz) ch -- sz >= xftpBlockSize
          send $ byteString ch'
          go $ sz - fromIntegral (B.length ch')

receiveFile :: Handle -> (Int -> IO ByteString) -> Word32 -> IO (Either XFTPErrorType ())
receiveFile h receive = go
  where
    go sz = do
      ch <- receive xftpBlockSize
      let chSize = fromIntegral $ B.length ch
      if
          | chSize > sz -> pure $ Left SIZE
          | chSize > 0 -> B.hPut h ch >> go (sz - chSize)
          | sz == 0 -> pure $ Right ()
          | otherwise -> pure $ Left SIZE
