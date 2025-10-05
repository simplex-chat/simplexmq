{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module Util where

import Control.Concurrent.Async
import Control.Exception as E
import Control.Logger.Simple
import Control.Monad (replicateM, when)
import Data.Either (partitionEithers)
import Data.List (tails)
import GHC.Conc (getNumCapabilities, getNumProcessors, setNumCapabilities)
import System.Directory (doesFileExist, removeFile)
import System.Environment (lookupEnv)
import System.Process (callCommand)
import System.Timeout (timeout)
import Test.Hspec hiding (fit, it)
import qualified Test.Hspec as Hspec
import Test.Hspec.Core.Spec (Example (..), Result (..), ResultStatus (..))

skip :: String -> SpecWith a -> SpecWith a
skip = before_ . pendingWith

withNumCapabilities :: Int -> IO a -> IO a
withNumCapabilities new a = getNumCapabilities >>= \old -> bracket_ (setNumCapabilities new) (setNumCapabilities old) a

withNCPUCapabilities :: IO a -> IO a
withNCPUCapabilities a = getNumProcessors >>= \p -> withNumCapabilities p a

inParrallel :: Int -> IO () -> IO ()
inParrallel n action = do
  streams <- replicateM n $ async action
  (es, rs) <- partitionEithers <$> mapM waitCatch streams
  map show es `shouldBe` []
  length rs `shouldBe` n

combinations :: Int -> [a] -> [[a]]
combinations 0 _ = [[]]
combinations k xs = [y : ys | y : xs' <- tails xs, ys <- combinations (k - 1) xs']

removeFileIfExists :: FilePath -> IO ()
removeFileIfExists filePath = do
  fileExists <- doesFileExist filePath
  when fileExists $ removeFile filePath

newtype TestWrapper a = TestWrapper a

-- TODO [ntfdb] running wiht LogWarn level shows potential issue "Queue count differs"
testLogLevel :: LogLevel
testLogLevel = LogWarn

instance Example a => Example (TestWrapper a) where
  type Arg (TestWrapper a) = Arg a
  evaluateExample (TestWrapper action) params hooks state = do
    ci <- envCI
    runTest `E.catches` [E.Handler (onTestFailure ci), E.Handler (onTestException ci)]
    where
      tt = 30
      runTest =
        timeout (tt * 1000000) (evaluateExample action params hooks state) `finally` callCommand "sync" >>= \case
          Just r -> pure r
          Nothing -> throwIO $ userError $ "test timed out after " <> show tt <> " seconds"
      onTestFailure :: Bool -> ResultStatus -> IO Result
      onTestFailure ci = \case
        Failure loc_ reason | ci -> do
          putStrLn $ "Test failed: location " ++ show loc_ ++ ", reason: " ++ show reason
          retryTest
        r -> E.throwIO r
      onTestException :: Bool -> SomeException -> IO Result
      onTestException False e = E.throwIO e
      onTestException True e = do
        putStrLn $ "Test exception: " ++ show e
        retryTest
      retryTest = do
        putStrLn "Retrying with more logs..."
        setLogLevel LogDebug
        runTest `finally` setLogLevel testLogLevel -- change this to match log level in Test.hs

envCI :: IO Bool
envCI = (Just "true" ==) <$> lookupEnv "CI"

it :: (HasCallStack, Example a) => String -> a -> SpecWith (Arg a)
it label action = Hspec.it label (TestWrapper action)

fit :: (HasCallStack, Example a) => String -> a -> SpecWith (Arg a)
fit = fmap focus . it
