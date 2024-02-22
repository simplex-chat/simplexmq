module Simplex.Messaging.Agent.TRcvQueues.HAMT
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
import Control.DeepSeq (NFData (..))
import Data.Set (Set)
import qualified Data.Set as S
import Simplex.Messaging.Agent.Protocol (ConnId, UserId)
import Simplex.Messaging.Agent.Store (RcvQueue, StoredRcvQueue (..))
import Simplex.Messaging.Protocol (RecipientId, SMPServer)
import StmContainers.Map (Map)
import qualified StmContainers.Map as M
import qualified DeferredFolds.UnfoldlM as UF
import Control.Monad (when)

newtype TRcvQueues = TRcvQueues {getRcvQueues :: Map (UserId, SMPServer, RecipientId) RcvQueue}

instance NFData TRcvQueues where rnf trqs = trqs `seq` ()

empty :: STM TRcvQueues
empty = TRcvQueues <$> M.new

clear :: TRcvQueues -> STM ()
clear (TRcvQueues qs) = M.reset qs

deleteConn :: ConnId -> TRcvQueues -> STM ()
deleteConn cId (TRcvQueues qs) =
  UF.forM_ (M.unfoldlM qs) $ \(key, rq) ->
    when (cId /= connId rq) $ M.delete key qs

hasConn :: ConnId -> TRcvQueues -> STM Bool
hasConn cId (TRcvQueues qs) =
  not <$> UF.null (UF.filter (\rq -> pure $ cId == connId rq) $ snd <$> M.unfoldlM qs)

getConns :: TRcvQueues -> STM (Set ConnId)
getConns (TRcvQueues qs) =
  UF.foldlM' (\conns rq -> pure $! S.insert (connId rq) conns) S.empty (snd <$> M.unfoldlM qs)

addQueue :: RcvQueue -> TRcvQueues -> STM ()
addQueue rq (TRcvQueues qs) = M.insert rq (qKey rq) qs

deleteQueue :: RcvQueue -> TRcvQueues -> STM ()
deleteQueue rq (TRcvQueues qs) = M.delete (qKey rq) qs

getSessQueues :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues -> STM [RcvQueue]
getSessQueues tSess (TRcvQueues qs) =
  UF.foldlM' (\qs' rq -> pure $ rq : qs') [] (UF.filter p $ snd <$> M.unfoldlM qs)
  where
    p rq = pure $ rq `isSession` tSess

getDelSessQueues :: (UserId, SMPServer, Maybe ConnId) -> TRcvQueues -> STM [RcvQueue]
getDelSessQueues tSess (TRcvQueues qs) =
  UF.foldlM' remove [] (M.unfoldlM qs)
  where
    remove qs' (k, rq) =
      if rq `isSession` tSess
        then (rq : qs') <$ M.delete k qs
        else pure qs'

isSession :: RcvQueue -> (UserId, SMPServer, Maybe ConnId) -> Bool
isSession rq (uId, srv, connId_) =
  userId rq == uId && server rq == srv && maybe True (connId rq ==) connId_

qKey :: RcvQueue -> (UserId, SMPServer, ConnId)
qKey rq = (userId rq, server rq, connId rq)
