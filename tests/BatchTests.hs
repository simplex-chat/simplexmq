{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}

module BatchTests (batchTests) where

import Control.Monad
import Control.Monad.Cont
import Control.Monad.Except (MonadError (..), tryError)
import Control.Monad.Reader (MonadTrans (..), ReaderT (..), ask)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import qualified Data.Map.Strict as M
import Debug.Trace
import Simplex.Messaging.Batch
import Test.Hspec
import UnliftIO

batchTests :: Spec
batchTests = do
  fdescribe "error handling" $ do
    it "basic" testBasicErrors

-- it "mapped" testMappedErrors

testBasicErrors :: IO ()
testBasicErrors = do
  tests <- newTVarIO mempty
  getResults <- forM "abcde" $ \l -> do
    result <- newEmptyMVar
    flip runEContT (final result) $ do
      x <- ebatchOperation tests $ \c -> runExceptT $ pure [l, c]
      when (l == 'b') $ throwError 1 -- the train for 'b' should stop now
      when (l == 'c') (throwError 2) `catchError` \_no_c -> pure () -- the 'c' train rolls on
      y <- ebatchOperation tests $ \c -> runExceptT $ do
        when (l == 'd') $ throwError 3 -- there's no d-fference throwing inside or outside
        pure $ c : x
      pure y
    pure $ tryTakeMVar result >>= maybe (error "did not run") pure
  processAll tests
  sequence getResults
    `shouldReturn` [ Right "!a!",
                     Left 1, -- thrown from plan
                     Right "!c!", -- thrown/catched
                     Left 3, -- thrown from action
                     Right "!e!" -- still works
                   ]
  where
    final result r = tryPutMVar result r >>= \ok -> unless ok $ error "already run!"
    processAll :: TestBatch IO -> IO ()
    processAll testBatch = do
      tests <- atomically $ stateTVar testBatch (,[])
      runEContT (unless (null tests) $ processTestBatch tests) $ \case
        Left e -> traceShowM e >> pure ()
        Right () -> pure ()
      unless (null tests) $ processAll testBatch
    processTestBatch :: [EBatch Test IO] -> EBatchT IO Int ()
    processTestBatch tests = do
      rc <- newIORef (0 :: Int)
      rs <- liftIO $
        bracket_ (modifyIORef' rc (+ 1)) (modifyIORef' rc (\x -> x - 1)) $
          forM tests $ \(EBatch action next) ->
            -- catchError (Right <$> action '!') (pure . Left) >>= \case
            tryError (action '!') >>= \case
              Right ok -> pure $ next ok
              Left err -> pure $ traceShowM ('e', err) -- the train stops now
      sequence_ rs
      liftIO $ readIORef rc `shouldReturn` 0

data Test
type instance EBatchArgs Test = Char
type instance EBatchError Test = Int
type TestBatch m = EBatchVar Test m
