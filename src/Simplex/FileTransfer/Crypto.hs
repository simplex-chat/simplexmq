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
import qualified Data.ByteString.Char8 as B
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
    (state, expectedLen, ch) <- decryptFirstChunk
    (FileHeader {fileName}, ch') <- parseFileHeader ch
    path <- withExceptT FTCEFileIOError $ getFilePath fileName
    authOk <- liftIO . withFile path WriteMode $ \w -> do
      liftIO $ LB.hPut w ch'
      state' <- foldM (decryptChunk w) state $ reverse chPaths'
      decryptLastChunk w state' expectedLen
    unless authOk $ do
      removeFile path
      throwError FTCEInvalidAuthTag
    pure path
    where
      decryptFirstChunk = do
        sb <- liftEitherWith FTCECryptoError $ LC.sbInit key nonce
        ch <- liftIO $ LB.readFile chPath
        let (ch1, !sb') = LC.sbDecryptChunkLazy sb ch
        (!expectedLen, ch2) <- liftEitherWith FTCECryptoError $ LC.splitLen ch1
        let len1 = LB.length ch2
        pure ((sb', len1), expectedLen, ch2)
      decryptChunk w (sb, len) chPth = do
        ch <- LB.readFile chPth
        let !len' = len + LB.length ch
            (ch', !sb') = LC.sbDecryptChunkLazy sb ch
        LB.hPut w ch'
        pure (sb', len')
      decryptLastChunk w (sb, len) expectedLen = do
        ch <- LB.readFile lastPath
        let (ch1, tag') = LB.splitAt (LB.length ch - authTagSize) ch
            tag'' = LB.toStrict tag'
            (ch2, !sb') = LC.sbDecryptChunkLazy sb ch1
            len' = len + LB.length ch2
            ch3 = LB.take (LB.length ch2 - len' + expectedLen) ch2
            tag :: ByteString = BA.convert (LC.sbAuth sb')
        LB.hPut w ch3
        pure $ B.length tag'' == 16 && BA.constEq tag'' tag

parseFileHeader :: LazyByteString -> ExceptT FTCryptoError IO (FileHeader, LazyByteString)
parseFileHeader s = do
  let (hdrStr, s') = LB.splitAt 1024 s
  case A.parse smpP $ LB.toStrict hdrStr of
    A.Fail _ _ e -> throwError $ FTCEInvalidHeader e
    A.Partial _ -> throwError $ FTCEInvalidHeader "incomplete"
    A.Done rest hdr -> pure (hdr, LB.fromStrict rest <> s')

readChunks :: [FilePath] -> IO LB.ByteString
readChunks = foldM (\s path -> (s <>) <$> LB.readFile path) ""

data FTCryptoError
  = FTCECryptoError C.CryptoError
  | FTCEInvalidHeader String
  | FTCEInvalidAuthTag
  | FTCEFileIOError String
  deriving (Show, Eq)
