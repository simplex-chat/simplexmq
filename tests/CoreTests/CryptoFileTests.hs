{-# LANGUAGE OverloadedStrings #-}

module CoreTests.CryptoFileTests (cryptoFileTests) where

import AgentTests.FunctionalAPITests (runRight_)
import Control.Concurrent.STM
import Control.Monad.Except
import Control.Monad.IO.Class
import Crypto.Random (ChaChaDRG)
import qualified Data.ByteString.Lazy as LB
import GHC.IO.IOMode (IOMode (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.File (CryptoFile (..), FTCryptoError (..))
import qualified Simplex.Messaging.Crypto.File as CF
import System.Directory (getFileSize)
import Test.Hspec

cryptoFileTests :: Spec
cryptoFileTests = focus $ do
  it "should write/read file" testWriteReadFile
  it "should put/get file" testPutGetFile
  it "should write/get file" testWriteGetFile
  it "should put/read file" testPutReadFile
  it "should fail reading empty or small file" testSmallFile

testFilePath :: FilePath
testFilePath = "tests/tmp/testcryptofile"

testWriteReadFile :: IO ()
testWriteReadFile = do
  g <- C.newRandom
  s <- atomically $ LB.fromStrict <$> C.randomBytes 100000 g
  file <- atomically $ mkCryptoFile g
  runRight_ $ do
    CF.writeFile file s
    liftIO $ CF.getFileContentsSize file `shouldReturn` 100000
    liftIO $ getFileSize testFilePath `shouldReturn` 100000 + fromIntegral C.authTagSize
    s' <- CF.readFile file
    liftIO $ s `shouldBe` s'

testPutGetFile :: IO ()
testPutGetFile = do
  g <- C.newRandom
  s <- atomically $ LB.fromStrict <$> C.randomBytes 50000 g
  s' <- atomically $ LB.fromStrict <$> C.randomBytes 50000 g
  file <- atomically $ mkCryptoFile g
  runRight_ $ do
    CF.withFile file WriteMode $ \h -> liftIO $ do
      CF.hPut h s
      CF.hPut h s'
      CF.hPutTag h
    liftIO $ CF.getFileContentsSize file `shouldReturn` 100000
    liftIO $ getFileSize testFilePath `shouldReturn` 100000 + fromIntegral C.authTagSize
    CF.withFile file ReadMode $ \h -> do
      s1 <- liftIO $ CF.hGet h 30000
      s2 <- liftIO $ CF.hGet h 40000
      s3 <- liftIO $ CF.hGet h 30000
      CF.hGetTag h
      liftIO $ (s <> s') `shouldBe` LB.fromStrict (s1 <> s2 <> s3)

testWriteGetFile :: IO ()
testWriteGetFile = do
  g <- C.newRandom
  s <- atomically $ LB.fromStrict <$> C.randomBytes 100000 g
  file <- atomically $ mkCryptoFile g
  runRight_ $ do
    CF.writeFile file s
    CF.withFile file ReadMode $ \h -> do
      s' <- liftIO $ CF.hGet h 50000
      s'' <- liftIO $ CF.hGet h 50000
      CF.hGetTag h
      liftIO $ runExceptT (CF.hGetTag h) `shouldReturn` Left FTCEInvalidAuthTag
      liftIO $ s `shouldBe` LB.fromStrict (s' <> s'')

testPutReadFile :: IO ()
testPutReadFile = do
  g <- C.newRandom
  s <- atomically $ LB.fromStrict <$> C.randomBytes 50000 g
  s' <- atomically $ LB.fromStrict <$> C.randomBytes 50000 g
  file <- atomically $ mkCryptoFile g
  runRight_ $ do
    CF.withFile file WriteMode $ \h -> liftIO $ do
      CF.hPut h s
      CF.hPut h s'
  runExceptT (CF.readFile file) `shouldReturn` Left FTCEInvalidAuthTag
  runRight_ $ do
    CF.withFile file WriteMode $ \h -> liftIO $ do
      CF.hPut h s
      CF.hPut h s'
      CF.hPutTag h
    s'' <- CF.readFile file
    liftIO $ (s <> s') `shouldBe` s''

testSmallFile :: IO ()
testSmallFile = do
  g <- C.newRandom
  file <- atomically $ mkCryptoFile g
  LB.writeFile testFilePath ""
  runExceptT (CF.readFile file) `shouldReturn` Left FTCEInvalidFileSize
  LB.writeFile testFilePath "123"
  runExceptT (CF.readFile file) `shouldReturn` Left FTCEInvalidFileSize

mkCryptoFile :: TVar ChaChaDRG -> STM CryptoFile
mkCryptoFile g = CryptoFile testFilePath . Just <$> CF.randomArgs g
