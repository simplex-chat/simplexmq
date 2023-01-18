{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Agent.TRcvQueues where

import Control.Concurrent.STM
import qualified Data.Map.Strict as M
import Data.Set (Set)
import qualified Data.Set as S
import Simplex.Messaging.Agent.Protocol (ConnId)
import Simplex.Messaging.Agent.Store (RcvQueue (..))
import Simplex.Messaging.Protocol (RecipientId, SMPServer)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM

newtype TRcvQueues = TRcvQueues (TMap (SMPServer, RecipientId) RcvQueue)

empty :: STM TRcvQueues
empty = TRcvQueues <$> TM.empty

clear :: TRcvQueues -> STM ()
clear (TRcvQueues qs) = TM.clear qs

deleteConn :: ConnId -> TRcvQueues -> STM ()
deleteConn cId (TRcvQueues qs) = modifyTVar' qs $ M.filter (\rq -> cId /= connId rq)

hasConn :: ConnId -> TRcvQueues -> STM Bool
hasConn cId (TRcvQueues qs) = any (\rq -> cId == connId rq) <$> readTVar qs

getConns :: TRcvQueues -> STM (Set ConnId)
getConns (TRcvQueues qs) = M.foldr' (S.insert . connId) S.empty <$> readTVar qs

addQueue :: RcvQueue -> TRcvQueues -> STM ()
addQueue rq@RcvQueue {server, rcvId} (TRcvQueues qs) = TM.insert (server, rcvId) rq qs

deleteQueue :: RcvQueue -> TRcvQueues -> STM ()
deleteQueue RcvQueue {server, rcvId} (TRcvQueues qs) = TM.delete (server, rcvId) qs

getSrvQueues :: SMPServer -> TRcvQueues -> STM [RcvQueue]
getSrvQueues srv (TRcvQueues qs) = M.foldl' addQ [] <$> readTVar qs
  where
    addQ qs' rq@RcvQueue {server} = if srv == server then rq : qs' else qs'

getDelSrvQueues :: SMPServer -> TRcvQueues -> STM [RcvQueue]
getDelSrvQueues srv (TRcvQueues qs) = stateTVar qs $ M.foldl' addQ ([], M.empty)
  where
    addQ (removed, qs') rq@RcvQueue {server, rcvId}
      | srv == server = (rq : removed, qs')
      | otherwise = (removed, M.insert (server, rcvId) rq qs')
