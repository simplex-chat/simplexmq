{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}

module BatchTests (batchTests) where

import Control.Monad
import Control.Monad.Except (MonadError (..), tryError)
import Control.Monad.Trans.Except (runExceptT)
import Debug.Trace
import Simplex.Messaging.Batch
import Test.Hspec
import UnliftIO

batchTests :: Spec
batchTests = do
  fdescribe "error handling" $ do
    it "basic" testBasicErrors
    it "mapped" testMappedErrors

testBasicErrors :: IO ()
testBasicErrors = do
  tests <- newTVarIO mempty
  shmests <- newTVarIO mempty
  getResults <- forM "abcde" $ \l -> execEContT $ do
    x <- batchOperation tests $ \c -> runExceptT $ pure [l, c]
    when (l == 'b') $ throwError 1 -- the train for 'b' should stop now
    when (l == 'c') (throwError 2) `catchError` \_no_c -> pure () -- the 'c' train rolls on
    y <- batchOperation tests $ \c -> runExceptT $ do
      when (l == 'd') $ throwError 3 -- there's no d-fference throwing inside or outside
      pure $ c : x
    pure y
  processAll tests shmests
  sequence getResults
    `shouldReturn` [ Right "!a!",
                     Left 1, -- thrown from plan
                     Right "!c!", -- thrown/catched
                     Left 3, -- thrown from action
                     Right "!e!" -- still works
                   ]

testMappedErrors :: IO ()
testMappedErrors = do
  tests <- newTVarIO mempty
  shmests <- newTVarIO mempty
  getResults <- forM "abcde" $ \l -> execEContT $ do
    x <- batchOperation tests $ \c -> runExceptT $ pure [l, c]
    when (l == 'c') (throwError 2) `catchError` \_no_c -> pure ()
    mapEContT (\e -> if e then 100 else 500) $ do
      when (l == 'b') $ throwError True
      batchOperation shmests $ \s -> runExceptT $ do
        when (l == 'd') $ throwError False
        pure $ maybe '_' (\() -> '^') s : x
  processAll tests shmests
  sequence getResults
    `shouldReturn` [ Right "_a!",
                     Left 100,
                     Right "_c!",
                     Left 500,
                     Right "_e!"
                   ]

processAll :: TestBatch IO -> ShmestBatch IO -> IO ()
processAll testBatch shmestBatch = do
  tests <- atomically $ stateTVar testBatch (,[])
  shmests <- atomically $ stateTVar shmestBatch (,[])
  runEContT (unless (null tests) $ processTestBatch tests) $ \case
    Left e -> traceShowM e >> pure ()
    Right () -> pure ()
  runEContT (unless (null shmests) $ processShmestBatch shmests) $ \case
    Left e -> traceShowM e >> pure ()
    Right () -> pure ()
  unless (null tests && null shmests) $ processAll testBatch shmestBatch

data Test
type instance BatchArgs Test = Char
type instance BatchError Test = Int
type TestBatch m = BatchVar Test m

processTestBatch :: [Batch Test IO] -> BatchT Int IO ()
processTestBatch tests = do
  rc <- newIORef (0 :: Int)
  rs <- liftIO $
    bracket_ (modifyIORef' rc (+ 1)) (modifyIORef' rc (\x -> x - 1)) $
      forM tests $ \(Batch action next) ->
        tryError (action '!') >>= \case
          Right ok -> pure $ next ok
          Left err -> pure $ traceShowM ('e', err) -- the train stops now
  sequence_ rs
  liftIO $ readIORef rc `shouldReturn` 0

data Shmest
type instance BatchArgs Shmest = Maybe ()
type instance BatchError Shmest = Bool
type ShmestBatch m = BatchVar Shmest m

processShmestBatch :: [Batch Shmest IO] -> BatchT Bool IO ()
processShmestBatch shmests = do
  rs <- liftIO $
    forM shmests $ \Batch {step, next} ->
      tryError (step Nothing) >>= \case
        Right ok -> pure $ next ok
        Left err -> pure $ traceShowM ('e', err) -- the train stops now
  sequence_ rs
