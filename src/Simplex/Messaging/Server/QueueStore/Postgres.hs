{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Server.QueueStore.Postgres where

import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import Data.Bitraversable (bimapM)
import Data.Functor (($>))
import qualified Data.Text as T
import Database.PostgreSQL.Simple (Binary (..), Only (..), SqlError, (:.) (..))
import Database.PostgreSQL.Simple.Errors (constraintViolation)
import Database.PostgreSQL.Simple.SqlQQ (sql)
import Simplex.Messaging.Agent.Client (withLockMap)
import Simplex.Messaging.Agent.Lock (Lock)
import Simplex.Messaging.Agent.Store.Postgres (createDBStore)
import Simplex.Messaging.Agent.Store.Postgres.Common
import Simplex.Messaging.Agent.Store.Postgres.DB (FromField (..), ToField (..), blobFieldDecoder)
import qualified Simplex.Messaging.Agent.Store.Postgres.DB as DB
import Simplex.Messaging.Agent.Store.Shared (MigrationConfirmation)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.Postgres.Migrations (serverMigrations)
import Simplex.Messaging.Server.QueueStore.STM (readQueueRecIO, setStatus, withQueueRec)
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (anyM, firstRow, ifM, tshow, ($>>), ($>>=), (<$$))
import System.Exit (exitFailure)

data PostgresQueueStore q = PostgresQueueStore
  { dbStore :: DBStore,
    -- this map caches all created and opened queues
    queues :: TMap RecipientId q,
    -- this map only cashes the queues that were attempted to send messages to,
    senders :: TMap SenderId RecipientId,
    -- this map only cashes the queues that were attempted to be subscribed to,
    notifiers :: TMap NotifierId RecipientId,
    notifierLocks :: TMap NotifierId Lock
  }

instance StoreQueueClass q => QueueStoreClass q (PostgresQueueStore q) where
  type QueueStoreCfg (PostgresQueueStore q) = (DBOpts, MigrationConfirmation)

  newQueueStore :: (DBOpts, MigrationConfirmation)  -> IO (PostgresQueueStore q)
  newQueueStore (dbOpts, confirmMigrations) = do
    dbStore <- either err pure =<< createDBStore dbOpts serverMigrations confirmMigrations
    queues <- TM.emptyIO
    senders <- TM.emptyIO
    notifiers <- TM.emptyIO
    notifierLocks <- TM.emptyIO
    pure PostgresQueueStore {dbStore, queues, senders, notifiers, notifierLocks}
    where
      err e = do
        logError $ "STORE: newQueueStore, error opening PostgreSQL database, " <> tshow e
        exitFailure

  loadedQueues = queues
  {-# INLINE loadedQueues #-}

  queueCounts :: PostgresQueueStore q -> IO QueueCounts
  queueCounts st =
    withConnection (dbStore st) $ \db -> do
      (queueCount, notifierCount) : _ <-
        DB.query_
          db
          [sql|
            SELECT
              (SELECT COUNT(1) FROM msg_queues) AS queue_count, 
              (SELECT COUNT(1) FROM msg_notifiers) AS notifier_count
          |]
      pure QueueCounts {queueCount, notifierCount}

  -- this implementation assumes that the lock is already taken
  -- and relies on unique constraints in the database to prevent duplicate IDs.
  addQueueRec :: PostgresQueueStore q -> RecipientId -> QueueLock q -> QueueRec -> IO (Either ErrorType q)
  addQueueRec st rId lock qr =
    addDB $>> (mkQueue rId lock qr >>= add)
    where
      PostgresQueueStore {queues, senders, notifiers} = st
      addDB =
        withDB "addQueueRec" st $ \db ->
          E.try (insert db) >>= bimapM handleDuplicate pure
      add q = do
        atomically $ TM.insert rId q queues
        atomically $ TM.insert senderId rId senders
        pure $ Right q
      -- Not doing duplicate checks in maps as the probability of duplicates is very low.
      -- It needs to be reconsidered when IDs are supplied by the users.
      -- hasId = anyM [TM.memberIO rId queues, TM.memberIO senderId senders, hasNotifier]
      -- hasNotifier = maybe (pure False) (\NtfCreds {notifierId} -> TM.memberIO notifierId notifiers) notifier
      insert db =
        DB.execute
          db
          [sql|
            WITH inserted AS (
              INSERT INTO msg_queues
                (recipient_id, recipient_key, rcv_dh_secret, sender_id, sender_key, snd_secure, status, updated_at)
              VALUES (?,?,?,?,?,?,?,?)
              RETURNING recipient_id
            )
            INSERT INTO msg_notifiers (recipient_id, notifier_id, notifier_key, rcv_ntf_dh_secret)
            SELECT inserted.recipient_id, ?, ?, ?
            FROM inserted
            WHERE ? IS NOT NULL;
          |]
          ((rId, recipientKey, rcvDhSecret, senderId, senderKey, sndSecure, status, updatedAt)
            :. (notifierId_, notifierKey_, rcvNtfDhSecret_, notifierId_))
      QueueRec {recipientKey, rcvDhSecret, senderId, senderKey, sndSecure, notifier, status, updatedAt} = qr
      (notifierId_, notifierKey_, rcvNtfDhSecret_) = case notifier of
        Just NtfCreds {notifierId, notifierKey, rcvNtfDhSecret} -> (Just notifierId, Just notifierKey, Just rcvNtfDhSecret)
        Nothing -> (Nothing, Nothing, Nothing)

  getQueue :: DirectParty p => PostgresQueueStore q -> SParty p -> QueueId -> IO (Either ErrorType q)
  getQueue st party qId = undefined -- do
  --   case party of
  --     SRecipient -> getQueue_ qId
  --     SSender -> TM.lookupIO qId senders >>= maybe loadSndQueue getQueue_
  --     SNotifier -> loadRefQueue $ \_ -> pure ()
  --   where
  --     -- TODO isolate
  --     PostgresQueueStore {queues, senders, notifiers} = st
  --     getQueue_ rId = TM.lookupIO rId queues >>= maybe loadQueue (pure . Right)
  --     loadQueue =
  --       loadQueueRec $>>= \(rId, qRec) ->  -- isolate by rId
  --         cacheQueue rId qRec
  --     loadSndQueue = loadRefQueue $ \rId -> atomically $ TM.insert qId rId senders
  --     loadRefQueue insertRef =
  --       loadQueueRec $>>= \(rId, qRec) -> -- isolate by rId
  --         TM.lookupIO rId queues >>= \case
  --           Just sq -> pure $ Right sq
  --           Nothing -> insertRef rId >> cacheQueue rId qRec
  --     cacheQueue rId qRec = do
  --       sq <- mkQueue rId qRec
  --       atomically $ TM.insert rId sq queues
  --       pure $ Right sq
  --     loadQueueRec =
  --       withDB "loadQueueRec" st $ \db -> firstRow toQueueRec AUTH $
  --         DB.query
  --           db
  --           ( [sql|
  --               SELECT q.recipient_id, q.recipient_key, q.rcv_dh_secret, q.sender_id, q.sender_key, q.snd_secure, q.status, q.updated_at,
  --                 n.notifier_id, n.notifier_key, n.rcv_ntf_dh_secret
  --               FROM msg_queues q
  --               LEFT JOIN msg_notifiers n USING (msg_queue_id)
  --             |]
  --               <> cond
  --           )
  --            (Only qId)
  --     toQueueRec :: ( (RecipientId, RcvPublicAuthKey, RcvDhSecret, SenderId, Maybe SndPublicAuthKey, SenderCanSecure, ServerEntityStatus, Maybe RoundedSystemTime)
  --                      :. (Maybe NotifierId, Maybe NtfPublicAuthKey, Maybe RcvNtfDhSecret)
  --                   ) -> (RecipientId, QueueRec)
  --     toQueueRec ((rId, recipientKey, rcvDhSecret, senderId, senderKey, sndSecure, status, updatedAt) :. (notifierId_, notifierKey_, rcvNtfDhSecret_)) =
  --       let notifier = NtfCreds <$> notifierId_ <*> notifierKey_ <*> rcvNtfDhSecret_
  --        in (rId, QueueRec {recipientKey, rcvDhSecret, senderId, senderKey, sndSecure, notifier, status, updatedAt})
  --     cond = case party of
  --       SRecipient -> " WHERE q.recipient_id = ?"
  --       SSender -> " WHERE q.sender_id = ?"
  --       SNotifier -> " WHERE n.notifier_id = ?"

  secureQueue :: PostgresQueueStore q -> q -> SndPublicAuthKey -> IO (Either ErrorType ())
  secureQueue st sq sKey =
    withQueueLock sq "secureQueue" $
      readQueueRecIO qr
        $>>= \q -> verify q
        $>> secureDB
        $>> secure q
    where
      qr = queueRec sq
      verify q = pure $ case senderKey q of
        Just k | sKey /= k -> Left AUTH
        _ -> Right ()
      secureDB =
        withDB' "secureQueue" st $ \db ->
          DB.execute db "UPDATE msg_queues SET sender_key = ? WHERE recipient_id = ?" (sKey, recipientId sq)
      secure q = do
        atomically $ writeTVar qr $ Just q {senderKey = Just sKey}
        pure $ Right ()

  addQueueNotifier :: PostgresQueueStore q -> q -> NtfCreds -> IO (Either ErrorType (Maybe NotifierId))
  addQueueNotifier st sq ntfCreds@NtfCreds {notifierId = nId, notifierKey, rcvNtfDhSecret} =
    withQueueLock sq "addQueueNotifier" $
      readQueueRecIO qr $>>= add
    where
      PostgresQueueStore {notifiers} = st
      rId = recipientId sq
      qr = queueRec sq
      add q =
        withLockMap (notifierLocks st) nId "addQueueNotifier" $
          ifM (TM.memberIO nId notifiers) (pure $ Left DUPLICATE_) $
            addDB $>> do
              nId_ <- forM (notifier q) $ \NtfCreds {notifierId} -> atomically (TM.delete notifierId notifiers) $> notifierId
              let !q' = q {notifier = Just ntfCreds}
              atomically $ writeTVar qr $ Just q'
              atomically $ TM.insert nId rId notifiers
              pure $ Right nId_
      addDB =
        withDB "addQueueNotifier" st $ \db ->
          E.try (insert db) >>= bimapM handleDuplicate pure
        where
          -- TODO [postgres] test how this query works with duplicate recipient_id (updates) and notifier_id (fails)
          insert db =
            DB.execute
              db
              [sql|
                INSERT INTO msg_notifiers (recipient_id, notifier_id, notifier_key, rcv_ntf_dh_secret)
                VALUES (?, ?, ?, ?)
                ON CONFLICT (recipient_id) DO UPDATE
                SET notifier_id = EXCLUDED.notifier_id,
                    notifier_key = EXCLUDED.notifier_key,
                    rcv_ntf_dh_secret = EXCLUDED.rcv_ntf_dh_secret
              |]
              (rId, nId, notifierKey, rcvNtfDhSecret)

  deleteQueueNotifier :: PostgresQueueStore q -> q -> IO (Either ErrorType (Maybe NotifierId))
  deleteQueueNotifier st sq =
    withQueueLock sq "deleteQueueNotifier" $
      readQueueRecIO qr $>>= fmap sequence . delete
    where
      qr = queueRec sq
      delete :: QueueRec -> IO (Maybe (Either ErrorType NotifierId))
      delete q = forM (notifier q) $ \NtfCreds {notifierId = nId} ->
        withLockMap (notifierLocks st) nId "deleteQueueNotifier" $ do
          deleteDB nId $>> do
            atomically $ TM.delete nId $ notifiers st
            atomically $ writeTVar qr $! Just q {notifier = Nothing}
            pure $ Right nId
      deleteDB nId =
        withDB' "deleteQueueNotifier" st $ \db ->
          DB.execute db "DELETE FROM msg_notifiers WHERE notifier_id = ?" (Only nId)

  -- TODO [postgres] only update STM on DB success
  suspendQueue :: PostgresQueueStore q -> q -> IO (Either ErrorType ())
  suspendQueue st sq =
    setStatus (queueRec sq) EntityOff
      $>> setStatusDB "suspendQueue" st (recipientId sq) EntityOff

  -- TODO [postgres] only update STM on DB success
  blockQueue :: PostgresQueueStore q -> q -> BlockingInfo -> IO (Either ErrorType ())
  blockQueue st sq info =
    setStatus (queueRec sq) (EntityBlocked info)
      $>> setStatusDB "blockQueue" st (recipientId sq) (EntityBlocked info)

  -- TODO [postgres] only update STM on DB success
  unblockQueue :: PostgresQueueStore q -> q -> IO (Either ErrorType ())
  unblockQueue st sq =
    setStatus (queueRec sq) EntityActive
      $>> setStatusDB "unblockQueue" st (recipientId sq) EntityActive

  -- TODO [postgres] only update STM on DB success
  updateQueueTime :: PostgresQueueStore q -> q -> RoundedSystemTime -> IO (Either ErrorType QueueRec)
  updateQueueTime st sq t = withQueueRec qr update $>>= updateDB
    where
      qr = queueRec sq
      update q@QueueRec {updatedAt}
        | updatedAt == Just t = pure (q, False)
        | otherwise =
            let !q' = q {updatedAt = Just t}
             in (writeTVar qr $! Just q') $> (q', True)
      updateDB (q, changed)
        | changed = q <$$ withDB' "updateQueueTime" st (\db -> DB.execute db "UPDATE msg_queues SET updated_at = ? WHERE recipient_id = ?" (t, Binary $ unEntityId $ recipientId sq))
        | otherwise = pure $ Right q

  -- TODO [postgres] only update STM on DB success
  deleteStoreQueue :: PostgresQueueStore q -> q -> IO (Either ErrorType (QueueRec, Maybe (MsgQueue q)))
  deleteStoreQueue st sq =
    withQueueRec qr delete
      $>>= \q -> deleteDB
      >>= mapM (\_ -> (q,) <$> atomically (swapTVar (msgQueue sq) Nothing))
    where
      qr = queueRec sq
      delete q = do
        writeTVar qr Nothing
        TM.delete (senderId q) $ senders st
        -- forM_ (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId $ notifiers st
        pure q
      deleteDB =
        withDB' "deleteStoreQueue" st $ \db ->
          DB.execute db "DELETE FROM msg_queues WHERE recipient_id = ?" (Only $ Binary $ unEntityId $ recipientId sq)

setStatusDB :: String -> PostgresQueueStore q -> RecipientId -> ServerEntityStatus -> IO (Either ErrorType ())
setStatusDB name st rId status =
  withDB' name st $ \db ->
    DB.execute db "UPDATE msg_queues SET status = ? WHERE recipient_id = ?" (status, rId)

withDB' :: String -> PostgresQueueStore q -> (DB.Connection -> IO a) -> IO (Either ErrorType a)
withDB' name st' action = withDB name st' $ fmap Right . action

withDB :: forall a q. String -> PostgresQueueStore q -> (DB.Connection -> IO (Either ErrorType a)) -> IO (Either ErrorType a)
withDB name st' action =
  E.try (withConnection (dbStore st') action) >>= either logErr pure
  where
    logErr :: E.SomeException -> IO (Either ErrorType a)
    logErr e = logError ("STORE: " <> T.pack err) $> Left (STORE err)
      where
        err = name <> ", withLog, " <> show e

handleDuplicate :: SqlError -> IO ErrorType
handleDuplicate e = case constraintViolation e of
  Just _ -> pure AUTH
  Nothing -> E.throwIO e

-- The orphan instances below are copy-pasted, but here they are defined specifically for PostgreSQL

instance ToField EntityId where toField (EntityId s) = toField $ Binary s

deriving newtype instance FromField EntityId

instance ToField (C.DhSecret 'C.X25519) where toField = toField . Binary . C.dhBytes'

instance FromField (C.DhSecret 'C.X25519) where fromField = blobFieldDecoder strDecode

instance ToField C.APublicAuthKey where toField = toField . Binary . C.encodePubKey

instance FromField C.APublicAuthKey where fromField = blobFieldDecoder C.decodePubKey
