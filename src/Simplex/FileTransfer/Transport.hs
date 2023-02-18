{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.FileTransfer.Transport
  ( supportedFileServerVRange,
    XFTPRcvChunkSpec (..),
    sendFile,
    receiveFile,
  )
where

import Control.Monad.Except
import Data.ByteString.Builder (Builder, byteString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Word (Word32)
import GHC.IO.Handle.Internals (ioe_EOF)
import Simplex.FileTransfer.Protocol (XFTPErrorType (..), xftpBlockSize)
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Version
import System.IO (Handle, IOMode (..), withFile)

data XFTPRcvChunkSpec = XFTPRcvChunkSpec
  { filePath :: FilePath,
    chunkSize :: Word32,
    chunkDigest :: ByteString
  }
  deriving (Show)

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

receiveFile :: (Int -> IO ByteString) -> XFTPRcvChunkSpec -> ExceptT XFTPErrorType IO ()
receiveFile getBody XFTPRcvChunkSpec {filePath, chunkSize, chunkDigest} = do
  ExceptT $ withFile filePath WriteMode (`receive` chunkSize)
  digest' <- liftIO $ LC.sha512Hash <$> LB.readFile filePath
  when (digest' /= chunkDigest) $ throwError DIGEST
  where
    receive h sz = do
      ch <- getBody xftpBlockSize
      let chSize = fromIntegral $ B.length ch
      if
          | chSize > sz -> pure $ Left SIZE
          | chSize > 0 -> B.hPut h ch >> receive h (sz - chSize)
          | sz == 0 -> pure $ Right ()
          | otherwise -> pure $ Left SIZE
