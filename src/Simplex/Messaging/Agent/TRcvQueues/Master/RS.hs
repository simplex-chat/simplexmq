module Simplex.Messaging.Agent.TRcvQueues.Master.RS where

import Control.Concurrent.STM
import qualified Data.Set as S
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.Store (RcvQueue, qConnId)
import Simplex.Messaging.Agent.TRcvQueues.Master

removeSubs :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues -> TRcvQueues -> STM ([RcvQueue], [ConnId])
removeSubs tSess activeSubs pendingSubs = do
  qs <- getDelSessQueuesFlip tSess activeSubs
  mapM_ (`addQueue` pendingSubs) qs
  cs' <- getConns activeSubs
  pure (qs, filter (`S.notMember` cs') $ map qConnId qs)

removeSubsSet :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues -> TRcvQueues -> STM ([RcvQueue], [ConnId])
removeSubsSet tSess activeSubs pendingSubs = do
  qs <- getDelSessQueuesFlip tSess activeSubs
  mapM_ (`addQueue` pendingSubs) qs
  let cs = S.fromList $ map qConnId qs
  cs' <- getConns activeSubs
  pure (qs, S.toList $ cs `S.difference` cs')
