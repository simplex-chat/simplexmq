{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}

module Simplex.Messaging.Worker where

import Control.Concurrent (ThreadId)
import Control.Monad.Reader
import Data.Int (Int64)
import Data.Time.Clock.System (SystemTime (..))
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import System.Mem.Weak (Weak)
import UnliftIO.STM

data Worker = Worker
  { workerId :: Int,
    doWork :: TMVar (),
    action :: TMVar (Maybe (Weak ThreadId)),
    restarts :: TVar RestartCount
  }

data RestartCount = RestartCount
  { restartMinute :: Int64,
    restartCount :: Int
  }

updateRestartCount :: SystemTime -> RestartCount -> RestartCount
updateRestartCount t (RestartCount minute count) = do
  let min' = systemSeconds t `div` 60
   in RestartCount min' $ if minute == min' then count + 1 else 1

getAgentWorker :: (Ord k, Show k) => String -> Bool -> AgentClient -> k -> TMap k Worker -> (Worker -> AM ()) -> AM' Worker
getAgentWorker = getAgentWorker' id pure
{-# INLINE getAgentWorker #-}

-- TODO These fields are used from AgentClient:
-- TODO   - workerSeq :: TVar Int - can create one in ChatController;
-- TODO   - active :: TVar Bool - it seems we need to additionally keep track of it in chat (?);
-- TODO   - subQ :: TBQueue ATransmission - don't need this mechanism of notification in chat;
-- TODO They should be passed as separate parameters, or we can create a new type to use both in chat and agent.
-- TODO
-- TODO AM, AM' monads should be replaced with generic ones, allowing different error and reader types.
-- TODO In agent we use AgentErrorType, Env, in chat - ChatError, ChatController.
-- TODO Similarly for tryAgentError' - should work with any error type.
-- TODO We can use tryAllErrors' and pass different error converter (agent uses mkInternal).
getAgentWorker' :: forall a k. (Ord k, Show k) => (a -> Worker) -> (Worker -> STM a) -> String -> Bool -> AgentClient -> k -> TMap k a -> (a -> AM ()) -> AM' a
getAgentWorker' toW fromW name hasWork c key ws work = do
  atomically (getWorker >>= maybe createWorker whenExists) >>= \w -> runWorker w $> w
  where
    getWorker = TM.lookup key ws
    createWorker = do
      w <- fromW =<< newWorker (workerSeq c)
      TM.insert key w ws
      pure w
    whenExists w
      | hasWork = hasWorkToDo (toW w) $> w
      | otherwise = pure w
    runWorker w = runWorkerAsync (toW w) runWork
      where
        runWork :: AM' ()
        runWork = tryAgentError' (work w) >>= restartOrDelete
        restartOrDelete :: Either AgentErrorType () -> AM' ()
        restartOrDelete e_ = do
          t <- liftIO getSystemTime
          maxRestarts <- asks $ maxWorkerRestartsPerMin . config
          -- worker may terminate because it was deleted from the map (getWorker returns Nothing), then it won't restart
          restart <- atomically $ getWorker >>= maybe (pure False) (shouldRestart e_ (toW w) t maxRestarts)
          when restart runWork
        shouldRestart e_ Worker {workerId = wId, doWork, action, restarts} t maxRestarts w'
          | wId == workerId (toW w') = do
              rc <- readTVar restarts
              isActive <- readTVar $ active c
              checkRestarts isActive $ updateRestartCount t rc
          | otherwise =
              pure False -- there is a new worker in the map, no action
          where
            checkRestarts isActive rc
              | isActive && restartCount rc < maxRestarts = do
                  writeTVar restarts rc
                  hasWorkToDo' doWork
                  void $ tryPutTMVar action Nothing
                  notifyErr INTERNAL -- TODO replace AgentErrorType
                  pure True
              | otherwise = do
                  TM.delete key ws
                  when isActive $ notifyErr $ CRITICAL True -- TODO replace AgentErrorType
                  pure False
              where
                notifyErr err = do -- TODO chat could throw/show error directly
                  let e = either ((", error: " <>) . show) (\_ -> ", no error") e_
                      msg = "Worker " <> name <> " for " <> show key <> " terminated " <> show (restartCount rc) <> " times" <> e
                  writeTBQueue (subQ c) ("", "", AEvt SAEConn $ ERR $ err msg)

newWorker :: TVar Int -> STM Worker
newWorker workerSeq = do
  workerId <- stateTVar workerSeq $ \next -> (next, next + 1)
  doWork <- newTMVar ()
  action <- newTMVar Nothing
  restarts <- newTVar $ RestartCount 0 0
  pure Worker {workerId, doWork, action, restarts}

-- TODO need to use parameter instead of Env, in chat it's ChatController
runWorkerAsync :: Worker -> ReaderT Env IO () -> ReaderT Env IO ()
runWorkerAsync Worker {action} work =
  E.bracket
    (atomically $ takeTMVar action) -- get current action, locking to avoid race conditions
    (atomically . tryPutTMVar action) -- if it was running (or if start crashes), put it back and unlock (don't lock if it was just started)
    (\a -> when (isNothing a) start) -- start worker if it's not running
  where
    start = atomically . putTMVar action . Just =<< mkWeakThreadId =<< forkIO work
