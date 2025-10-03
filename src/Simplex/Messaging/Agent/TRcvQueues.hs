{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}

module Simplex.Messaging.Agent.TRcvQueues
  ( TRcvQueues (getRcvQueues),
    empty,
    clear,
    hasQueue,
    addQueue,
    addSessQueue,
    batchAddQueues,
    deleteQueue,
    hasSessQueues,
    getSessQueues,
    getSessConns,
    getDelSessQueues,
    qKey,
  )
where

import Control.Concurrent.STM
import Data.Foldable (foldl')
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Simplex.Messaging.Agent.Protocol (ConnId, UserId)
import Simplex.Messaging.Agent.Store (RcvQueue, StoredRcvQueue (..))
import Simplex.Messaging.Protocol (RecipientId, SMPServer)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport

-- the fields in this record have the same data with swapped keys for lookup efficiency,
-- and all methods must maintain this invariant.
data TRcvQueues q = TRcvQueues
  { getRcvQueues :: TMap (UserId, SMPServer, RecipientId) q
  }

empty :: IO (TRcvQueues q)
empty = TRcvQueues <$> TM.emptyIO

clear :: TRcvQueues q -> STM ()
clear (TRcvQueues qs) = TM.clear qs

hasQueue :: RcvQueue -> TRcvQueues q -> STM Bool
hasQueue rq (TRcvQueues qs) = TM.member (qKey rq) qs

addQueue :: RcvQueue -> TRcvQueues RcvQueue -> STM ()
addQueue rq = addQueue_ rq rq
{-# INLINE addQueue #-}

addSessQueue :: (SessionId, RcvQueue) -> TRcvQueues (SessionId, RcvQueue) -> STM ()
addSessQueue q@(_, rq) = addQueue_ rq q
{-# INLINE addSessQueue #-}

addQueue_ :: RcvQueue -> q -> TRcvQueues q -> STM ()
addQueue_ rq q (TRcvQueues qs) = TM.insert (qKey rq) q qs

-- Save time by aggregating modifyTVar'
batchAddQueues :: TRcvQueues RcvQueue -> [RcvQueue] -> STM ()
batchAddQueues (TRcvQueues qs) rqs =
  modifyTVar' qs $ \now -> foldl' (\rqs' rq -> M.insert (qKey rq) rq rqs') now rqs

deleteQueue :: RcvQueue -> TRcvQueues q -> STM ()
deleteQueue rq (TRcvQueues qs) = TM.delete (qKey rq) qs

hasSessQueues :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues RcvQueue -> STM Bool
hasSessQueues tSess (TRcvQueues qs) = any (`isSession` tSess) <$> readTVar qs

getSessQueues :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues RcvQueue -> IO [RcvQueue]
getSessQueues tSess (TRcvQueues qs) = M.foldl' addQ [] <$> readTVarIO qs
  where
    addQ qs' rq = if rq `isSession` tSess then rq : qs' else qs'

getSessConns :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues (SessionId, RcvQueue) -> IO (S.Set ConnId)
getSessConns tSess (TRcvQueues qs) = M.foldl' addConn S.empty <$> readTVarIO qs
  where
    addConn cIds (_, rq) = if rq `isSession` tSess then S.insert (connId rq) cIds else cIds

getDelSessQueues :: (UserId, SMPServer, Maybe ConnId) -> SessionId -> TRcvQueues (SessionId, RcvQueue) -> STM ([RcvQueue], [ConnId])
getDelSessQueues tSess sessId' (TRcvQueues qs) = do
  (removedQs, removedConns, qs'') <- (\qs' -> M.foldl' delQ ([], S.empty, qs') qs') <$> readTVar qs
  writeTVar qs $! qs''
  let removedConns' = S.toList $ removedConns `S.difference` queueConns qs''
  pure (removedQs, removedConns')
  where
    delQ acc@(removed, cIds, qs') (sessId, rq)
      | rq `isSession` tSess && sessId == sessId' = (rq : removed, S.insert (connId rq) cIds, M.delete (qKey rq) qs')
      | otherwise = acc
    queueConns = M.foldl' (\cIds (_, rq) -> S.insert (connId rq) cIds) S.empty

isSession :: RcvQueue -> (UserId, SMPServer, Maybe ConnId) -> Bool
isSession rq (uId, srv, connId_) =
  userId rq == uId && server rq == srv && maybe True (connId rq ==) connId_

qKey :: RcvQueue -> (UserId, SMPServer, RecipientId)
qKey rq = (userId rq, server rq, rcvId rq)
