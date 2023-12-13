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
    it "mapped" testMappedErrors

testBasicErrors :: IO ()
testBasicErrors = do
  tests <- newTVarIO mempty
  shmests <- newTVarIO mempty
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
  getResults <- forM "abcde" $ \l -> do
    result <- newEmptyMVar
    flip runEContT (final result) $ do
      x <- ebatchOperation tests $ \c -> runExceptT $ pure [l, c]
      when (l == 'c') (throwError 2) `catchError` \_no_c -> pure ()
      mapEContT (\e -> if e then 100 else 500) $ do
        when (l == 'b') $ throwError True
        ebatchOperation shmests $ \s -> runExceptT $ do
          when (l == 'd') $ throwError False
          pure $ maybe '_' (\() -> '^') s : x
    pure $ tryTakeMVar result >>= maybe (error "did not run") pure
  processAll tests shmests
  sequence getResults
    `shouldReturn` [ Right "_a!",
                     Left 100,
                     Right "_c!",
                     Left 500,
                     Right "_e!"
                   ]

final result r = tryPutMVar result r >>= \ok -> unless ok $ error "already ran!" -- must not happen

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

processTestBatch :: [EBatch Test IO] -> EBatchT IO Int ()
processTestBatch tests = do
  rc <- newIORef (0 :: Int)
  rs <- liftIO $
    bracket_ (modifyIORef' rc (+ 1)) (modifyIORef' rc (\x -> x - 1)) $
      forM tests $ \(EBatch action next) ->
        tryError (action '!') >>= \case
          Right ok -> pure $ next ok
          Left err -> pure $ traceShowM ('e', err) -- the train stops now
  sequence_ rs
  liftIO $ readIORef rc `shouldReturn` 0

processShmestBatch :: [EBatch Shmest IO] -> EBatchT IO Bool ()
processShmestBatch shmests = do
  rs <- liftIO $
    forM shmests $ \(EBatch action next) ->
      tryError (action Nothing) >>= \case
        Right ok -> pure $ next ok
        Left err -> pure $ traceShowM ('e', err) -- the train stops now
  sequence_ rs

data Test
type instance EBatchArgs Test = Char
type instance EBatchError Test = Int
type TestBatch m = EBatchVar Test m

data Shmest
type instance EBatchArgs Shmest = Maybe ()
type instance EBatchError Shmest = Bool
type ShmestBatch m = EBatchVar Shmest m
