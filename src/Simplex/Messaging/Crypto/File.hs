{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE BangPatterns #-}

module Simplex.Messaging.Crypto.File
  ( CryptoFile (..),
    CryptoFileArgs (..),
    CryptoFileHandle (..),
    FTCryptoError (..),
    Simplex.Messaging.Crypto.File.readFile,
    streamFromFile,
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
import Crypto.Random (ChaChaDRG)
import qualified Data.Aeson.TH as J
import qualified Data.ByteArray as BA
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB
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
import GHC.IO (unsafeInterleaveIO)
import Data.ByteString.Builder.Extra (defaultChunkSize)

-- Possibly encrypted local file
data CryptoFile = CryptoFile {filePath :: FilePath, cryptoArgs :: Maybe CryptoFileArgs}
  deriving (Eq, Show)

data CryptoFileArgs = CFArgs {fileKey :: C.SbKey, fileNonce :: C.CbNonce}
  deriving (Eq, Show)

data CryptoFileHandle = CFHandle Handle (Maybe (TVar LC.SbState))

readFile :: CryptoFile -> ExceptT FTCryptoError IO LazyByteString
readFile (CryptoFile path cfArgs) = do
  fileLen <- liftIO $ getFileSize path
  s <- liftIO $ LB.readFile path
  case cfArgs of
    Just (CFArgs key nonce) -> do
      let len = fromInteger fileLen - fromIntegral C.authTagSize
      when (len < 0) $ throwError FTCEInvalidFileSize
      let (s', tag') = LB.splitAt len s
      st0 <- liftEitherWith FTCECryptoError $ LC.sbInit key nonce
      tagVar <- IO.newEmptyMVar
      cs <- LC.secretBoxLazyM (\st -> pure . LC.sbDecryptChunk st) (IO.putMVar tagVar . LC.sbAuth) st0 s'
      tag <- IO.takeMVar tagVar
      unless (BA.constEq (LB.toStrict tag') tag) $ throwError FTCEInvalidAuthTag
      pure cs
    Nothing -> pure s

streamFromFile :: CryptoFile -> (LazyByteString -> IO ()) -> ExceptT FTCryptoError IO ()
streamFromFile (CryptoFile path cfArgs) stepF = do
  case cfArgs of
    Nothing -> liftIO (LB.readFile path) >>= liftIO . stepF
    Just (CFArgs key nonce) -> do
      fileLen <- liftIO $ getFileSize path
      let len = fileLen - fromIntegral C.authTagSize
      when (len < 0) $ throwError FTCEInvalidFileSize
      ---
      tag' <- liftIO . IO.withFile path IO.ReadMode $ \h -> do
        IO.hSeek h IO.AbsoluteSeek len
        B.hGet h $ fromIntegral C.authTagSize
      ---
      sv <- IO.newIORef =<< liftEitherWith FTCECryptoError (LC.sbInit key nonce)
      tag <- liftIO . IO.withFile path IO.ReadMode $ \h ->
        hGetN defaultChunkSize h (fromInteger len) (step' sv) (LC.sbAuth <$> IO.readIORef sv)
        -- unsafeInterleaveIO (LB.hGet h (fromInteger len)) >>= LB.foldrChunks (step sv) (LC.sbAuth <$> IO.readIORef sv)
      ---
      -- liftIO $ print (tag', BA.convert tag :: ByteString)
      unless (BA.constEq tag' tag) $ throwError FTCEInvalidAuthTag
  where
    step' :: IO.IORef LC.SbState -> ByteString -> IO ()
    step' sv chunk = do
      st <- IO.readIORef sv
      let (dc, !st') = LC.sbDecryptChunk st chunk
      IO.writeIORef sv st'
      stepF (LB.fromStrict dc)
    -- step :: IO.IORef LC.SbState -> ByteString -> IO a -> IO a
    -- step sv chunk next = do
    --   st <- IO.readIORef sv
    --   let (dc, st') = LC.sbDecryptChunk st chunk
    --   st' `seq` IO.writeIORef sv st'
    --   stepF (LB.fromStrict dc)
    --   next
    -- hGetN :: Int -> Handle -> Int -> IO ByteString
    hGetN k h n step done | n > 0 = foldChunks n
      where
        foldChunks !i = do
            c <- B.hGet h (min k i)
            case B.length c of
              0 -> done
              m -> step c >> foldChunks (i - m)
    hGetN _ _ 0 _ done = done
    hGetN _ _ _ _ _ = error "hGetN: illegal buffer size"

writeFile :: CryptoFile -> LazyByteString -> ExceptT FTCryptoError IO ()
writeFile (CryptoFile path cfArgs) s = do
  s' <- case cfArgs of
    Just (CFArgs (C.SbKey key) (C.CbNonce nonce)) ->
      liftEitherWith FTCECryptoError $ LC.secretBoxTailTag LC.sbEncryptChunk key nonce s
    Nothing -> pure s
  liftIO $ LB.writeFile path s'

withFile :: CryptoFile -> IOMode -> (CryptoFileHandle -> ExceptT FTCryptoError IO a) -> ExceptT FTCryptoError IO a
withFile (CryptoFile path cfArgs) mode action = do
  sb <- forM cfArgs $ \(CFArgs key nonce) ->
    liftEitherWith FTCECryptoError (LC.sbInit key nonce) >>= newTVarIO
  ExceptT . IO.withFile path mode $ \h -> runExceptT $ action $ CFHandle h sb

hPut :: CryptoFileHandle -> LazyByteString -> IO ()
hPut (CFHandle h sb_) s = maybe (LB.hPut h s) encrypt sb_ -- XXX: not thread-safe unless state is TMVar
  where
    encrypt :: TVar LC.SbState -> IO ()
    encrypt var = do
      st <- readTVarIO var
      void $ LC.secretBoxLazyM step (atomically . writeTVar var) st s
      where
        step st chunk = do
          let (chunk', st') = LC.sbEncryptChunk st chunk
          B.hPut h chunk'
          pure (chunk', st')

-- hPut :: CryptoFileHandle -> LazyByteString -> IO ()
-- hPut (CFHandle h sb_) s = LB.hPut h =<< maybe (pure s) encrypt sb_
--   where
--     encrypt :: TVar LC.SbState -> IO LazyByteString
--     encrypt sb = atomically $ stateTVar sb (`LC.sbEncryptChunkLazy` s)

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

randomArgs :: TVar ChaChaDRG -> STM CryptoFileArgs
randomArgs g = CFArgs <$> C.randomSbKey g <*> C.randomCbNonce g

getFileContentsSize :: CryptoFile -> IO Integer
getFileContentsSize (CryptoFile path cfArgs) = do
  size <- getFileSize path
  pure $ if isJust cfArgs then size - fromIntegral C.authTagSize else size

$(J.deriveJSON defaultJSON ''CryptoFileArgs)

$(J.deriveJSON defaultJSON ''CryptoFile)
