{-# LANGUAGE MultiParamTypeClasses #-}

module Simplex.Messaging.Agent.Store (MonadAgentStore (..)) where

import Simplex.Messaging.Agent.Types.ConnTypes
import Simplex.Messaging.Agent.Types.TransmissionTypes
import qualified Simplex.Messaging.Protocol as SMP

class Monad m => MonadAgentStore s m where
  createRcvConn :: s -> ReceiveQueue -> m ()
  createSndConn :: s -> SendQueue -> m ()
  getConn :: s -> ConnAlias -> m SomeConn
  getRcvQueue :: s -> SMPServer -> SMP.RecipientId -> m ReceiveQueue
  deleteConn :: s -> ConnAlias -> m ()
  upgradeRcvConnToDuplex :: s -> ConnAlias -> SendQueue -> m ()
  upgradeSndConnToDuplex :: s -> ConnAlias -> ReceiveQueue -> m ()
  removeSndAuth :: s -> ConnAlias -> m ()
  setRcvQueueStatus :: s -> ReceiveQueue -> QueueStatus -> m ()
  setSndQueueStatus :: s -> SendQueue -> QueueStatus -> m ()

-- ? make data kind out of AMessage so that we can limit parameter to AMessage A_MSG?
-- ? or just throw error / silently ignore other AMessage types?
-- createRcvMsg :: s -> ConnAlias -> AMessage -> m ()
-- createSndMsg :: s -> ConnAlias -> AMessage -> m ()

-- TODO this will be removed
-- createMsg :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> AMessage -> m ()

-- getLastMsg :: s -> ConnAlias -> QueueDirection -> m MessageDelivery
-- getMsg :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> m MessageDelivery
-- setMsgStatus :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> m ()
-- deleteMsg :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> m ()
