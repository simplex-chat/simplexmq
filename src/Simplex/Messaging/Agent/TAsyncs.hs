module Simplex.Messaging.Agent.TAsyncs where

import Control.Monad.IO.Unlift (MonadUnliftIO)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import UnliftIO.Async (Async, async)
import UnliftIO.STM

data TAsyncs = TAsyncs
  { actionId :: TVar Int,
    actions :: TMap Int (Async ())
  }

newTAsyncs :: STM TAsyncs
newTAsyncs = TAsyncs <$> newTVar 0 <*> TM.empty

newAsyncAction :: MonadUnliftIO m => (Int -> m ()) -> TAsyncs -> m ()
newAsyncAction action as = do
  aId <- atomically $ stateTVar (actionId as) $ \i -> (i + 1, i + 1)
  a <- async $ action aId
  atomically $ TM.insert aId a $ actions as

removeAsyncAction :: Int -> TAsyncs -> STM ()
removeAsyncAction aId = TM.delete aId . actions
