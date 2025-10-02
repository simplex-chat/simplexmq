{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Agent.TRcvQueues
  ( TRcvQueues (getRcvQueues, getConnections),
    RcvQueueCreds (..),
    empty,
    clear,
    deleteConn,
    hasConn,
    addQueue,
    addSessQueue,
    batchAddQueues,
    deleteQueue,
    hasSessQueues,
    getSessQueues,
    getDelSessQueues,
    qKey,
  )
where

import Control.Concurrent.STM
import Data.Foldable (foldl')
import Data.List.NonEmpty (NonEmpty (..), (<|))
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Simplex.Messaging.Agent.Protocol (ConnId, QueueStatus, UserId)
import Simplex.Messaging.Agent.Store (RcvQueueSub (..))
import Simplex.Messaging.Protocol (RcvPrivateAuthKey, RecipientId, SMPServer)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport

-- the fields in this record have the same data with swapped keys for lookup efficiency,
-- and all methods must maintain this invariant.
data TRcvQueues q = TRcvQueues
  { getRcvQueues :: TMap (UserId, SMPServer, RecipientId) q,
    getConnections :: TMap ConnId (NonEmpty (UserId, SMPServer, RecipientId))
  }

data RcvQueueCreds = RcvQueueCreds
  { connId_ :: ConnId,
    rcvPrivateKey_ :: RcvPrivateAuthKey,
    status_ :: QueueStatus
  }
  deriving (Show)

rqCreds :: RcvQueueSub -> RcvQueueCreds
rqCreds RcvQueueSub {connId, rcvPrivateKey, status} =
  RcvQueueCreds {connId_ = connId, rcvPrivateKey_ = rcvPrivateKey, status_ = status}

empty :: IO (TRcvQueues q)
empty = TRcvQueues <$> TM.emptyIO <*> TM.emptyIO

clear :: TRcvQueues q -> STM ()
clear (TRcvQueues qs cs) = TM.clear qs >> TM.clear cs

deleteConn :: ConnId -> TRcvQueues q -> STM ()
deleteConn cId (TRcvQueues qs cs) =
  TM.lookupDelete cId cs >>= \case
    Just ks -> modifyTVar' qs $ \qs' -> foldl' (flip M.delete) qs' ks
    Nothing -> pure ()

hasConn :: ConnId -> TRcvQueues q -> STM Bool
hasConn cId (TRcvQueues _ cs) = TM.member cId cs

addQueue :: RcvQueueSub -> TRcvQueues RcvQueueCreds -> STM ()
addQueue rq = addQueue_ rq (rqCreds rq)
{-# INLINE addQueue #-}

addSessQueue :: (SessionId, RcvQueueSub) -> TRcvQueues (SessionId, RcvQueueCreds) -> STM ()
addSessQueue (sessId, rq) = addQueue_ rq (sessId, rqCreds rq)
{-# INLINE addSessQueue #-}

addQueue_ :: RcvQueueSub -> q -> TRcvQueues q -> STM ()
addQueue_ rq q (TRcvQueues qs cs) = do
  TM.insert k q qs
  TM.alter addQ (connId rq) cs
  where
    addQ = Just . maybe (k :| []) (k <|)
    k = qKey rq

-- Save time by aggregating modifyTVar'
batchAddQueues :: TRcvQueues RcvQueueCreds -> [RcvQueueSub] -> STM ()
batchAddQueues (TRcvQueues qs cs) rqs = do
  modifyTVar' qs $ \now -> foldl' (\rqs' rq -> M.insert (qKey rq) (rqCreds rq) rqs') now rqs
  modifyTVar' cs $ \now -> foldl' (\cs' rq -> M.alter (addQ $ qKey rq) (connId rq) cs') now rqs
  where
    addQ k = Just . maybe (k :| []) (k <|)

deleteQueue :: RcvQueueSub -> TRcvQueues RcvQueueCreds -> STM ()
deleteQueue rq (TRcvQueues qs cs) = do
  TM.delete k qs
  TM.update delQ (connId rq) cs
  where
    delQ = L.nonEmpty . L.filter (/= k)
    k = qKey rq

hasSessQueues :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues RcvQueueCreds -> STM Bool
hasSessQueues tSess (TRcvQueues qs _) = any (`isSession'` tSess) . M.assocs <$> readTVar qs

getSessQueues :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues RcvQueueCreds -> IO [RcvQueueSub]
getSessQueues tSess (TRcvQueues qs _) = M.foldlWithKey' addQ [] <$> readTVarIO qs
  where
    addQ qs' k@(userId, server, rcvId) rq@RcvQueueCreds {connId_, rcvPrivateKey_, status_} =
      if (k, rq) `isSession'` tSess then rq' : qs' else qs'
      where
        rq' = RcvQueueSub {userId, connId = connId_, server, rcvId, rcvPrivateKey = rcvPrivateKey_, status = status_}

getDelSessQueues :: (UserId, SMPServer, Maybe ConnId) -> SessionId -> TRcvQueues (SessionId, RcvQueueCreds) -> STM ([RcvQueueSub], [ConnId])
getDelSessQueues tSess sessId' (TRcvQueues qs cs) = do
  (removedQs, qs'') <- (\qs' -> M.foldlWithKey' delQ ([], qs') qs') <$> readTVar qs
  writeTVar qs $! qs''
  removedConns <- stateTVar cs $ \cs' -> foldl' delConn ([], cs') removedQs
  pure (removedQs, removedConns)
  where
    delQ acc@(removed, qs') k@(userId, server, rcvId) (sessId, rq@RcvQueueCreds {connId_, rcvPrivateKey_, status_})
      | (k, rq) `isSession'` tSess && sessId == sessId' = (rq' : removed, M.delete k qs')
      | otherwise = acc
      where
        rq' = RcvQueueSub {userId, connId = connId_, server, rcvId, rcvPrivateKey = rcvPrivateKey_, status = status_}
    delConn :: ([ConnId], M.Map ConnId (NonEmpty (UserId, SMPServer, RecipientId))) -> RcvQueueSub -> ([ConnId], M.Map ConnId (NonEmpty (UserId, SMPServer, RecipientId)))
    delConn (removed, cs') rq = M.alterF f cId cs'
      where
        cId = connId rq
        f = \case
          Just ks -> case L.nonEmpty $ L.filter (qKey rq /=) ks of
            Just ks' -> (removed, Just ks')
            Nothing -> (cId : removed, Nothing)
          Nothing -> (removed, Nothing) -- "impossible" in invariant holds, because we get keys from the known queues

isSession' :: ((UserId, SMPServer, RecipientId), RcvQueueCreds) -> (UserId, SMPServer, Maybe ConnId) -> Bool
isSession' ((userId, server, _), RcvQueueCreds {connId_}) (uId, srv, connId') =
  userId == uId && server == srv && maybe True (connId_ ==) connId'

qKey :: RcvQueueSub -> (UserId, SMPServer, RecipientId)
qKey rq = (userId rq, server rq, rcvId rq)
