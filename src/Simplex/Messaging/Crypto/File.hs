{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Crypto.File where

import Control.Exception
import Control.Monad.Except
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Aeson as J
import Data.Bifunctor (first)
import qualified Data.ByteArray as BA
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB
import Data.List.NonEmpty (NonEmpty (..))
import GHC.Generics (Generic)
import Simplex.Messaging.Client.Agent ()
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Lazy (LazyByteString)
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Util (liftEitherWith)
import UnliftIO (Handle, IOMode (..))
import qualified UnliftIO as IO
import UnliftIO.STM

data EncryptedFile = EncryptedFile {filePath :: FilePath, encFileArgs :: Maybe EncryptedFileArgs}
  deriving (Eq, Show, Generic, FromJSON)

instance ToJSON EncryptedFile where
  toEncoding = J.genericToEncoding J.defaultOptions {J.omitNothingFields = True}
  toJSON = J.genericToJSON J.defaultOptions {J.omitNothingFields = True}

data EncryptedFileArgs = EFArgs {fileSbKey :: C.SbKey, fileNonce :: C.CbNonce}
  deriving (Eq, Show, Generic, FromJSON)

instance ToJSON EncryptedFileArgs where toEncoding = J.genericToEncoding J.defaultOptions

data EncryptedFileHandle = EFHandle Handle (Maybe (TVar LC.SbState))

readFile :: EncryptedFile -> ExceptT FTCryptoError IO LazyByteString
readFile (EncryptedFile path fKey_) = do
  s <- liftIO $ LB.readFile path
  case fKey_ of
    Just (EFArgs (C.SbKey key) (C.CbNonce nonce)) -> do
      let len = LB.length s - fromIntegral C.authTagSize
      when (len < 0) $ throwError FTCEInvalidFileSize
      let (s', tag') = LB.splitAt len s
      (tag :| cs) <- liftEitherWith FTCECryptoError $ LC.secretBox LC.sbDecryptChunk key nonce s'
      unless (BA.constEq (LB.toStrict tag') tag) $ throwError FTCEInvalidAuthTag
      pure $ LB.fromChunks cs
    Nothing -> pure s

writeFile :: EncryptedFile -> LazyByteString -> ExceptT FTCryptoError IO ()
writeFile (EncryptedFile path fKey_) s = do
  s' <- case fKey_ of
    Just (EFArgs (C.SbKey key) (C.CbNonce nonce)) ->
      liftEitherWith FTCECryptoError $ LB.fromChunks <$> LC.secretBoxTailTag LC.sbEncryptChunk key nonce s
    Nothing -> pure s
  liftIO $ LB.writeFile path s'

withFile :: EncryptedFile -> IOMode -> (EncryptedFileHandle -> ExceptT FTCryptoError IO a) -> ExceptT FTCryptoError IO a
withFile (EncryptedFile path fKey_) mode action = do
  sb <- forM fKey_ $ \(EFArgs key nonce) ->
    liftEitherWith FTCECryptoError (LC.sbInit key nonce) >>= newTVarIO
  IO.withFile path mode $ \h -> action $ EFHandle h sb

hPut :: EncryptedFileHandle -> LazyByteString -> IO ()
hPut (EFHandle h sb_) s = LB.hPut h =<< maybe (pure s) encrypt sb_
  where
    encrypt sb = atomically $ stateTVar sb (`LC.sbEncryptChunkLazy` s)

hPutTag :: EncryptedFileHandle -> IO ()
hPutTag (EFHandle h sb_) = forM_ sb_ $ B.hPut h . BA.convert . LC.sbAuth <=< readTVarIO

hGet :: EncryptedFileHandle -> Int -> IO ByteString
hGet (EFHandle h sb_) n = B.hGet h n >>= maybe pure decrypt sb_
  where
    decrypt sb s = atomically $ stateTVar sb (`LC.sbDecryptChunk` s)

-- | Read and validate the auth tag.
-- This function should be called after reading the whole file, it assumes you know the file size and read only the needed bytes.
hGetTag :: EncryptedFileHandle -> ExceptT FTCryptoError IO ()
hGetTag (EFHandle h sb_) = forM_ sb_ $ \sb -> do
  tag <- liftIO $ B.hGet h C.authTagSize
  tag' <- LC.sbAuth <$> readTVarIO sb
  unless (BA.constEq tag tag') $ throwError FTCEInvalidAuthTag

fileIO :: IO a -> ExceptT FTCryptoError IO a
fileIO action = ExceptT $ first (\(e :: IOException) -> FTCEFileIOError $ show e) <$> try action

data FTCryptoError
  = FTCECryptoError C.CryptoError
  | FTCEInvalidHeader String
  | FTCEInvalidFileSize
  | FTCEInvalidAuthTag
  | FTCEFileIOError String
  deriving (Show, Eq, Exception)
