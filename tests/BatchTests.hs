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

batchTests :: Spec
batchTests = do
  describe "postcard example" $ do
    fit "simply works" simple
    it "internal simply works" simpleInt -- XXX: it doesn't
    fit "batching works" simpleFor
  describe "batching" $ do
    it "example works" exampleTest
    it "results work" resultsTest

-- * Postcard implementation of delayed computation with automatic stages

data Later m = forall a. Later (m a) (a -> Plan m) -- A delayed computation that can spawn more stages after the main action finishes
type Plan m = CSM () m () -- A continuation-based *planning* action.
type CSM x m r = ContT x (SM m) r -- Planning monad. The binds are only to construct an execution plan. The actuall running happens outside.
type SM m = ReaderT (S m) m -- StateT is prone to losing data in the face of exceptions AND continuations. A reader with a mutable var is used instad.
type S m = TVar [Later m] -- A mutable var to hold suspended computations.

-- | Split the plan into action and continuation parts. `next` is everything that happens after the `doLater` invocation.
-- Every call is contributing to a pool of planned actions.
--
-- @
-- plan = do
--   x <- doLater action
--   next x
-- @
doLater :: MonadIO m => m r -> CSM () m r
doLater action = ContT $ \nextR -> do
  let later = Later action (\r -> ContT $ \nextU -> nextU () >> nextR r)
  s <- ask
  atomically $ modifyTVar' s (later :)

_runPlan :: MonadIO m => Plan m -> m ()
_runPlan action = do
  st <- newTVarIO []
  runSimple st action
  runAllStages st

-- this works by interleaving planning and running (and planning next stage)
runAllStages :: MonadIO m => S m -> m ()
runAllStages st = do
  late <- atomically $ stateTVar st (,[]) -- get all the suspended steps
  -- the computations can now be inspected, partitioned, discarded etc.
  runSimple st $ -- get planning facilities back -- get planning facilities back
  -- get planning facilities back
    forM_ late $ \(Later action next) ->
      lift (lift action) >>= next -- fuse action with its continuation, producing effects in `m`
      -- XXX: alternatively, ...
      -- forM_ late $ \(Later action next) ->
      --   action >>= runSimple st . next -- ... provide planning facilities where needed
  unless (null late) $ runAllStages st -- run until no more stages planned

-- just peeling the layers
runSimple :: Applicative m => S m -> CSM x m x -> m x
runSimple st csm = runReaderT (runContT csm pure) st

-- ** Explicit running points using runners embedd in the plan (doesn't work)

-- XXX: this doesn't work, since we're only planning to run sometime and never actually run the plan.
runSimpleInt :: MonadIO m => Plan m -> m ()
runSimpleInt plan = do
  st <- newTVarIO []
  runSimple st $ do
    plan
    runInternal

runInternal :: MonadIO m => Plan m
runInternal = do
  st <- ask
  late <- atomically $ stateTVar st (,[])
  forM_ late $ \(Later action next) ->
    lift (lift action) >>= next
  unless (null late) runInternal

-- ** Examples / tests

simple :: IO ()
simple = do
  traceM "\n"
  st <- newTVarIO []
  () <- runSimple st $ do
    traceM "simple"
    x <- pure 'x'
    traceM "x <- pure 'x'"
    xy <- doLater $ pure $ x : ['y']
    traceM "y <- doLater $ pure $ x : ['y']"
    () <- doLater $ traceM $ "final: " <> xy
    traceM "() <- doLater $ traceM $ \"final: \" <> xy"
    pure () -- no results... we're just planning here
  late1 <- readTVarIO st
  length late1 `shouldBe` 1 -- one item queued
  runAllStages st
  late2 <- readTVarIO st
  length late2 `shouldBe` 0 -- all the steps are fully processed despite being multiple layers deep
  runAllStages st -- nothing happens

simpleFor :: IO ()
simpleFor = do
  traceM "\n"
  let items = "abc"
  st <- newTVarIO []
  getResults <- forB st items $ \item -> do
    twice <- doLater $ pure [item, item]
    doLater $ pure (item : "*2 = " <> twice)
  length <$> readTVarIO st `shouldReturn` length items
  runAllStages st
  getResults `shouldReturn` ["a*2 = aa", "b*2 = bb", "c*2 = cc"]

forB :: (MonadIO m, Traversable t) => S m -> t input -> (input -> CSM () m output) -> m (m (t output))
forB st inputs action = do
  results <- forM inputs $ \input -> do
    -- submit actions per-input
    result <- newEmptyMVar
    runSimple st $ action input >>= putMVar result -- every action gets its own track with a final action "collect results"
    pure result -- return result promise
  pure $ forM results $ tryTakeMVar >=> maybe (error "task didn't finish") pure

simpleInt :: IO ()
simpleInt = do
  traceM "\n"
  reached <- newIORef False
  runSimpleInt $ do
    traceM "simpleInt:"
    x <- pure 'x'
    traceM "x <- pure 'x'"
    xy <- doLater $ pure $ x : ['y']
    runInternal -- BUG: never gets a chance to execute as it is fenced off by doLater above it
    traceM "y <- doLater $ pure $ x : ['y']"
    () <- doLater $ traceM $ "final: " <> xy
    traceM "() <- doLater $ traceM $ \"final: \" <> xy"
    writeIORef reached True
  readIORef reached `shouldReturn` False

exampleTest :: Expectation
exampleTest = runTestMonad Batch.example `shouldReturn` Right 2

resultsTest :: Expectation
resultsTest =
  runTestMonad Batch.exampleWithResults
    `shouldReturn` Right
      [ (True, 1),
        (True, 2),
        (True, 3),
        (True, 4),
        (True, 5),
        (True, 6),
        (True, 7),
        (True, 8),
        (True, 9),
        (True, 10)
      ]

type TestMonad = ExceptT Oops (ReaderT Char IO)
data Oops = Oops deriving (Eq, Show)
instance Exception Oops
instance MonadUnliftIO TestMonad where -- i wonder how our main code gets MonadUnliftIO from ChatMonad m with a mere `runExceptT`
  withRunInIO f = ExceptT $ ReaderT $ \env ->
    try $ f $ \action ->
      runReaderT (runExceptT action) env >>= either throwIO pure

runTestMonad :: TestMonad a -> IO (Either Oops a)
runTestMonad action = runReaderT (runExceptT action) 'R'
