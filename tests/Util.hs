module Util where

import Control.Monad (replicateM, when)
import Data.Either (partitionEithers)
import Data.List (tails)
import GHC.Conc (getNumCapabilities, getNumProcessors, setNumCapabilities)
import System.Directory (doesFileExist, removeFile)
import Test.Hspec
import UnliftIO

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
