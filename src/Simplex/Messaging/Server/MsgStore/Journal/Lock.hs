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

-- wait until shared lock with passed ID is released and take lock
withLockWaitShared :: RecipientId -> Lock -> TMVar RecipientId -> String -> IO a -> IO a
withLockWaitShared rId lock shared name =
  E.bracket_
    (atomically $ waitShared rId shared >> putTMVar lock name)
    (void $ atomically $ takeTMVar lock)

-- wait until shared lock with passed ID is released and take lock from Map for this ID
withLockMapWaitShared :: RecipientId -> TMap RecipientId Lock -> TMVar RecipientId -> String -> IO a -> IO a
withLockMapWaitShared rId locks shared name a =
  E.bracket
    (atomically $ waitShared rId shared >> getPutLock (getMapLock locks) rId name)
    (atomically . takeTMVar)
    (const a)

waitShared :: RecipientId -> TMVar RecipientId -> STM ()
waitShared rId shared = tryReadTMVar shared >>= mapM_ (\rId' -> when (rId == rId') retry)

-- wait until lock with passed ID in Map is released and take shared lock for this ID
withSharedLock :: RecipientId -> TMap RecipientId Lock -> TMVar RecipientId -> IO a -> IO a
withSharedLock rId locks shared =
  E.bracket_
    (atomically $ waitLock >> putTMVar shared rId)
    (atomically $ takeTMVar shared)
  where
    waitLock = TM.lookup rId locks $>>= tryReadTMVar $>> retry
