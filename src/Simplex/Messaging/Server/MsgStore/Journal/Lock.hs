module Simplex.Messaging.Server.MsgStore.Journal.Lock where

import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Monad
import Simplex.Messaging.Agent.Lock
import Simplex.Messaging.Agent.Client (getMapLock)
import Simplex.Messaging.Protocol (RecipientId)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (($>>), ($>>=))

withLockAndShared :: RecipientId -> Lock -> TVar (Maybe RecipientId) -> String -> IO a -> IO a
withLockAndShared rId lock shared name =
  E.bracket_
    (atomically $ retrySharedLocked rId shared >> putTMVar lock name)
    (void $ atomically $ takeTMVar lock)

withLockMapAndShared :: RecipientId -> TMap RecipientId Lock -> TVar (Maybe RecipientId) -> String -> IO a -> IO a
withLockMapAndShared rId locks shared name a =
  E.bracket
    (atomically $ retrySharedLocked rId shared >> getPutLock (getMapLock locks) rId name)
    (atomically . takeTMVar)
    (const a)

retrySharedLocked :: RecipientId -> TVar (Maybe RecipientId) -> STM ()
retrySharedLocked rId shared = readTVar shared >>= mapM_ (\rId' -> when (rId == rId') retry)

withSharedLock :: RecipientId -> TMap RecipientId Lock -> TVar (Maybe RecipientId) -> String -> IO a -> IO a
withSharedLock rId locks shared name =
  E.bracket_
    (atomically $ retryLocked >> writeTVar shared (Just rId))
    (atomically $ writeTVar shared Nothing)
  where
    retryLocked = TM.lookup rId locks $>>= tryReadTMVar $>> retry
