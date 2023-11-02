{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.FileTransfer.Crypto where

import Control.Monad
import Control.Monad.Except
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import qualified Data.ByteArray as BA
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Int (Int64)
import Simplex.FileTransfer.Types (FileHeader (..), authTagSize)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.File (CryptoFile (..), FTCryptoError (..))
import qualified Simplex.Messaging.Crypto.File as CF
import Simplex.Messaging.Crypto.Lazy (LazyByteString)
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Encoding
import Simplex.Messaging.Util (liftEitherWith)
import UnliftIO
import UnliftIO.Directory (removeFile)

encryptFile :: CryptoFile -> ByteString -> C.SbKey -> C.CbNonce -> Int64 -> Int64 -> FilePath -> ExceptT FTCryptoError IO ()
encryptFile srcFile fileHdr key nonce fileSize' encSize encFile = do
  sb <- liftEitherWith FTCECryptoError $ LC.sbInit key nonce
  CF.withFile srcFile ReadMode $ \r -> withFile encFile WriteMode $ \w -> do
    let lenStr = smpEncode fileSize'
        (hdr, !sb') = LC.sbEncryptChunk sb $ lenStr <> fileHdr
        padLen = encSize - authTagSize - fileSize' - 8
    liftIO $ B.hPut w hdr
    sb2 <- encryptChunks r w (sb', fileSize' - fromIntegral (B.length fileHdr))
    CF.hGetTag r
    sb3 <- encryptPad w (sb2, padLen)
    let tag = BA.convert $ LC.sbAuth sb3
    liftIO $ B.hPut w tag
  where
    encryptChunks r = encryptChunks_ $ liftIO . CF.hGet r . fromIntegral
    encryptPad = encryptChunks_ $ \sz -> pure $ B.replicate (fromIntegral sz) '#'
    encryptChunks_ :: (Int64 -> IO ByteString) -> Handle -> (LC.SbState, Int64) -> ExceptT FTCryptoError IO LC.SbState
    encryptChunks_ get w (!sb, !len)
      | len == 0 = pure sb
      | otherwise = do
          let chSize = min len 65536
          ch <- liftIO $ get chSize
          when (B.length ch /= fromIntegral chSize) $ throwError $ FTCEFileIOError "encrypting file: unexpected EOF"
          let (ch', sb') = LC.sbEncryptChunk sb ch
          liftIO $ B.hPut w ch'
          encryptChunks_ get w (sb', len - chSize)

decryptChunks :: Int64 -> [FilePath] -> C.SbKey -> C.CbNonce -> (String -> ExceptT String IO CryptoFile) -> ExceptT FTCryptoError IO CryptoFile
decryptChunks _ [] _ _ _ = throwError $ FTCEInvalidHeader "empty"
decryptChunks encSize (chPath : chPaths) key nonce getDestFile = case reverse chPaths of
  [] -> do
    (!authOk, !f) <- liftEither . first FTCECryptoError . LC.sbDecryptTailTag key nonce (encSize - authTagSize) =<< liftIO (LB.readFile chPath)
    unless authOk $ throwError FTCEInvalidAuthTag
    (FileHeader {fileName}, !f') <- parseFileHeader f
    destFile <- withExceptT FTCEFileIOError $ getDestFile fileName
    CF.writeFile destFile f'
    pure destFile
  lastPath : chPaths' -> do
    (state, expectedLen, ch) <- decryptFirstChunk
    (FileHeader {fileName}, ch') <- parseFileHeader ch
    destFile@(CryptoFile path _) <- withExceptT FTCEFileIOError $ getDestFile fileName
    authOk <- CF.withFile destFile WriteMode $ \h -> liftIO $ do
      CF.hPut h ch'
      state' <- foldM (decryptChunk h) state $ reverse chPaths'
      decryptLastChunk h state' expectedLen
    unless authOk $ do
      removeFile path
      throwError FTCEInvalidAuthTag
    pure destFile
    where
      decryptFirstChunk = do
        sb <- liftEitherWith FTCECryptoError $ LC.sbInit key nonce
        ch <- liftIO $ LB.readFile chPath
        let (ch1, !sb') = LC.sbDecryptChunkLazy sb ch
        (!expectedLen, ch2) <- liftEitherWith FTCECryptoError $ LC.splitLen ch1
        let len1 = LB.length ch2
        pure ((sb', len1), expectedLen, ch2)
      decryptChunk h (!sb, !len) chPth = do
        ch <- LB.readFile chPth
        let len' = len + LB.length ch
            (ch', sb') = LC.sbDecryptChunkLazy sb ch
        CF.hPut h ch'
        pure (sb', len')
      decryptLastChunk h (!sb, !len) expectedLen = do
        ch <- LB.readFile lastPath
        let (ch1, tag') = LB.splitAt (LB.length ch - authTagSize) ch
            tag'' = LB.toStrict tag'
            (ch2, sb') = LC.sbDecryptChunkLazy sb ch1
            len' = len + LB.length ch2
            ch3 = LB.take (LB.length ch2 - len' + expectedLen) ch2
            tag :: ByteString = BA.convert (LC.sbAuth sb')
        CF.hPut h ch3
        CF.hPutTag h
        pure $ B.length tag'' == 16 && BA.constEq tag'' tag
  where
    parseFileHeader :: LazyByteString -> ExceptT FTCryptoError IO (FileHeader, LazyByteString)
    parseFileHeader s = do
      let (hdrStr, s') = LB.splitAt 1024 s
      case A.parse smpP $ LB.toStrict hdrStr of
        A.Fail _ _ e -> throwError $ FTCEInvalidHeader e
        A.Partial _ -> throwError $ FTCEInvalidHeader "incomplete"
        A.Done rest hdr -> pure (hdr, LB.fromStrict rest <> s')

readChunks :: [FilePath] -> IO LB.ByteString
readChunks = foldM (\s path -> (s <>) <$> LB.readFile path) ""
