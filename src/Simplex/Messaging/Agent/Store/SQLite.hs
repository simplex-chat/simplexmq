{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Agent.Store.SQLite where

import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Data.Maybe
import qualified Database.SQLite.Simple as DB
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite.Schema
import Simplex.Messaging.Agent.Store.SQLite.Util
import Simplex.Messaging.Agent.Store.Types
import Simplex.Messaging.Agent.Transmission
import qualified Simplex.Messaging.Protocol as SMP
import UnliftIO.STM

data SQLiteStore = SQLiteStore
  { dbFilename :: String,
    dbConn :: DB.Connection
  }

newSQLiteStore :: MonadUnliftIO m => String -> m SQLiteStore
newSQLiteStore dbFilename = do
  dbConn <- liftIO $ DB.open dbFilename
  liftIO $ createSchema dbConn
  return
    SQLiteStore
      { dbFilename,
        dbConn
      }

instance (MonadUnliftIO m, MonadError StoreError m) => MonadAgentStore SQLiteStore m where
  createRcvConn :: SQLiteStore -> ReceiveQueue -> m ()
  createRcvConn SQLiteStore {dbConn} rcvQueue =
    liftIO $
      createRcvQueueAndConn dbConn rcvQueue

  createSndConn :: SQLiteStore -> SendQueue -> m ()
  createSndConn SQLiteStore {dbConn} sndQueue =
    liftIO $
      createSndQueueAndConn dbConn sndQueue

  getConn :: SQLiteStore -> ConnAlias -> m SomeConn
  getConn SQLiteStore {dbConn} connAlias = do
    queues <- liftIO (retrieveConnQueues dbConn connAlias)
    case queues of
      (Just rq, Just sq) -> return $ SomeConn SCDuplex (DuplexConnection connAlias rq sq)
      (Just rq, _) -> return $ SomeConn SCReceive (ReceiveConnection connAlias rq)
      (_, Just sq) -> return $ SomeConn SCSend (SendConnection connAlias sq)
      _ -> throwError SEBadConn

-- getReceiveQueue :: SQLiteStore -> SMPServer -> SMP.RecipientId -> m (ConnAlias, ReceiveQueue)
-- getReceiveQueue st SMPServer {host, port} recipientId = do
--   rcvQueue <- getRcvQueueByRecipientId st recipientId host port
--   connAlias <- getConnAliasByRcvQueue st recipientId
--   return (connAlias, rcvQueue)

-- -- TODO make transactional
-- addSndQueue :: SQLiteStore -> ConnAlias -> SendQueue -> m ()
-- addSndQueue st connAlias sndQueue =
--   getConn st connAlias
--     >>= \case
--       SomeConn SCDuplex _ -> throwError (SEBadConnType CDuplex)
--       SomeConn SCSend _ -> throwError (SEBadConnType CSend)
--       SomeConn SCReceive _ -> do
--         srvId <- upsertServer st (server (sndQueue :: SendQueue))
--         sndQ <- insertSndQueue st srvId sndQueue
--         updateRcvConnectionWithSndQueue st connAlias sndQ

-- -- TODO make transactional
-- addRcvQueue :: SQLiteStore -> ConnAlias -> ReceiveQueue -> m ()
-- addRcvQueue st connAlias rcvQueue =
--   getConn st connAlias
--     >>= \case
--       SomeConn SCDuplex _ -> throwError (SEBadConnType CDuplex)
--       SomeConn SCReceive _ -> throwError (SEBadConnType CReceive)
--       SomeConn SCSend _ -> do
--         srvId <- upsertServer st (server (rcvQueue :: ReceiveQueue))
--         rcvQ <- insertRcvQueue st srvId rcvQueue
--         updateSndConnectionWithRcvQueue st connAlias rcvQ

-- -- TODO think about design of one-to-one relationships between connections ans send/receive queues
-- -- - Make wide `connections` table? -> Leads to inability to constrain queue fields on SQL level
-- -- - Make bi-directional foreign keys deferred on queue side?
-- --   * Involves populating foreign keys on queues' tables and reworking store
-- --   * Enables cascade deletes
-- --   ? See https://sqlite.org/foreignkeys.html#fk_deferred
-- -- - Keep as is and just wrap in transaction?
-- deleteConn :: SQLiteStore -> ConnAlias -> m ()
-- deleteConn st connAlias = do
--   (rcvQId, sndQId) <- getConnection st connAlias
--   forM_ rcvQId $ deleteRcvQueue st
--   forM_ sndQId $ deleteSndQueue st
--   deleteConnection st connAlias
--   when (isNothing rcvQId && isNothing sndQId) $ throwError SEBadConn

-- removeSndAuth :: SQLiteStore -> ConnAlias -> m ()
-- removeSndAuth _st _connAlias = throwError SENotImplemented

-- -- TODO throw error if queue doesn't exist
-- updateRcvQueueStatus :: SQLiteStore -> ReceiveQueue -> QueueStatus -> m ()
-- updateRcvQueueStatus st ReceiveQueue {rcvId, server = SMPServer {host, port}} status =
--   updateReceiveQueueStatus st rcvId host port status

-- -- TODO throw error if queue doesn't exist
-- updateSndQueueStatus :: SQLiteStore -> SendQueue -> QueueStatus -> m ()
-- updateSndQueueStatus st SendQueue {sndId, server = SMPServer {host, port}} status =
--   updateSendQueueStatus st sndId host port status

-- -- TODO decrease duplication of queue direction checks?
-- createMsg :: SQLiteStore -> ConnAlias -> QueueDirection -> AgentMsgId -> AMessage -> m ()
-- createMsg st connAlias qDirection agentMsgId msg = do
--   case qDirection of
--     RCV -> do
--       (rcvQId, _) <- getConnection st connAlias
--       case rcvQId of
--         Just _ -> insertMsg st connAlias qDirection agentMsgId $ serializeAgentMessage msg
--         Nothing -> throwError SEBadQueueDirection
--     SND -> do
--       (_, sndQId) <- getConnection st connAlias
--       case sndQId of
--         Just _ -> insertMsg st connAlias qDirection agentMsgId $ serializeAgentMessage msg
--         Nothing -> throwError SEBadQueueDirection

-- getLastMsg :: SQLiteStore -> ConnAlias -> QueueDirection -> m MessageDelivery
-- getLastMsg _st _connAlias _dir = throwError SENotImplemented

-- getMsg :: SQLiteStore -> ConnAlias -> QueueDirection -> AgentMsgId -> m MessageDelivery
-- getMsg _st _connAlias _dir _msgId = throwError SENotImplemented

-- -- TODO missing status parameter?
-- updateMsgStatus :: SQLiteStore -> ConnAlias -> QueueDirection -> AgentMsgId -> m ()
-- updateMsgStatus _st _connAlias _dir _msgId = throwError SENotImplemented

-- deleteMsg :: SQLiteStore -> ConnAlias -> QueueDirection -> AgentMsgId -> m ()
-- deleteMsg _st _connAlias _dir _msgId = throwError SENotImplemented
