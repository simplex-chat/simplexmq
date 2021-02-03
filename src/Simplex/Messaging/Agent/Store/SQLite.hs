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
    queues <-
      liftIO $
        retrieveConnQueues dbConn connAlias
    case queues of
      (Just rcvQ, Just sndQ) -> return $ SomeConn SCDuplex (DuplexConnection connAlias rcvQ sndQ)
      (Just rcvQ, Nothing) -> return $ SomeConn SCReceive (ReceiveConnection connAlias rcvQ)
      (Nothing, Just sndQ) -> return $ SomeConn SCSend (SendConnection connAlias sndQ)
      _ -> throwError SEBadConn

  getRcvQueue :: SQLiteStore -> SMPServer -> SMP.RecipientId -> m ReceiveQueue
  getRcvQueue SQLiteStore {dbConn} SMPServer {host, port} rcvId = do
    rcvQueue <-
      liftIO $
        retrieveRcvQueue dbConn host port rcvId
    case rcvQueue of
      Just rcvQ -> return rcvQ
      _ -> throwError SENotFound

  deleteConn :: SQLiteStore -> ConnAlias -> m ()
  deleteConn SQLiteStore {dbConn} connAlias =
    liftIO $
      deleteConnCascade dbConn connAlias

  upgradeConnWithSndQueue :: SQLiteStore -> ConnAlias -> SendQueue -> m ()
  upgradeConnWithSndQueue SQLiteStore {dbConn} connAlias sndQueue =
    liftIO (updateRcvConnWithSndQueue dbConn connAlias sndQueue) >>= \case
      Right () -> return ()
      Left e -> throwError e

  upgradeConnWithRcvQueue :: SQLiteStore -> ConnAlias -> ReceiveQueue -> m ()
  upgradeConnWithRcvQueue SQLiteStore {dbConn} connAlias rcvQueue =
    liftIO (updateSndConnWithRcvQueue dbConn connAlias rcvQueue) >>= \case
      Right () -> return ()
      Left e -> throwError e

  removeSndAuth :: SQLiteStore -> ConnAlias -> m ()
  removeSndAuth _st _connAlias = throwError SENotImplemented

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

  getLastMsg :: SQLiteStore -> ConnAlias -> QueueDirection -> m MessageDelivery
  getLastMsg _st _connAlias _dir = throwError SENotImplemented

  getMsg :: SQLiteStore -> ConnAlias -> QueueDirection -> AgentMsgId -> m MessageDelivery
  getMsg _st _connAlias _dir _msgId = throwError SENotImplemented

  -- TODO missing status parameter?
  updateMsgStatus :: SQLiteStore -> ConnAlias -> QueueDirection -> AgentMsgId -> m ()
  updateMsgStatus _st _connAlias _dir _msgId = throwError SENotImplemented

  deleteMsg :: SQLiteStore -> ConnAlias -> QueueDirection -> AgentMsgId -> m ()
  deleteMsg _st _connAlias _dir _msgId = throwError SENotImplemented
