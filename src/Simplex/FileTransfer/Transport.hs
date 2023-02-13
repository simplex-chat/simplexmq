{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.FileTransfer.Transport
  ( supportedFileServerVRange,
    sendFile,
    receiveFile,
  )
where

import Control.Monad.Except
import Data.ByteString.Builder (Builder, byteString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import GHC.IO.Handle.Internals (ioe_EOF)
import Simplex.FileTransfer.Protocol (xftpBlockSize)
import Simplex.Messaging.Version
import System.IO (Handle)

supportedFileServerVRange :: VersionRange
supportedFileServerVRange = mkVersionRange 1 1

sendFile :: Handle -> (Builder -> IO ()) -> Int -> IO ()
sendFile _ _ 0 = pure ()
sendFile h send sz = do
  B.hGet h xftpBlockSize >>= \case
    "" -> when (sz /= 0) ioe_EOF
    ch -> do
      let ch' = B.take sz ch -- sz >= xftpBlockSize
      send (byteString ch')
      sendFile h send $ sz - B.length ch'

-- TODO instead of receiving the whole file this function should stop at size and return error if file is larger
receiveFile :: Handle -> (Int -> IO ByteString) -> Int -> IO Int
receiveFile h receive sz = do
  ch <- receive xftpBlockSize
  let chSize = B.length ch
  if chSize > 0
    then B.hPut h ch >> receiveFile h receive (sz + chSize)
    else pure sz
