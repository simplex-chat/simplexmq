{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.FileTransfer.Transport
  ( supportedFileServerVRange,
    XFTPRcvChunkSpec (..),
    ReceiveFileError (..),
    receiveFile,
    sendEncFile,
    receiveEncFile,
    receiveSbFile,
  )
where

import qualified Control.Exception as E
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class
import Data.Bifunctor (first)
import qualified Data.ByteArray as BA
import Data.ByteString.Builder (Builder, byteString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Word (Word32)
import Simplex.FileTransfer.Protocol (XFTPErrorType (..))
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Transport.HTTP2.File
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

sendEncFile :: Handle -> (Builder -> IO ()) -> LC.SbState -> Word32 -> IO ()
sendEncFile h send = go
  where
    go sbState 0 = do
      let authTag = BA.convert (LC.sbAuth sbState)
      send $ byteString authTag
    go sbState sz =
      getFileChunk h sz >>= \ch -> do
        let (encCh, sbState') = LC.sbEncryptChunk sbState ch
        send (byteString encCh) `E.catch` \(e :: E.SomeException) -> print e >> E.throwIO e
        go sbState' $ sz - fromIntegral (B.length ch)

receiveFile :: (Int -> IO ByteString) -> XFTPRcvChunkSpec -> ExceptT XFTPErrorType IO ()
receiveFile getBody = receiveFile_ receive
  where
    receive h sz = hReceiveFile getBody h sz >>= \sz' -> pure $ if sz' == 0 then Right () else Left SIZE

receiveEncFile :: (Int -> IO ByteString) -> LC.SbState -> XFTPRcvChunkSpec -> ExceptT XFTPErrorType IO ()
receiveEncFile getBody = receiveFile_ . receive
  where
    receive sbState h sz = first err <$> receiveSbFile getBody h sbState sz
    err RFESize = SIZE
    err RFECrypto = CRYPTO

data ReceiveFileError = RFESize | RFECrypto

receiveSbFile :: (Int -> IO ByteString) -> Handle -> LC.SbState -> Word32 -> IO (Either ReceiveFileError ())
receiveSbFile getBody h = receive
  where
    receive sbState sz = do
      ch <- getBody fileBlockSize
      let chSize = fromIntegral $ B.length ch
      if
        | chSize > sz + authSz -> pure $ Left RFESize
        | chSize > 0 -> do
            let (ch', rest) = B.splitAt (fromIntegral sz) ch
                (decCh, sbState') = LC.sbDecryptChunk sbState ch'
                sz' = sz - fromIntegral (B.length ch')
            B.hPut h decCh
            if sz' > 0
              then receive sbState' sz'
              else do
                let tag' = B.take C.authTagSize rest
                    tagSz = B.length tag'
                    tag = LC.sbAuth sbState'
                tag'' <- if tagSz == C.authTagSize then pure tag' else (tag' <>) <$> getBody (C.authTagSize - tagSz)
                pure $ if BA.constEq tag'' tag then Right () else Left RFECrypto
        | otherwise -> pure $ Left RFESize
    authSz = fromIntegral C.authTagSize

receiveFile_ :: (Handle -> Word32 -> IO (Either XFTPErrorType ())) -> XFTPRcvChunkSpec -> ExceptT XFTPErrorType IO ()
receiveFile_ receive XFTPRcvChunkSpec {filePath, chunkSize, chunkDigest} = do
  ExceptT $ withFile filePath WriteMode (`receive` chunkSize)
  digest' <- liftIO $ LC.sha256Hash <$> LB.readFile filePath
  when (digest' /= chunkDigest) $ throwError DIGEST
