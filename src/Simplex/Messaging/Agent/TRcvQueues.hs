{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}

module Simplex.Messaging.Agent.TRcvQueues
  ( TRcvQueues (getRcvQueues, getConnections),
    Queue (..),
    empty,
    clear,
    deleteConn,
    hasConn,
    addQueue,
    batchAddQueues,
    deleteQueue,
    hasSessQueues,
    getSessQueues,
    getDelSessQueues,
  )
where

import Control.Concurrent.STM
import Data.Foldable (foldl')
import Data.List.NonEmpty (NonEmpty (..), (<|))
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Simplex.Messaging.Agent.Protocol (ConnId, UserId)
import Simplex.Messaging.Agent.Store (RcvQueue, StoredRcvQueue (..))
import Simplex.Messaging.Protocol (RecipientId, SMPServer)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport

class Queue q where
  connId' :: q -> ConnId
  qKey :: q -> (UserId, SMPServer, ConnId)

-- the fields in this record have the same data with swapped keys for lookup efficiency,
-- and all methods must maintain this invariant.
data TRcvQueues q = TRcvQueues
  { getRcvQueues :: TMap (UserId, SMPServer, RecipientId) q,
    getConnections :: TMap ConnId (NonEmpty (UserId, SMPServer, RecipientId))
  }

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

addQueue :: Queue q => q -> TRcvQueues q -> STM ()
addQueue rq (TRcvQueues qs cs) = do
  TM.insert k rq qs
  TM.alter addQ (connId' rq) cs
  where
    addQ = Just . maybe (k :| []) (k <|)
    k = qKey rq

-- Save time by aggregating modifyTVar
batchAddQueues :: (Foldable t, Queue q) => TRcvQueues q -> t q -> STM ()
batchAddQueues (TRcvQueues qs cs) rqs = do
  modifyTVar' qs $ \now -> foldl' (\rqs' rq -> M.insert (qKey rq) rq rqs') now rqs
  modifyTVar' cs $ \now -> foldl' (\cs' rq -> M.alter (addQ $ qKey rq) (connId' rq) cs') now rqs
  where
    addQ k = Just . maybe (k :| []) (k <|)

deleteQueue :: RcvQueue -> TRcvQueues RcvQueue -> STM ()
deleteQueue rq (TRcvQueues qs cs) = do
  TM.delete k qs
  TM.update delQ (connId rq) cs
  where
    delQ = L.nonEmpty . L.filter (/= k)
    k = qKey rq

hasSessQueues :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues RcvQueue -> STM Bool
hasSessQueues tSess (TRcvQueues qs _) = any (`isSession` tSess) <$> readTVar qs

getSessQueues :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues RcvQueue -> IO [RcvQueue]
getSessQueues tSess (TRcvQueues qs _) = M.foldl' addQ [] <$> readTVarIO qs
  where
    addQ qs' rq = if rq `isSession` tSess then rq : qs' else qs'

getDelSessQueues :: (UserId, SMPServer, Maybe ConnId) -> SessionId -> TRcvQueues (SessionId, RcvQueue) -> STM ([RcvQueue], [ConnId])
getDelSessQueues tSess sessId' (TRcvQueues qs cs) = do
  (removedQs, qs'') <- (\qs' -> M.foldl' delQ ([], qs') qs') <$> readTVar qs
  writeTVar qs $! qs''
  removedConns <- stateTVar cs $ \cs' -> foldl' delConn ([], cs') removedQs
  pure (removedQs, removedConns)
  where
    delQ acc@(removed, qs') (sessId, rq)
      | rq `isSession` tSess && sessId == sessId' = (rq : removed, M.delete (qKey rq) qs')
      | otherwise = acc
    delConn :: ([ConnId], M.Map ConnId (NonEmpty (UserId, SMPServer, ConnId))) -> RcvQueue -> ([ConnId], M.Map ConnId (NonEmpty (UserId, SMPServer, ConnId)))
    delConn (removed, cs') rq = M.alterF f cId cs'
      where
        cId = connId rq
        f = \case
          Just ks -> case L.nonEmpty $ L.filter (qKey rq /=) ks of
            Just ks' -> (removed, Just ks')
            Nothing -> (cId : removed, Nothing)
          Nothing -> (removed, Nothing) -- "impossible" in invariant holds, because we get keys from the known queues

isSession :: RcvQueue -> (UserId, SMPServer, Maybe ConnId) -> Bool
isSession rq (uId, srv, connId_) =
  userId rq == uId && server rq == srv && maybe True (connId rq ==) connId_

instance Queue RcvQueue where
  connId' = connId
  qKey rq = (userId rq, server rq, connId rq)

instance Queue (SessionId, RcvQueue) where
  connId' = connId . snd
  qKey = qKey . snd
