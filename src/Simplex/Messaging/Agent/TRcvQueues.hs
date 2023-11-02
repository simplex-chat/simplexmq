module Simplex.Messaging.Agent.TRcvQueues
  ( TRcvQueues (getRcvQueues),
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
import qualified Data.Map.Strict as M
import Data.Set (Set)
import qualified Data.Set as S
import Simplex.Messaging.Agent.Protocol (ConnId, UserId)
import Simplex.Messaging.Agent.Store (RcvQueue (..))
import Simplex.Messaging.Protocol (RecipientId, SMPServer)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM

newtype TRcvQueues = TRcvQueues {getRcvQueues :: TMap (UserId, SMPServer, RecipientId) RcvQueue}

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
addQueue rq (TRcvQueues qs) = TM.insert (qKey rq) rq qs

deleteQueue :: RcvQueue -> TRcvQueues -> STM ()
deleteQueue rq (TRcvQueues qs) = TM.delete (qKey rq) qs

getSessQueues :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues -> STM [RcvQueue]
getSessQueues tSess (TRcvQueues qs) = M.foldl' addQ [] <$> readTVar qs
  where
    addQ qs' rq = if rq `isSession` tSess then rq : qs' else qs'

getDelSessQueues :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues -> STM [RcvQueue]
getDelSessQueues tSess (TRcvQueues qs) = stateTVar qs $ M.foldl' addQ ([], M.empty)
  where
    addQ (removed, qs') rq
      | rq `isSession` tSess = (rq : removed, qs')
      | otherwise = (removed, M.insert (qKey rq) rq qs')

isSession :: RcvQueue -> (UserId, SMPServer, Maybe ConnId) -> Bool
isSession rq (uId, srv, connId_) =
  userId rq == uId && server rq == srv && maybe True (connId rq ==) connId_

qKey :: RcvQueue -> (UserId, SMPServer, ConnId)
qKey rq = (userId rq, server rq, connId rq)
