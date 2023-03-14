{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Crypto where

import Control.Monad.Except
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Int (Int64)
import Simplex.FileTransfer.Types (FileHeader (..), authTagSize)
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Encoding
import UnliftIO.Directory (removeFile)

decryptChunks :: Int64 -> [FilePath] -> C.SbKey -> C.CbNonce -> (String -> ExceptT String IO String) -> ExceptT FTCryptoError IO FilePath
decryptChunks encSize chunkPaths key nonce getFilePath = do
  (authOk, f) <- liftEither . first FTCEDecryptionError . LC.sbDecryptTailTag key nonce (encSize - authTagSize) =<< liftIO (readChunks chunkPaths)
  let (fileHdr, f') = LB.splitAt 1024 f
  -- withFile encPath ReadMode $ \r -> do
  --   fileHdr <- liftIO $ B.hGet r 1024
  case A.parse smpP $ LB.toStrict fileHdr of
    A.Fail _ _ e -> throwError $ FTCEInvalidHeader e
    A.Partial _ -> throwError $ FTCEInvalidHeader "incomplete"
    A.Done rest FileHeader {fileName} -> do
      path <- withExceptT FTCEFileIOError $ getFilePath fileName
      liftIO $ LB.writeFile path $ LB.fromStrict rest <> f'
      unless authOk $ do
        removeFile path
        throwError FTCEInvalidAuthTag
      pure path

readChunks :: [FilePath] -> IO LB.ByteString
readChunks = foldM (\s path -> (s <>) <$> LB.readFile path) ""

data FTCryptoError
  = FTCEDecryptionError C.CryptoError
  | FTCEInvalidHeader String
  | FTCEInvalidAuthTag
  | FTCEFileIOError String
  deriving (Show, Eq)
