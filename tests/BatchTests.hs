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
  tests2 <- newTVarIO mempty
  getResults <- forM "abcde" $ \l -> execEContT $ do
    x <- batchOperation tests $ \c -> runExceptT $ pure [l, c]
    when (l == 'b') $ throwError 1 -- the train for 'b' should stop now
    when (l == 'c') (throwError 2) `catchError` \_no_c -> pure () -- the 'c' train rolls on
    y <- batchOperation tests $ \c -> runExceptT $ do
      when (l == 'd') $ throwError 3 -- there's no d-fference throwing inside or outside
      pure $ c : x
    pure $ reverse y
  processAll tests tests2
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
  tests2 <- newTVarIO mempty
  getResults <- forM "abcde" $ \l -> execEContT $ do
    x <- batchOperation tests $ \c -> runExceptT $ pure [l, c]
    when (l == 'c') (throwError 2) `catchError` \_no_c -> pure ()
    mapEContT (\e -> if e then 100 else 500) $ do
      when (l == 'b') $ throwError True
      batchOperation tests2 $ \s -> runExceptT $ do
        when (l == 'd') $ throwError False
        pure $ maybe '_' (\() -> '^') s : x
  processAll tests tests2
  sequence getResults
    `shouldReturn` [ Right "_a!",
                     Left 100,
                     Right "_c!",
                     Left 500,
                     Right "_e!"
                   ]

processAll :: TestBatch IO -> Test2Batch IO -> IO ()
processAll testBatch shmestBatch = do
  tests <- atomically $ stateTVar testBatch (,[])
  tests2 <- atomically $ stateTVar shmestBatch (,[])
  runEContT (unless (null tests) $ processTestBatch tests) $ \case
    Left e -> traceShowM e
    Right () -> pure ()
  runEContT (unless (null tests2) $ processTest2Batch tests2) $ \case
    Left e -> traceShowM e
    Right () -> pure ()
  unless (null tests && null tests2) $ processAll testBatch shmestBatch

data Test
type instance BatchArgs Test = Char
type instance BatchError Test = Int
type TestBatch m = BatchVar Test m

processTestBatch :: [BatchOperation Test IO] -> BatchT Int IO ()
processTestBatch tests = do
  rc <- newIORef (0 :: Int)
  rs <- liftIO $
    bracket_ (modifyIORef' rc (+ 1)) (modifyIORef' rc (\x -> x - 1)) $
      forM tests $ \BatchOperation {step, next} ->
        tryError (step '!') >>= \case
          Right ok -> pure $ next ok
          Left err -> pure $ traceShowM ('e', err) -- the train stops now
  sequence_ rs
  liftIO $ readIORef rc `shouldReturn` 0

data Test2
type instance BatchArgs Test2 = Maybe ()
type instance BatchError Test2 = Bool
type Test2Batch m = BatchVar Test2 m

processTest2Batch :: [BatchOperation Test2 IO] -> BatchT Bool IO ()
processTest2Batch tests2 = do
  rs <- liftIO $
    forM tests2 $ \BatchOperation {step, next} ->
      tryError (step Nothing) >>= \case
        Right ok -> pure $ next ok
        Left err -> pure $ traceShowM ('e', err) -- the train stops now
  sequence_ rs
