{-# LANGUAGE BangPatterns #-}

module Bench.Crypto.Lazy where

-- import qualified Simplex.Messaging.Crypto.Lazy as CL
import Test.Tasty.Bench

import Control.Concurrent.STM (atomically)
import Control.Monad.Except (runExceptT)
import qualified Data.ByteString.Lazy.Char8 as LB
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.File (CryptoFile (..))
import qualified Simplex.Messaging.Crypto.File as CF
import System.Directory (removeFile)
import Test.Tasty (TestTree, withResource)
import System.IO (IOMode(..))
import Control.Monad.IO.Class (liftIO)

benchCryptoLazy :: [Benchmark]
benchCryptoLazy =
  [ bgroup
      "File"
      [ withSomeFile $ bench "cf-readFile" . nfAppIO (>>= benchReadFile),
        withSomeFile $ bcompare "cf-readFile" . bench "cf-streamFromFile" . nfAppIO (>>= benchStreamFromFile),
        withSomeFile $ bcompare "cf-readFile" . bench "cf-passthrough" . nfAppIO (>>= benchPassthrough)
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
      Right () <- runExceptT $ CF.writeFile cfIn $ LB.replicate (256 * 1024 * 1024) '#'
      -- gen out args
      cfOut <- atomically $ CryptoFile "./some-file.out" . Just <$> CF.randomArgs g
      -- let cfOut  = CryptoFile "./some-file.out" Nothing
      pure (cfIn, cfOut)
    deleteCF (CryptoFile pathIn _, CryptoFile pathOut _) = do
      -- removeFile pathIn
      -- removeFile pathOut
      pure ()
