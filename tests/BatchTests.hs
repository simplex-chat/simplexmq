{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TupleSections #-}

module BatchTests (batchTests) where

import Control.Monad
import Control.Monad.Cont
import Control.Monad.Except (ExceptT (..), runExceptT)
import Control.Monad.Reader (MonadTrans (..), ReaderT (..), ask)
import Debug.Trace
import qualified Simplex.Messaging.Batch as Batch
import Test.Hspec
import UnliftIO
import qualified Data.Map.Strict as M

batchTests :: Spec
batchTests = do
  describe "postcard example" $ do
    it "works" testWorks

testWorks :: IO ()
testWorks = do

  pure ()
