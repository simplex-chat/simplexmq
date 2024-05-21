module Util where

import Control.Monad (replicateM)
import Data.Either (partitionEithers)
import GHC.Conc (getNumCapabilities, getNumProcessors, setNumCapabilities)
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
