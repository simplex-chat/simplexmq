{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.Messaging.Batch where

import Control.Monad
import Control.Monad.Error.Class (MonadError (..)) -- XXX: see the notes in MonadError instance
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.IO.Unlift (MonadUnliftIO, liftIO)
import Control.Monad.Reader (ReaderT (..))
import Control.Monad.Reader.Class (MonadReader (..))
import Control.Monad.Trans (MonadTrans, lift)
import Control.Monad.Trans.Cont (ContT (..))
import Data.Kind (Type)
import Debug.Trace
import UnliftIO (TVar, atomically, bracket, modifyTVar', newTVarIO)
import UnliftIO.MVar
import UnliftIO.STM (stateTVar)

type Parent env err m = (MonadReader env m, MonadError err m, MonadUnliftIO m)

exampleWithResults :: Parent env err m => m [(Bool, Int)]
exampleWithResults = forB [1 :: Int .. 10] $ \item -> do
  dbResult <- batchOperation SDB1 $ \ExDB -> do
    liftIO $ putStrLn ("operation on DB1 for item " <> show item)
    pure FancyResult
  -- the action that will continue with the results later (can batch more actions)
  batchOperation SNet $ \ExSocket exInt -> do
    liftIO $ putStrLn $ "Sending " <> show dbResult <> " to channel " <> show exInt
  -- the final result
  pure (dbResult == FancyResult, item)

forB :: (Parent env err m, Traversable t) => t a -> (a -> BatchT () m b) -> m (t b)
forB items action = do
  r <- newEmptyMVar
  traceM "running batched"
  runBatched $ forM items action >>= \res -> traceM "putting results" >> putMVar r res
  traceM "getting results"
  takeMVar r

example ::
  forall env err m.
  Parent env err m => -- Got to be preserved
  m Int -- produce result in Parent monad
example = do
  finalResult <- runBatched $ do
    -- prepare work
    items <- pure "work items"
    -- start running
    rs <- forM items $ \item -> do
      traceM "batching DB1"
      dbResult <- batchOperation SDB1 $ \ExDB -> do
        liftIO $ putStrLn ("operation on DB1 for item " <> show item)
        pure FancyResult
      traceM "... later ... using DB1 to batch Net"
      -- the action that will continue with the results later (can batch more actions)
      batchOperation SNet $ \ExSocket exInt -> do
        liftIO $ putStrLn $ "Sending " <> show dbResult <> " to channel " <> show exInt
      -- the final result
      traceM "... finally"
      pure (dbResult == FancyResult, item)
    -- aggregate results
    traceM "aggregating"
    liftIO $ print rs
  -- pure ()
  pure $ length $ show finalResult

btwNoBrackets :: MonadUnliftIO m => m ()
btwNoBrackets =
  flip runContT pure $ do
    -- no MonadUnliftIO for ContT
    lift . bracket (liftIO $ putStrLn "preserve unliftio") pure . const $ do
      pure () -- lost ContT - no batching inside brackets

-- a probe type to avoid confusion when reading type elaboration output
data FancyResult = FancyResult
  deriving (Eq, Show)

runBatched :: Parent env err m => BatchPlan m -> m ()
runBatched action = do
  st <- newTVarIO []
  runBatchT st action
  processAll st

-- | Process all batched items until no more items got batched.
processAll :: Parent env err m => BatchState m -> m ()
processAll st =
  atomically (stateTVar st (,[])) >>= \case
    [] -> pure ()
    batched -> do
      runBatchT st $ process batched
      processAll st

-- * Specific things

-- | Process all currently batched items.
-- Their continuations can produce more operations.
process :: Parent env err m => [ABatch m] -> BatchPlan m
process batched = do
  traceM $ "process: batched size = " <> show (length batched)
  -- TODO: partition by op?
  runDb1 batched
  runDb2 batched
  runNet batched

data Op
  = DB1
  | DB2
  | Net
  deriving (Show)

runDb1 :: Parent env err m => [ABatch m] -> BatchPlan m
runDb1 batch =
  withExDB $ \db ->
    forM_ batch $ \case
      ABatch SDB1 db_ma aBb -> lift (db_ma db) >>= aBb
      _ -> pure ()

runDb2 :: Parent env err m => [ABatch m] -> BatchPlan m
runDb2 batch =
  withExDB $ \db ->
    forM_ batch $ \case
      ABatch SDB2 action next -> lift (action db) >>= next
      _ -> pure ()

runNet :: Parent env err m => [ABatch m] -> BatchPlan m
runNet batch =
  withExSocket $ \sock ->
    forM_ (zip [0 :: Int ..] batch) $ \case
      (ix, ABatch SNet action next) -> lift (action sock ix) >>= next
      _ -> pure ()

data ExDB = ExDB

withExDB :: (ExDB -> BatchT r m a) -> BatchT r m a
withExDB action =
  -- TODO: "produce DB handle, run transcation, commit or abort, close DB handle"
  action ExDB

data ExSocket = ExSocket

withExSocket :: (ExSocket -> BatchT r m a) -> BatchT r m a
withExSocket action =
  action ExSocket -- TODO: produce socket, run connection, close socket

type family BatchStep (op :: Op) m a where
  BatchStep DB1 m a = ExDB -> m a
  BatchStep DB2 m a = ExDB -> m a
  BatchStep Net m a = ExSocket -> Int -> m a

data ABatch m = forall op a. ABatch (SOp op) (BatchStep op m a) (a -> BatchPlan m) -- XXX: add `TypeRep r` to recover final result?

data SOp :: Op -> Type where
  SDB1 :: SOp DB1
  SDB2 :: SOp DB2
  SNet :: SOp Net
deriving instance Show (SOp a)

-- the magic (:
batchOperation :: Parent env err m => SOp op -> BatchStep op m r -> BatchT () m r
batchOperation op action = do
  traceM $ "batchOperation for " <> show op
  BatchT $ ContT $ \next -> do
    traceM $ "batchOperation for " <> show op <> " (inside)"
    let abatch = ABatch op action $ \r -> BatchT . ContT $ \_next -> next r
    st <- ask
    atomically $ modifyTVar' st (abatch :)

type BatchState m = TVar [ABatch m]

type BatchPlan m = BatchT () m ()

newtype BatchT r m a = BatchT {unBatchT :: ContT r (ReaderT (BatchState m) m) a}
  deriving (Functor, Applicative, Monad, MonadIO)

instance MonadTrans (BatchT r) where
  lift :: Monad m => m a -> BatchT r m a
  lift ma = BatchT $ ContT $ \next -> lift ma >>= next

runBatchT :: Monad m => BatchState m -> BatchT a m a -> m a
runBatchT st = flip runReaderT st . flip runContT pure . unBatchT
