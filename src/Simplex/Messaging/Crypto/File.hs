{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.Crypto.File
  ( CryptoFile (..),
    CryptoFileArgs (..),
    CryptoFileHandle (..),
    FTCryptoError (..),
    Simplex.Messaging.Crypto.File.readFile,
    Simplex.Messaging.Crypto.File.writeFile,
    withFile,
    hPut,
    hPutTag,
    hGet,
    hGetTag,
    plain,
    randomArgs,
    getFileContentsSize,
  )
where

import Control.Exception
import Control.Monad
import Control.Monad.Except
import qualified Data.Aeson.TH as J
import qualified Data.ByteArray as BA
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isJust)
import Simplex.Messaging.Client.Agent ()
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Lazy (LazyByteString)
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Parsers (defaultJSON)
import Simplex.Messaging.Util (liftEitherWith)
import System.Directory (getFileSize)
import UnliftIO (Handle, IOMode (..), liftIO)
import qualified UnliftIO as IO
import UnliftIO.STM

-- Possibly encrypted local file
data CryptoFile = CryptoFile {filePath :: FilePath, cryptoArgs :: Maybe CryptoFileArgs}
  deriving (Eq, Show)

data CryptoFileArgs = CFArgs {fileKey :: C.SbKey, fileNonce :: C.CbNonce}
  deriving (Eq, Show)

data CryptoFileHandle = CFHandle Handle (Maybe (TVar LC.SbState))

readFile :: CryptoFile -> ExceptT FTCryptoError IO LazyByteString
readFile (CryptoFile path cfArgs) = do
  s <- liftIO $ LB.readFile path
  case cfArgs of
    Just (CFArgs (C.SbKey key) (C.CbNonce nonce)) -> do
      let len = LB.length s - fromIntegral C.authTagSize
      when (len < 0) $ throwError FTCEInvalidFileSize
      let (s', tag') = LB.splitAt len s
      (tag :| cs) <- liftEitherWith FTCECryptoError $ LC.secretBox LC.sbDecryptChunk key nonce s'
      unless (BA.constEq (LB.toStrict tag') tag) $ throwError FTCEInvalidAuthTag
      pure $ LB.fromChunks cs
    Nothing -> pure s

writeFile :: CryptoFile -> LazyByteString -> ExceptT FTCryptoError IO ()
writeFile (CryptoFile path cfArgs) s = do
  s' <- case cfArgs of
    Just (CFArgs (C.SbKey key) (C.CbNonce nonce)) ->
      liftEitherWith FTCECryptoError $ LB.fromChunks <$> LC.secretBoxTailTag LC.sbEncryptChunk key nonce s
    Nothing -> pure s
  liftIO $ LB.writeFile path s'

withFile :: CryptoFile -> IOMode -> (CryptoFileHandle -> ExceptT FTCryptoError IO a) -> ExceptT FTCryptoError IO a
withFile (CryptoFile path cfArgs) mode action = do
  sb <- forM cfArgs $ \(CFArgs key nonce) ->
    liftEitherWith FTCECryptoError (LC.sbInit key nonce) >>= newTVarIO
  IO.withFile path mode $ \h -> action $ CFHandle h sb

hPut :: CryptoFileHandle -> LazyByteString -> IO ()
hPut (CFHandle h sb_) s = LB.hPut h =<< maybe (pure s) encrypt sb_
  where
    encrypt sb = atomically $ stateTVar sb (`LC.sbEncryptChunkLazy` s)

hPutTag :: CryptoFileHandle -> IO ()
hPutTag (CFHandle h sb_) = forM_ sb_ $ B.hPut h . BA.convert . LC.sbAuth <=< readTVarIO

hGet :: CryptoFileHandle -> Int -> IO ByteString
hGet (CFHandle h sb_) n = B.hGet h n >>= maybe pure decrypt sb_
  where
    decrypt sb s = atomically $ stateTVar sb (`LC.sbDecryptChunk` s)

-- | Read and validate the auth tag.
-- This function should be called after reading the whole file, it assumes you know the file size and read only the needed bytes.
hGetTag :: CryptoFileHandle -> ExceptT FTCryptoError IO ()
hGetTag (CFHandle h sb_) = forM_ sb_ $ \sb -> do
  tag <- liftIO $ B.hGet h C.authTagSize
  tag' <- LC.sbAuth <$> readTVarIO sb
  unless (BA.constEq tag tag') $ throwError FTCEInvalidAuthTag

data FTCryptoError
  = FTCECryptoError C.CryptoError
  | FTCEInvalidHeader String
  | FTCEInvalidFileSize
  | FTCEInvalidAuthTag
  | FTCEFileIOError String
  deriving (Show, Eq, Exception)

plain :: FilePath -> CryptoFile
plain = (`CryptoFile` Nothing)

randomArgs :: IO CryptoFileArgs
randomArgs = CFArgs <$> C.randomSbKey <*> C.randomCbNonce

getFileContentsSize :: CryptoFile -> IO Integer
getFileContentsSize (CryptoFile path cfArgs) = do
  size <- getFileSize path
  pure $ if isJust cfArgs then size - fromIntegral C.authTagSize else size

$(J.deriveJSON defaultJSON ''CryptoFileArgs)

$(J.deriveJSON defaultJSON ''CryptoFile)
