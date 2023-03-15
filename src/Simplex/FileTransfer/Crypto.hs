{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.FileTransfer.Crypto where

import Control.Monad.Except
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import qualified Data.ByteArray as BA
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Int (Int64)
import Simplex.FileTransfer.Types (FileHeader (..), authTagSize)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Lazy (LazyByteString)
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Encoding
import Simplex.Messaging.Util (liftEitherWith)
import UnliftIO
import UnliftIO.Directory (removeFile)

decryptChunks' :: Int64 -> [FilePath] -> C.SbKey -> C.CbNonce -> (String -> ExceptT String IO String) -> ExceptT FTCryptoError IO FilePath
decryptChunks' encSize chunkPaths key nonce getFilePath = do
  (authOk, f) <- liftEither . first FTCECryptoError . LC.sbDecryptTailTag key nonce (encSize - authTagSize) =<< liftIO (readChunks chunkPaths)
  (FileHeader {fileName}, f') <- parseFileHeader f
  path <- withExceptT FTCEFileIOError $ getFilePath fileName
  liftIO $ LB.writeFile path f'
  unless authOk $ do
    removeFile path
    throwError FTCEInvalidAuthTag
  pure path

decryptChunks :: Int64 -> [FilePath] -> C.SbKey -> C.CbNonce -> (String -> ExceptT String IO String) -> ExceptT FTCryptoError IO FilePath
decryptChunks _ [] _ _ _ = throwError $ FTCEInvalidHeader "empty"
decryptChunks encSize (chPath : chPaths) key nonce getFilePath = case reverse chPaths of
  [] -> do
    (!authOk, !f) <- liftEither . first FTCECryptoError . LC.sbDecryptTailTag key nonce (encSize - authTagSize) =<< liftIO (LB.readFile chPath)
    unless authOk $ throwError FTCEInvalidAuthTag
    (FileHeader {fileName}, !f') <- parseFileHeader f
    path <- withExceptT FTCEFileIOError $ getFilePath fileName
    liftIO $ LB.writeFile path f'
    pure path
  lastPath : chPaths' -> do
    sb <- liftEitherWith FTCECryptoError $ LC.sbInit key nonce
    ch <- liftIO $ LB.readFile chPath
    let (ch1, sb1) = LC.sbDecryptChunkLazy sb ch
    (!expectedLen, ch2) <- liftEitherWith FTCECryptoError $ LC.splitLen ch1
    let len1 = LB.length ch2
    -- (authOk, f) <- liftEither . first FTCECryptoError . LC.sbDecryptTailTag key nonce (encSize - authTagSize) =<< liftIO (readChunks chunkPaths)
    (FileHeader {fileName}, ch3) <- parseFileHeader ch2
    path <- withExceptT FTCEFileIOError $ getFilePath fileName
    authOk <- liftIO . withFile path WriteMode $ \w -> do
      liftIO $ LB.hPut w ch3
      (sb2, len2) <- foldM (decryptChunk w) (sb1, len1) $ reverse chPaths'
      lastCh <- LB.readFile lastPath
      let (lastCh1, tag') = LB.splitAt (LB.length lastCh - authTagSize) lastCh
          (lastCh2, sb3) = LC.sbDecryptChunkLazy sb2 lastCh1
          len3 = len2 + LB.length lastCh2
          lastCh3 = LB.take (LB.length lastCh2 - len3 + expectedLen) lastCh2
          tag :: ByteString = BA.convert (LC.sbAuth sb3)
      LB.hPut w lastCh3
      pure $ LB.length tag' == 16 && BA.constEq (LB.toStrict tag') tag
    unless authOk $ do
      removeFile path
      throwError FTCEInvalidAuthTag
    pure path

parseFileHeader :: LazyByteString -> ExceptT FTCryptoError IO (FileHeader, LazyByteString)
parseFileHeader s = do
  let (hdrStr, s') = LB.splitAt 1024 s
  case A.parse smpP $ LB.toStrict hdrStr of
    A.Fail _ _ e -> throwError $ FTCEInvalidHeader e
    A.Partial _ -> throwError $ FTCEInvalidHeader "incomplete"
    A.Done rest hdr -> pure (hdr, LB.fromStrict rest <> s')

decryptChunk :: Handle -> (LC.SbState, Int64) -> FilePath -> IO (LC.SbState, Int64)
decryptChunk w (sb, len) chPath = do
  ch <- LB.readFile chPath
  let !len' = len + LB.length ch
      (!ch', !sb') = LC.sbDecryptChunkLazy sb ch
  LB.hPut w ch'
  pure (sb', len')

readChunks :: [FilePath] -> IO LB.ByteString
readChunks = foldM (\s path -> (s <>) <$> LB.readFile path) ""

data FTCryptoError
  = FTCECryptoError C.CryptoError
  | FTCEInvalidHeader String
  | FTCEInvalidAuthTag
  | FTCEFileIOError String
  deriving (Show, Eq)
