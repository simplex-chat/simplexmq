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
    sendEncFile,
    receiveEncFile,
  )
where

import Control.Concurrent (threadDelay)
import qualified Control.Exception as E
import Control.Monad.Except
import qualified Data.ByteArray as BA
import Data.ByteString.Builder (Builder, byteString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Word (Word32)
import GHC.IO.Handle.Internals (ioe_EOF)
import Simplex.FileTransfer.Protocol (XFTPErrorType (..))
import qualified Simplex.Messaging.Crypto as C
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

fileBlockSize :: Int
fileBlockSize = 16 * 1024

sendFile :: Handle -> (Builder -> IO ()) -> Word32 -> IO ()
sendFile h send = go
  where
    go 0 = pure ()
    go sz =
      getFileChunk h sz >>= \ch -> do
        send $ byteString ch
        go $ sz - fromIntegral (B.length ch)

sendEncFile :: Handle -> (Builder -> IO ()) -> LC.SbState -> Word32 -> IO ()
sendEncFile h send = go
  where
    go sbState 0 = do
      -- TODO padding somehow also solves timing issue in HTTP2 (?)
      let authTag = BA.convert (LC.sbAuth sbState) <> B.replicate (fileBlockSize - C.authTagSize) '#'
      send $ byteString authTag
    go sbState sz =
      getFileChunk h sz >>= \ch -> do
        let (encCh, sbState') = LC.sbEncryptChunk sbState ch
        send (byteString encCh) `E.catch` \(e :: E.SomeException) -> print e >> E.throwIO e
        -- TODO remove delay when HTTP2 issue is fixed
        threadDelay 500
        go sbState' $ sz - fromIntegral (B.length ch)

getFileChunk :: Handle -> Word32 -> IO ByteString
getFileChunk h sz =
  B.hGet h fileBlockSize >>= \case
    "" -> ioe_EOF
    ch -> pure $ B.take (fromIntegral sz) ch -- sz >= xftpBlockSize

receiveFile :: (Int -> IO ByteString) -> XFTPRcvChunkSpec -> ExceptT XFTPErrorType IO ()
receiveFile getBody = receiveFile_ receive
  where
    receive h sz = do
      ch <- getBody fileBlockSize
      let chSize = fromIntegral $ B.length ch
      if
          | chSize > sz -> pure $ Left SIZE
          | chSize > 0 -> B.hPut h ch >> receive h (sz - chSize)
          | sz == 0 -> pure $ Right ()
          | otherwise -> pure $ Left SIZE

receiveEncFile :: (Int -> IO ByteString) -> LC.SbState -> XFTPRcvChunkSpec -> ExceptT XFTPErrorType IO ()
receiveEncFile getBody = receiveFile_ . receive
  where
    receive sbState h sz = do
      ch <- getBody fileBlockSize
      let chSize = fromIntegral $ B.length ch
      if
          | chSize > sz + authSz -> pure $ Left SIZE
          | chSize > 0 -> do
            let (ch', rest) = B.splitAt (fromIntegral sz) ch
                (decCh, sbState') = LC.sbDecryptChunk sbState ch'
                sz' = sz - fromIntegral (B.length ch')
            B.hPut h decCh
            if sz' > 0
              then receive sbState' h sz'
              else do
                let tag' = B.take C.authTagSize rest
                    tagSz = B.length tag'
                    tag = LC.sbAuth sbState'
                tag'' <- if tagSz == C.authTagSize then pure tag' else (tag' <>) <$> getBody (C.authTagSize - tagSz)
                pure $ if BA.constEq tag'' tag then Right () else Left CRYPTO
          | otherwise -> pure $ Left SIZE
    authSz = fromIntegral C.authTagSize

receiveFile_ :: (Handle -> Word32 -> IO (Either XFTPErrorType ())) -> XFTPRcvChunkSpec -> ExceptT XFTPErrorType IO ()
receiveFile_ receive XFTPRcvChunkSpec {filePath, chunkSize, chunkDigest} = do
  ExceptT $ withFile filePath WriteMode (`receive` chunkSize)
  digest' <- liftIO $ LC.sha256Hash <$> LB.readFile filePath
  when (digest' /= chunkDigest) $ throwError DIGEST
