{-# LANGUAGE CPP #-}
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

module Simplex.Messaging.Server.QueueStore.Postgres
  ( PostgresQueueStore (..),
    batchInsertQueues,
    foldQueueRecs,
  )
where

import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Data.Bitraversable (bimapM)
import Data.Functor (($>))
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes, mapMaybe)
import qualified Data.Text as T
import Database.PostgreSQL.Simple (Binary (..), Only (..), Query, SqlError, (:.) (..))
import qualified Database.PostgreSQL.Simple as PSQL
import Database.PostgreSQL.Simple.Errors (ConstraintViolation (..), constraintViolation)
import Database.PostgreSQL.Simple.SqlQQ (sql)
import Simplex.Messaging.Agent.Client (withLockMap)
import Simplex.Messaging.Agent.Lock (Lock)
import Simplex.Messaging.Agent.Store.Postgres (createDBStore)
import Simplex.Messaging.Agent.Store.Postgres.Common
import Simplex.Messaging.Agent.Store.Postgres.DB (FromField (..), ToField (..))
import qualified Simplex.Messaging.Agent.Store.Postgres.DB as DB
import Simplex.Messaging.Agent.Store.Shared (MigrationConfirmation)
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.Postgres.Migrations (serverMigrations)
import Simplex.Messaging.Server.QueueStore.STM (readQueueRecIO)
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (firstRow, ifM, tshow, (<$$>))
import System.Exit (exitFailure)
import System.IO (hFlush, stdout)
import UnliftIO.STM
#if !defined(dbPostgres)
import Simplex.Messaging.Agent.Store.Postgres.DB (blobFieldDecoder)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
#endif

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

  -- this implementation assumes that the lock is already taken by addQueue
  -- and relies on unique constraints in the database to prevent duplicate IDs.
  addQueue_ :: PostgresQueueStore q -> (RecipientId -> QueueRec -> IO q) -> RecipientId -> QueueRec -> IO (Either ErrorType q)
  addQueue_ st mkQ rId qr = do
    sq <- mkQ rId qr
    withQueueLock sq "addQueue_" $ runExceptT $ do
      withDB "addQueue_" st $ \db ->
        E.try (insertQueueDB db rId qr) >>= bimapM handleDuplicate pure
      atomically $ TM.insert rId sq queues
      atomically $ TM.insert (senderId qr) rId senders
      pure sq
    where
      PostgresQueueStore {queues, senders} = st
      -- Not doing duplicate checks in maps as the probability of duplicates is very low.
      -- It needs to be reconsidered when IDs are supplied by the users.
      -- hasId = anyM [TM.memberIO rId queues, TM.memberIO senderId senders, hasNotifier]
      -- hasNotifier = maybe (pure False) (\NtfCreds {notifierId} -> TM.memberIO notifierId notifiers) notifier

  getQueue_ :: DirectParty p => PostgresQueueStore q -> (RecipientId -> QueueRec -> IO q) -> SParty p -> QueueId -> IO (Either ErrorType q)
  getQueue_ st mkQ party qId = case party of
    SRecipient -> getRcvQueue qId
    SSender -> TM.lookupIO qId senders >>= maybe loadSndQueue getRcvQueue
    SNotifier -> TM.lookupIO qId notifiers >>= maybe loadNtfQueue getRcvQueue
    where
      PostgresQueueStore {queues, senders, notifiers} = st
      getRcvQueue rId = TM.lookupIO rId queues >>= maybe loadRcvQueue (pure . Right)
      loadRcvQueue = loadQueue " WHERE q.recipient_id = ?" $ \_ -> pure ()
      loadSndQueue = loadQueue " WHERE q.sender_id = ?" $ \rId -> TM.insert qId rId senders
      loadNtfQueue = loadQueue " WHERE n.notifier_id = ?" $ \_ -> pure () -- do NOT cache ref - ntf subscriptions are rare
      loadQueue condition insertRef = runExceptT $ do
        (rId, qRec) <- loadQueueRec
        sq <- liftIO $ mkQ rId qRec
        atomically $
          -- checking the cache again for concurrent reads,
          -- use previously loaded queue if exists.
          TM.lookup rId queues >>= \case
            Just sq' -> pure sq'
            Nothing -> do
              insertRef rId
              TM.insert rId sq queues
              pure sq
        where
          loadQueueRec =
            withDB "getQueue_" st $ \db -> firstRow rowToQueueRec AUTH $
              DB.query db (queueRecQuery <> condition) (Only qId)

  secureQueue :: PostgresQueueStore q -> q -> SndPublicAuthKey -> IO (Either ErrorType ())
  secureQueue st sq sKey =
    withQueueDB sq "secureQueue" $ \q -> do
      verify q
      withDB' "secureQueue" st $ \db ->
        DB.execute db "UPDATE msg_queues SET sender_key = ? WHERE recipient_id = ?" (sKey, recipientId sq)
      atomically $ writeTVar (queueRec sq) $ Just q {senderKey = Just sKey}
    where
      verify q = case senderKey q of
        Just k | sKey /= k -> throwE AUTH
        _ -> pure ()

  addQueueNotifier :: PostgresQueueStore q -> q -> NtfCreds -> IO (Either ErrorType (Maybe NotifierId))
  addQueueNotifier st sq ntfCreds@NtfCreds {notifierId = nId, notifierKey, rcvNtfDhSecret} =
    withQueueDB sq "addQueueNotifier" $ \q ->
      ExceptT $ withLockMap (notifierLocks st) nId "addQueueNotifier" $
        ifM (TM.memberIO nId notifiers) (pure $ Left DUPLICATE_) $ runExceptT $ do
          withDB "addQueueNotifier" st $ \db ->
            E.try (insert db) >>= bimapM handleDuplicate pure
          nId_ <- forM (notifier q) $ \NtfCreds {notifierId} -> atomically (TM.delete notifierId notifiers) $> notifierId
          let !q' = q {notifier = Just ntfCreds}
          atomically $ writeTVar (queueRec sq) $ Just q'
          -- cache queue notifier ID – after notifier is added ntf server will likely subscribe
          atomically $ TM.insert nId rId notifiers
          pure nId_
    where
      PostgresQueueStore {notifiers} = st
      rId = recipientId sq
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
    withQueueDB sq "deleteQueueNotifier" $ \q ->
      ExceptT $ fmap sequence $ forM (notifier q) $ \NtfCreds {notifierId = nId} ->
        withLockMap (notifierLocks st) nId "deleteQueueNotifier" $ runExceptT $ do
          withDB' "deleteQueueNotifier" st $ \db ->
            DB.execute db "DELETE FROM msg_notifiers WHERE notifier_id = ?" (Only nId)
          atomically $ TM.delete nId $ notifiers st
          atomically $ writeTVar (queueRec sq) $ Just q {notifier = Nothing}
          pure nId

  suspendQueue :: PostgresQueueStore q -> q -> IO (Either ErrorType ())
  suspendQueue st sq = setStatusDB "suspendQueue" st sq EntityOff

  blockQueue :: PostgresQueueStore q -> q -> BlockingInfo -> IO (Either ErrorType ())
  blockQueue st sq info = setStatusDB "blockQueue" st sq (EntityBlocked info)

  unblockQueue :: PostgresQueueStore q -> q -> IO (Either ErrorType ())
  unblockQueue st sq = setStatusDB "unblockQueue" st sq EntityActive
  
  updateQueueTime :: PostgresQueueStore q -> q -> RoundedSystemTime -> IO (Either ErrorType QueueRec)
  updateQueueTime st sq t =
    withQueueDB sq "updateQueueTime" $ \q@QueueRec {updatedAt} ->
      if updatedAt == Just t
        then pure q
        else do
          withDB' "updateQueueTime" st $ \db ->
            DB.execute db "UPDATE msg_queues SET updated_at = ? WHERE recipient_id = ?" (t, recipientId sq)
          let !q' = q {updatedAt = Just t}
          atomically $ writeTVar (queueRec sq) $ Just q'
          pure q'

  -- this method is called from JournalMsgStore deleteQueue that already locks the queue
  deleteStoreQueue :: PostgresQueueStore q -> q -> IO (Either ErrorType (QueueRec, Maybe (MsgQueue q)))
  deleteStoreQueue st sq = runExceptT $ do
    q <- ExceptT $ readQueueRecIO qr
    withDB' "deleteStoreQueue" st $ \db ->
      DB.execute db "DELETE FROM msg_queues WHERE recipient_id = ?" (Only $ Binary $ unEntityId $ recipientId sq)
    atomically $ writeTVar qr Nothing
    atomically $ TM.delete (senderId q) $ senders st
    forM_ (notifier q) $ \NtfCreds {notifierId} -> atomically $ TM.delete notifierId $ notifiers st
    (q,) <$> atomically (swapTVar (msgQueue sq) Nothing)
    where
      qr = queueRec sq

