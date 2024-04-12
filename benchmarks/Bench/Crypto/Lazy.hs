{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE NamedFieldPuns #-}

module Bench.Crypto.Lazy where

-- import qualified Simplex.Messaging.Crypto.Lazy as CL
import Test.Tasty.Bench

import Control.Concurrent.STM (atomically)
import Control.Monad.Except (runExceptT, throwError)
import qualified Data.ByteString.Lazy.Char8 as LB
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.File (CryptoFile (..))
import qualified Simplex.Messaging.Crypto.File as CF
import System.Directory (removeFile)
import Test.Tasty (TestTree, withResource)
import System.IO (IOMode(..))
import Control.Monad.IO.Class (liftIO)
import Control.Monad
import UnliftIO.Directory (getFileSize)
import qualified Data.ByteString as B
import Control.Monad.Trans.Except (ExceptT)

benchCryptoLazy :: [Benchmark]
benchCryptoLazy =
  [ bgroup
      "File"
      [ withSomeFile $ bench "cf-passthrough" . nfAppIO (>>= benchPassthrough),
        withSomeFile $ bench "cf-double-streaming" . nfAppIO (>>= benchDoubleStreaming),
        withSomeFile $ bench "cf-streamFromFile" . nfAppIO (>>= benchStreamFromFile),
        withSomeFile $ bench "cf-readFile" . nfAppIO (>>= benchReadFile)
      ]
  ]

benchReadFile :: (CryptoFile, CryptoFile) -> IO ()
benchReadFile (cfIn, cfOut) = fmap (either (error . show) id) . runExceptT $ CF.readFile cfIn >>= CF.writeFile cfOut

benchStreamFromFile :: (CryptoFile, CryptoFile) -> IO ()
benchStreamFromFile (cfIn, cfOut) = fmap (either (error . show) id) . runExceptT $
  -- CF.streamFromFile cfIn $ \_ -> pure ()
  CF.withFile cfOut WriteMode $ \cbh -> do
    CF.streamFromFile cfIn $ liftIO . CF.hPut cbh
    liftIO $ CF.hPutTag cbh

benchPassthrough :: (CryptoFile, CryptoFile) -> IO ()
benchPassthrough (CryptoFile pathIn _, CryptoFile pathOut _) = LB.readFile pathIn >>= LB.writeFile pathOut

benchDoubleStreaming :: (CryptoFile, CryptoFile) -> IO ()
benchDoubleStreaming (src, dst) = fmap (either (error . show) id) . runExceptT $ copyCryptoFile src dst
  where
    copyCryptoFile :: CryptoFile -> CryptoFile -> ExceptT CF.FTCryptoError IO ()
    copyCryptoFile fromCF@CryptoFile {filePath = fsFromPath, cryptoArgs = fromArgs} toCF@CryptoFile {cryptoArgs = toArgs} = do
      fromSizeFull <- getFileSize fsFromPath
      let fromSize = fromSizeFull - maybe 0 (const $ toInteger C.authTagSize) fromArgs
      CF.withFile fromCF ReadMode $ \fromH ->
        CF.withFile toCF WriteMode $ \toH -> do
          copyChunks fromH toH fromSize
          forM_ fromArgs $ \_ -> CF.hGetTag fromH
          forM_ toArgs $ \_ -> liftIO $ CF.hPutTag toH
      where
        copyChunks :: CF.CryptoFileHandle -> CF.CryptoFileHandle -> Integer -> ExceptT CF.FTCryptoError IO ()
        copyChunks r w size = do
          let chSize = min size 0xFFFF
              chSize' = fromIntegral chSize
              size' = size - chSize
          ch <- liftIO $ CF.hGet r chSize'
          when (B.length ch /= chSize') $ throwError $ CF.FTCEFileIOError "encrypting file: unexpected EOF"
          liftIO . CF.hPut w $ LB.fromStrict ch
          when (size' > 0) $ copyChunks r w size'

withSomeFile :: (IO (CryptoFile, CryptoFile) -> TestTree) -> TestTree
withSomeFile = withResource createCF deleteCF
  where
    createCF = do
      g <- C.newRandom
      -- encrypt input file
      let pathIn = "./some-file.in"
      -- let cfIn  = CryptoFile pathIn Nothing
      -- LB.writeFile pathIn $ LB.replicate (256 * 1024 * 1024) '#'
      cfIn <- atomically $ CryptoFile pathIn . Just <$> CF.randomArgs g
      -- Right () <- runExceptT $ CF.withFile cfIn WriteMode $ \cbh -> liftIO $ do
      --   replicateM_ 256 $ CF.hPut cbh dummyChunk
      --   CF.hPutTag cbh
      Right () <- runExceptT $ CF.writeFile cfIn $ LB.replicate (256 * 1024 * 1024) '#'
      -- gen out args
      cfOut <- atomically $ CryptoFile "./some-file.out" . Just <$> CF.randomArgs g
      -- let cfOut  = CryptoFile "./some-file.out" Nothing
      pure (cfIn, cfOut)
    deleteCF (CryptoFile pathIn _, CryptoFile pathOut _) = do
      removeFile pathIn
      removeFile pathOut

dummyChunk :: LB.ByteString
dummyChunk = LB.replicate (1024 * 1024) '#'
