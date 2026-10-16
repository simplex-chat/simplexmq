{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module Util where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception as E
import Control.Logger.Simple
import Control.Monad (replicateM, when)
import Data.Either (partitionEithers)
import Data.List (tails)
import Data.String (IsString (..))
import GHC.Conc (getNumCapabilities, getNumProcessors, setNumCapabilities)
import GHC.IO.Exception (IOException (..))
import qualified GHC.IO.Exception as IOException
import Network.Socket (ServiceName)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeDirectoryRecursive, removeFile)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import System.Process (callCommand)
import System.Timeout (timeout)
import Test.Hspec hiding (fit, it, xit)
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

data TestEnv = TestEnv
  { testNo :: Int,
    portBase :: Int
  }

type HasTestEnv = (?testEnv :: TestEnv)

tmpDir :: FilePath
tmpDir = "tests/tmp"

testDir :: HasTestEnv => FilePath
testDir = tmpDir </> show (testNo ?testEnv)

testPath :: HasTestEnv => FilePath -> FilePath
testPath = (testDir </>)

testServerPort :: HasTestEnv => Int -> ServiceName
testServerPort offset = show (portBase ?testEnv + offset)

testSchemaName :: (HasTestEnv, IsString s) => String -> s
testSchemaName name = fromString $ "test" <> show (testNo ?testEnv) <> "_" <> name

senderFiles :: HasTestEnv => FilePath
senderFiles = testPath "xftp-sender-files"

recipientFiles :: HasTestEnv => FilePath
recipientFiles = testPath "xftp-recipient-files"

testCounter :: TVar Int
testCounter = unsafePerformIO $ newTVarIO 0
{-# NOINLINE testCounter #-}

portBases :: TVar [Int]
portBases = unsafePerformIO $ newTVarIO [10000, 10010 .. 19990]
{-# NOINLINE portBases #-}

withTestEnv :: (HasTestEnv => IO a) -> IO a
withTestEnv action =
  bracket takePortBase releasePortBase $ \portBase -> do
    testNo <- atomically $ stateTVar testCounter $ \n -> (n, n + 1)
    let ?testEnv = TestEnv {testNo, portBase}
    bracket_
      (mapM_ (createDirectoryIfMissing True) [senderFiles, recipientFiles])
      (eventuallyRemove testDir 3)
      action
  where
    takePortBase =
      atomically $
        readTVar portBases >>= \case
          b : bs -> b <$ writeTVar portBases bs
          [] -> retry
    releasePortBase b = atomically $ modifyTVar' portBases (<> [b])

eventuallyRemove :: FilePath -> Int -> IO ()
eventuallyRemove path retries = case retries of
  0 -> action
  n ->
    action `E.catch` \ioe@IOError {ioe_type, ioe_filename} -> case ioe_type of
      IOException.UnsatisfiedConstraints | ioe_filename == Just path -> threadDelay 1000000 >> eventuallyRemove path (n - 1)
      _ -> E.throwIO ioe
  where
    action = removeDirectoryRecursive path

data TestWrapper a = TestWrapper (HasTestEnv => a)

-- TODO [ntfdb] running wiht LogWarn level shows potential issue "Queue count differs"
testLogLevel :: LogLevel
testLogLevel = LogError

instance Example a => Example (TestWrapper a) where
  type Arg (TestWrapper a) = Arg a
  evaluateExample (TestWrapper action) params hooks state = do
    ci <- envCI
    runTest `E.catches` [E.Handler (onTestFailure ci), E.Handler (onTestException ci)]
    where
      tt = 300
      runTest =
        withTestEnv $
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

it :: (HasCallStack, Example a) => String -> (HasTestEnv => a) -> SpecWith (Arg a)
it label action = Hspec.it label (TestWrapper action)

fit :: (HasCallStack, Example a) => String -> (HasTestEnv => a) -> SpecWith (Arg a)
fit label action = focus $ it label action

xit :: (HasCallStack, Example a) => String -> (HasTestEnv => a) -> SpecWith (Arg a)
xit label action = Hspec.xit label (TestWrapper action)
