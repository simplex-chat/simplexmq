{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Agent.TRcvQueues
  ( TRcvQueues (getServerKeys, getRcvQueues, getConnections),
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
import Control.Monad
import Data.Foldable (foldl')
import Data.List.NonEmpty (NonEmpty (..), (<|))
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Simplex.Messaging.Agent.Protocol (ConnId, QueueStatus, UserId)
import Simplex.Messaging.Agent.Store (RcvQueueSub (..))
import Simplex.Messaging.Protocol (RcvPrivateAuthKey, RecipientId, SMPServer)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport

-- the fields in this record have the same data with swapped keys for lookup efficiency,
-- and all methods must maintain this invariant.
data TRcvQueues q = TRcvQueues
  { serverKey :: TVar ServerId,
    getServerKeys :: TMap (UserId, SMPServer) ServerId,
    getRcvQueues :: TVar (IntMap (TMap RecipientId q)),
    getConnections :: TMap ConnId (NonEmpty (ServerId, RecipientId))
  }

type ServerId = Int

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
empty = do
  serverKey <- newTVarIO 0
  getServerKeys <- TM.emptyIO
  getRcvQueues <- newTVarIO IM.empty
  getConnections <- TM.emptyIO
  pure TRcvQueues {serverKey, getServerKeys, getRcvQueues, getConnections}

clear :: TRcvQueues q -> STM ()
clear (TRcvQueues sk ss qs cs) = do
  writeTVar sk 0
  TM.clear ss
  writeTVar qs IM.empty
  TM.clear cs

deleteConn :: ConnId -> TRcvQueues q -> STM ()
deleteConn cId (TRcvQueues _ _ qs cs) = TM.lookupDelete cId cs >>= mapM_ (mapM_ (`deleteServerQueue_` qs))

deleteServerQueue_ :: (ServerId, RecipientId) -> TVar (IntMap (TMap RecipientId q)) -> STM ()
deleteServerQueue_ (srvId, rId) = readTVar >=> mapM_ (TM.delete rId) . IM.lookup srvId

hasConn :: ConnId -> TRcvQueues q -> STM Bool
hasConn cId (TRcvQueues _ _ _ cs) = TM.member cId cs

addQueue :: RcvQueueSub -> TRcvQueues RcvQueueCreds -> STM ()
addQueue rq = addQueue_ rq (rqCreds rq)
{-# INLINE addQueue #-}

addSessQueue :: (SessionId, RcvQueueSub) -> TRcvQueues (SessionId, RcvQueueCreds) -> STM ()
addSessQueue (sessId, rq) = addQueue_ rq (sessId, rqCreds rq)
{-# INLINE addSessQueue #-}

addQueue_ :: RcvQueueSub -> q -> TRcvQueues q -> STM ()
addQueue_ rq q trq@(TRcvQueues _ _ _ cs) = do
  (srvId, srvQs) <- getServerQueues_ srvKey trq
  TM.insert rId q srvQs
  TM.alter (addQ srvId) (connId rq) cs
  where
    rId = rcvId rq
    srvKey = (userId rq, server rq)
    addQ srvId =
      let k = (srvId, rId)
       in Just . maybe (k :| []) (k <|)

getServerQueues_ :: (UserId, SMPServer) -> TRcvQueues q -> STM (ServerId, TMap RecipientId q)
getServerQueues_ srvKey (TRcvQueues sKey ss qs _) = do
  srvId <- maybe newServer pure =<< TM.lookup srvKey ss
  srvQs <- maybe (newSrvQueues srvId) pure . IM.lookup srvId =<< readTVar qs
  pure (srvId, srvQs)
  where
    newServer = do
      srvId <- stateTVar sKey $ \i -> let !i' = i + 1 in (i', i')
      TM.insert srvKey srvId ss
      pure srvId
    newSrvQueues srvId = do
      srvQs <- newTVar M.empty
      modifyTVar' qs $ IM.insert srvId srvQs
      pure srvQs

-- Save time by aggregating modifyTVar'
batchAddQueues :: (UserId, SMPServer) -> TRcvQueues RcvQueueCreds -> [RcvQueueSub] -> STM ()
batchAddQueues srvKey trq@(TRcvQueues _ _ _ cs) rqs = do
  (srvId, srvQs) <- getServerQueues_ srvKey trq
  modifyTVar' srvQs $ \now -> foldl' (\rqs' rq -> M.insert (rcvId rq) (rqCreds rq) rqs') now rqs
  modifyTVar' cs $ \now -> foldl' (\cs' rq -> M.alter (addQ (srvId, rcvId rq)) (connId rq) cs') now rqs
  where
    addQ k = Just . maybe (k :| []) (k <|)

deleteQueue :: RcvQueueSub -> TRcvQueues RcvQueueCreds -> STM ()
deleteQueue rq (TRcvQueues _ ss qs cs) = TM.lookup srvKey ss >>= mapM_ deleteSrvQueue
  where
    srvKey = (userId rq, server rq)
    deleteSrvQueue srvId = do
      deleteServerQueue_ k qs
      TM.update delQ (connId rq) cs
      where
        delQ = L.nonEmpty . L.filter (/= k)
        k = (srvId, rcvId rq)

hasSessQueues :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues RcvQueueCreds -> STM Bool
hasSessQueues (uId, srv, connId'_) (TRcvQueues _ ss qs _) =
  TM.lookup srvKey ss >>= maybe (pure False) hasSrvQueues
  where
    srvKey = (uId, srv)
    hasSrvQueues srvId = readTVar qs >>= maybe (pure False) (fmap hasQueue . readTVar) . IM.lookup srvId
    hasQueue = case connId'_ of
      Nothing -> not . null
      Just connId' -> any (\rq -> connId_ rq == connId')

getSessQueues :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues RcvQueueCreds -> STM [RcvQueueSub]
getSessQueues (uId, srv, connId'_) (TRcvQueues _ ss qs _) =
  TM.lookup srvKey ss >>= maybe (pure []) getSrvQueues
  where
    srvKey = (uId, srv)
    getSrvQueues srvId = readTVar qs >>= maybe (pure []) (fmap (M.foldrWithKey addQ []) . readTVar) . IM.lookup srvId
    addQ = case connId'_ of
      Nothing -> \rcvId rq -> (toQ rcvId rq :)
      Just connId' -> \rcvId rq@RcvQueueCreds {connId_} -> if connId_ == connId' then (toQ rcvId rq :) else id
    toQ rcvId RcvQueueCreds {connId_, rcvPrivateKey_, status_} =
      RcvQueueSub {userId = uId, connId = connId_, server = srv, rcvId, rcvPrivateKey = rcvPrivateKey_, status = status_}

getDelSessQueues :: (UserId, SMPServer, Maybe ConnId) -> SessionId -> TRcvQueues (SessionId, RcvQueueCreds) -> STM ([RcvQueueSub], [ConnId])
getDelSessQueues (uId, srv, connId'_) sessId' (TRcvQueues _ ss qs cs) = do
  TM.lookup srvKey ss >>= maybe (pure ([], [])) getSrvQueues
  where
    srvKey = (uId, srv)
    getSrvQueues srvId = readTVar qs >>= maybe (pure ([], [])) (getQueues srvId) . IM.lookup srvId
    getQueues srvId srvQs = do
      removedQs <- stateTVar srvQs (\qs' -> M.foldlWithKey' delQ ([], qs') qs')
      removedConns <- stateTVar cs $ \cs' -> foldl' (delConn srvId) ([], cs') removedQs
      pure (removedQs, removedConns)
    delQ acc@(removed, qs') rcvId (sessId, rq)
      | sessConn rq && sessId == sessId' = (toQ rcvId rq : removed, M.delete rcvId qs')
      | otherwise = acc
    sessConn = case connId'_ of
      Nothing -> const True
      Just connId' -> \rq -> connId_ rq == connId'
    toQ rcvId RcvQueueCreds {connId_, rcvPrivateKey_, status_} =
      RcvQueueSub {userId = uId, connId = connId_, server = srv, rcvId, rcvPrivateKey = rcvPrivateKey_, status = status_}
    delConn :: ServerId -> ([ConnId], M.Map ConnId (NonEmpty (ServerId, RecipientId))) -> RcvQueueSub -> ([ConnId], M.Map ConnId (NonEmpty (ServerId, RecipientId)))
    delConn srvId (removed, cs') rq = M.alterF f cId cs'
      where
        cId = connId rq
        k = (srvId, rcvId rq)
        f = \case
          Just ks -> case L.nonEmpty $ L.filter (k /=) ks of
            Just ks' -> (removed, Just ks')
            Nothing -> (cId : removed, Nothing)
          Nothing -> (removed, Nothing) -- "impossible" if invariant holds, because we get keys from the known queues

qKey :: RcvQueueSub -> (UserId, SMPServer, RecipientId)
qKey rq = (userId rq, server rq, rcvId rq)