insertQueueDB :: DB.Connection -> RecipientId -> QueueRec -> IO ()
insertQueueDB db rId QueueRec {recipientKey, rcvDhSecret, senderId, senderKey, sndSecure, notifier, status, updatedAt} = do
  DB.execute db insertQueueQuery (rId, recipientKey, rcvDhSecret, senderId, senderKey, sndSecure, status, updatedAt)
  forM_ notifier $ \NtfCreds {notifierId, notifierKey, rcvNtfDhSecret} ->
    DB.execute db insertNotifierQuery (rId, notifierId, notifierKey, rcvNtfDhSecret)

batchInsertQueues :: StoreQueueClass q => Bool -> M.Map RecipientId q -> PostgresQueueStore q' -> IO (Int64, Int64)
batchInsertQueues tty queues toStore = do
  qs <- catMaybes <$> mapM (\(rId, q) -> (rId,) <$$> readTVarIO (queueRec q)) (M.assocs queues)
  putStrLn $ "Importing " <> show (length qs) <> " queues..."
  let st = dbStore toStore
  (ns, count) <- foldM (processChunk st) ((0, 0), 0) $ toChunks 1000000 qs
  putStrLn $ progress count
  pure ns
  where
    processChunk st ((qCnt, nCnt), i) qs = do
      qCnt' <- withConnection st $ \db -> PSQL.executeMany db insertQueueQuery $ map toQueueRow qs
      nCnt' <- withConnection st $ \db -> PSQL.executeMany db insertNotifierQuery $ mapMaybe toNotifierRow qs
      let i' = i + length qs
      when tty $ putStr (progress i' <> "\r") >> hFlush stdout
      pure ((qCnt + qCnt', nCnt + nCnt'), i')
    progress i = "Imported: " <> show i <> " queues"
    toQueueRow (rId, QueueRec {recipientKey, rcvDhSecret, senderId, senderKey, sndSecure, status, updatedAt}) =
      (rId, recipientKey, rcvDhSecret, senderId, senderKey, sndSecure, status, updatedAt)
    toNotifierRow (rId, QueueRec {notifier}) =
      (\NtfCreds {notifierId, notifierKey, rcvNtfDhSecret} -> (rId, notifierId, notifierKey, rcvNtfDhSecret)) <$> notifier
    toChunks :: Int -> [a] -> [[a]]
    toChunks _ [] = []
    toChunks n xs =
      let (ys, xs') = splitAt n xs
       in ys : toChunks n xs'

insertQueueQuery :: Query
insertQueueQuery =
  [sql|
    INSERT INTO msg_queues
      (recipient_id, recipient_key, rcv_dh_secret, sender_id, sender_key, snd_secure, status, updated_at)
    VALUES (?,?,?,?,?,?,?,?)
  |]

insertNotifierQuery :: Query
insertNotifierQuery =
  [sql|
    INSERT INTO msg_notifiers (recipient_id, notifier_id, notifier_key, rcv_ntf_dh_secret)
    VALUES (?, ?, ?, ?)
  |]

foldQueueRecs :: Monoid a => Bool -> PostgresQueueStore q -> (RecipientId -> QueueRec -> IO a) -> IO a
foldQueueRecs tty st f = do
  fmap snd $ withConnection (dbStore st) $ \db ->
    PSQL.fold_ db queueRecQuery (0 :: Int, mempty) $ \(!i, !acc) row -> do
      r <- uncurry f (rowToQueueRec row)
      let i' = i + 1
      when (tty && i' `mod` 100000 == 0) $ putStr ("Processed: " <> show i <> " records\r") >> hFlush stdout
      pure (i', acc <> r)

queueRecQuery :: Query
queueRecQuery =
  [sql|
    SELECT q.recipient_id, q.recipient_key, q.rcv_dh_secret, q.sender_id, q.sender_key, q.snd_secure, q.status, q.updated_at,
      n.notifier_id, n.notifier_key, n.rcv_ntf_dh_secret
    FROM msg_queues q
    LEFT JOIN msg_notifiers n ON q.recipient_id = n.recipient_id
  |]

rowToQueueRec :: ( (RecipientId, RcvPublicAuthKey, RcvDhSecret, SenderId, Maybe SndPublicAuthKey, SenderCanSecure, ServerEntityStatus, Maybe RoundedSystemTime)
                :. (Maybe NotifierId, Maybe NtfPublicAuthKey, Maybe RcvNtfDhSecret)
              ) -> (RecipientId, QueueRec)
rowToQueueRec ((rId, recipientKey, rcvDhSecret, senderId, senderKey, sndSecure, status, updatedAt) :. (notifierId_, notifierKey_, rcvNtfDhSecret_)) =
  let notifier = NtfCreds <$> notifierId_ <*> notifierKey_ <*> rcvNtfDhSecret_
  in (rId, QueueRec {recipientKey, rcvDhSecret, senderId, senderKey, sndSecure, notifier, status, updatedAt})

setStatusDB :: StoreQueueClass q => String -> PostgresQueueStore q -> q -> ServerEntityStatus -> IO (Either ErrorType ())
setStatusDB op st sq status =
  withQueueDB sq op $ \q -> do
    withDB' op st $ \db ->
      DB.execute db "UPDATE msg_queues SET status = ? WHERE recipient_id = ?" (status, recipientId sq)
    atomically $ writeTVar (queueRec sq) $ Just q {status}

withQueueDB :: StoreQueueClass q => q -> String -> (QueueRec -> ExceptT ErrorType IO a) -> IO (Either ErrorType a)
withQueueDB sq op action =
  withQueueLock sq op $ runExceptT $ do
    q <- ExceptT $ readQueueRecIO $ queueRec sq
    action q

withDB' :: String -> PostgresQueueStore q -> (DB.Connection -> IO a) -> ExceptT ErrorType IO a
withDB' op st' action = withDB op st' $ fmap Right . action

-- TODO [postgres] possibly, use with connection if queries in addQueue_ are combined
withDB :: forall a q. String -> PostgresQueueStore q -> (DB.Connection -> IO (Either ErrorType a)) -> ExceptT ErrorType IO a
withDB op st' action =
  ExceptT $ E.try (withTransaction (dbStore st') action) >>= either logErr pure
  where
    logErr :: E.SomeException -> IO (Either ErrorType a)
    logErr e = logError ("STORE: " <> T.pack err) $> Left (STORE err)
      where
        err = op <> ", withLog, " <> show e

handleDuplicate :: SqlError -> IO ErrorType
handleDuplicate e = case constraintViolation e of
  Just (UniqueViolation _) -> pure AUTH
  _ -> E.throwIO e

-- The orphan instances below are copy-pasted, but here they are defined specifically for PostgreSQL

instance ToField EntityId where toField (EntityId s) = toField $ Binary s

deriving newtype instance FromField EntityId

#if !defined(dbPostgres)
instance ToField (C.DhSecret 'C.X25519) where toField = toField . Binary . C.dhBytes'

instance FromField (C.DhSecret 'C.X25519) where fromField = blobFieldDecoder strDecode

instance ToField C.APublicAuthKey where toField = toField . Binary . C.encodePubKey

instance FromField C.APublicAuthKey where fromField = blobFieldDecoder C.decodePubKey
#endif
