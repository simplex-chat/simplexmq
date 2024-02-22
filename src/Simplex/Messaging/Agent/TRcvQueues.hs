module Simplex.Messaging.Agent.TRcvQueues
  ( RcvQueues,
    RcvQueueKey,
    TRcvQueues (getRcvQueues),
    empty,
    clear,
    deleteConn,
    hasConn,
    getConns,
    addQueue,
    deleteQueue,
    getSessQueues,
    getDelSessQueues,
    qKey,
  )
where

import Control.Concurrent.STM
import Control.DeepSeq (NFData (..))
import qualified Data.HashMap.Strict as HM
import Data.Set (Set)
import qualified Data.Set as S
import Simplex.Messaging.Agent.Protocol (ConnId, UserId)
import Simplex.Messaging.Agent.Store (RcvQueue, StoredRcvQueue (..))
import Simplex.Messaging.Protocol (RecipientId, SMPServer)

type RcvQueueKey = (UserId, SMPServer, RecipientId)
type RcvQueues = HM.HashMap RcvQueueKey RcvQueue

newtype TRcvQueues = TRcvQueues {getRcvQueues :: TVar RcvQueues}

instance NFData TRcvQueues where rnf trqs = trqs `seq` ()

empty :: STM TRcvQueues
empty = TRcvQueues <$> newTVar mempty

clear :: TRcvQueues -> STM ()
clear (TRcvQueues qs) = writeTVar qs mempty

deleteConn :: ConnId -> TRcvQueues -> STM ()
deleteConn cId (TRcvQueues qs) = modifyTVar' qs $ HM.filter (\rq -> cId /= connId rq)

hasConn :: ConnId -> TRcvQueues -> STM Bool
hasConn cId (TRcvQueues qs) = any (\rq -> cId == connId rq) <$> readTVar qs

getConns :: TRcvQueues -> STM (Set ConnId)
getConns (TRcvQueues qs) = HM.foldr' (S.insert . connId) S.empty <$> readTVar qs

addQueue :: RcvQueue -> TRcvQueues -> STM ()
addQueue rq (TRcvQueues qs) = modifyTVar' qs $ HM.insert (qKey rq) rq

deleteQueue :: RcvQueue -> TRcvQueues -> STM ()
deleteQueue rq (TRcvQueues qs) = modifyTVar' qs $ HM.delete (qKey rq)

getSessQueues :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues -> STM [RcvQueue]
getSessQueues tSess (TRcvQueues qs) = HM.foldl' addQ [] <$> readTVar qs
  where
    addQ qs' rq = if rq `isSession` tSess then rq : qs' else qs'

getDelSessQueues :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues -> STM [RcvQueue]
getDelSessQueues tSess (TRcvQueues qs) = stateTVar qs $ HM.foldl' addQ ([], HM.empty)
  where
    addQ (removed, qs') rq
      | rq `isSession` tSess = (rq : removed, qs')
      | otherwise = (removed, HM.insert (qKey rq) rq qs')

isSession :: RcvQueue -> (UserId, SMPServer, Maybe ConnId) -> Bool
isSession rq (uId, srv, connId_) =
  userId rq == uId && server rq == srv && maybe True (connId rq ==) connId_

qKey :: RcvQueue -> RcvQueueKey
qKey rq = (userId rq, server rq, connId rq)
