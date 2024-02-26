{-# LANGUAGE LambdaCase #-}

module Simplex.Messaging.Agent.TRcvQueues
  ( TRcvQueues (getRcvQueues, getConnections),
    empty,
    clear,
    deleteConn,
    hasConn,
    addQueue,
    batchAddQueues,
    deleteQueue,
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
import Simplex.Messaging.Agent.Protocol (ConnId, UserId)
import Simplex.Messaging.Agent.Store (RcvQueue, StoredRcvQueue (..))
import Simplex.Messaging.Protocol (RecipientId, SMPServer)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM

-- the fields in this record have the same data with swapped keys for lookup efficiency,
-- and all methods must maintain this invariant.
data TRcvQueues = TRcvQueues
  { getRcvQueues :: TMap (UserId, SMPServer, RecipientId) RcvQueue,
    getConnections :: TMap ConnId (NonEmpty (UserId, SMPServer, RecipientId))
  }

empty :: STM TRcvQueues
empty = TRcvQueues <$> TM.empty <*> TM.empty

clear :: TRcvQueues -> STM ()
clear (TRcvQueues qs cs) = TM.clear qs >> TM.clear cs

deleteConn :: ConnId -> TRcvQueues -> STM ()
deleteConn cId (TRcvQueues qs cs) =
  TM.lookupDelete cId cs >>= \case
    Just ks -> modifyTVar' qs $ \qs' -> foldl' (flip M.delete) qs' ks
    Nothing -> pure ()

hasConn :: ConnId -> TRcvQueues -> STM Bool
hasConn cId (TRcvQueues _ cs) = TM.member cId cs

addQueue :: RcvQueue -> TRcvQueues -> STM ()
addQueue rq (TRcvQueues qs cs) = do
  TM.insert k rq qs
  TM.alter addQ (connId rq) cs
  where
    addQ = Just . maybe (k :| []) (k <|)
    k = qKey rq

-- Save time by aggregating modifyTVar
batchAddQueues :: Foldable t => TRcvQueues -> t RcvQueue -> STM ()
batchAddQueues (TRcvQueues qs cs) rqs = do
  modifyTVar' qs $ \now -> foldl' (\rqs' rq -> M.insert (qKey rq) rq rqs') now rqs
  modifyTVar' cs $ \now -> foldl' (\cs' rq -> M.alter (addQ $ qKey rq) (connId rq) cs') now rqs
  where
    addQ k = Just . maybe (k :| []) (k <|)

deleteQueue :: RcvQueue -> TRcvQueues -> STM ()
deleteQueue rq (TRcvQueues qs cs) = do
  TM.delete k qs
  TM.update delQ (connId rq) cs
  where
    delQ = L.nonEmpty . L.filter (/= k)
    k = qKey rq

getSessQueues :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues -> STM [RcvQueue]
getSessQueues tSess (TRcvQueues qs _) = M.foldl' addQ [] <$> readTVar qs
  where
    addQ qs' rq = if rq `isSession` tSess then rq : qs' else qs'

getDelSessQueues :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues -> STM ([RcvQueue], [ConnId])
getDelSessQueues tSess (TRcvQueues qs cs) = do
  (removedQs, qs'') <- (\qs' -> M.foldl' delQ ([], qs') qs') <$> readTVar qs
  writeTVar qs $! qs''
  removedConns <- stateTVar cs $ \cs' -> foldl' delConn ([], cs') removedQs
  pure (removedQs, removedConns)
  where
    delQ acc@(removed, qs') rq
      | rq `isSession` tSess = (rq : removed, M.delete (qKey rq) qs')
      | otherwise = acc
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

qKey :: RcvQueue -> (UserId, SMPServer, ConnId)
qKey rq = (userId rq, server rq, connId rq)
