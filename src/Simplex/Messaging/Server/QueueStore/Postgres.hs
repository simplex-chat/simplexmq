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
    PostgresStoreCfg (..),
    batchInsertQueues,
    foldQueueRecs,
    foldQueues,
  )
where

import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Data.Bitraversable (bimapM)
import Data.Either (fromRight)
import Data.Functor (($>))
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes)
import qualified Data.Text as T
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Database.PostgreSQL.Simple (Binary (..), Only (..), Query, SqlError)
import qualified Database.PostgreSQL.Simple as DB
import Database.PostgreSQL.Simple.FromField (FromField (..))
import Database.PostgreSQL.Simple.ToField (ToField (..))
import Database.PostgreSQL.Simple.Errors (ConstraintViolation (..), constraintViolation)
import Database.PostgreSQL.Simple.SqlQQ (sql)
import GHC.IO (catchAny)
import Simplex.Messaging.Agent.Client (withLockMap)
import Simplex.Messaging.Agent.Lock (Lock)
import Simplex.Messaging.Agent.Store.Postgres (createDBStore, closeDBStore)
import Simplex.Messaging.Agent.Store.Postgres.Common
import Simplex.Messaging.Agent.Store.Shared (MigrationConfirmation)
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.Postgres.Migrations (serverMigrations)
import Simplex.Messaging.Server.QueueStore.STM (readQueueRecIO)
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (firstRow, ifM, tshow, (<$$>))
import System.Exit (exitFailure)
import System.IO (IOMode (..), hFlush, stdout)
import UnliftIO.STM
#if !defined(dbPostgres)
import Simplex.Messaging.Agent.Store.Postgres.DB (blobFieldDecoder)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
#endif

data PostgresQueueStore q = PostgresQueueStore
  { dbStore :: DBStore,
    dbStoreLog :: Maybe (StoreLog 'WriteMode),
    -- this map caches all created and opened queues
    queues :: TMap RecipientId q,
    -- this map only cashes the queues that were attempted to send messages to,
    senders :: TMap SenderId RecipientId,
    -- this map only cashes the queues that were attempted to be subscribed to,
    notifiers :: TMap NotifierId RecipientId,
    notifierLocks :: TMap NotifierId Lock,
    deletedTTL :: Int64
  }

data PostgresStoreCfg = PostgresStoreCfg
  { dbOpts :: DBOpts,
    dbStoreLogPath :: Maybe FilePath,
    confirmMigrations :: MigrationConfirmation,
    deletedTTL :: Int64
  }

instance StoreQueueClass q => QueueStoreClass q (PostgresQueueStore q) where
  type QueueStoreCfg (PostgresQueueStore q) = PostgresStoreCfg

  newQueueStore :: PostgresStoreCfg  -> IO (PostgresQueueStore q)
  newQueueStore PostgresStoreCfg {dbOpts, dbStoreLogPath, confirmMigrations, deletedTTL} = do
    dbStore <- either err pure =<< createDBStore dbOpts serverMigrations confirmMigrations
    dbStoreLog <- mapM (openWriteStoreLog True) dbStoreLogPath
    queues <- TM.emptyIO
    senders <- TM.emptyIO
    notifiers <- TM.emptyIO
    notifierLocks <- TM.emptyIO
    pure PostgresQueueStore {dbStore, dbStoreLog, queues, senders, notifiers, notifierLocks, deletedTTL}
    where
      err e = do
        logError $ "STORE: newQueueStore, error opening PostgreSQL database, " <> tshow e
        exitFailure

  closeQueueStore :: PostgresQueueStore q -> IO ()
  closeQueueStore PostgresQueueStore {dbStore, dbStoreLog} = do
    closeDBStore dbStore
    mapM_ closeStoreLog dbStoreLog

  loadedQueues = queues
  {-# INLINE loadedQueues #-}

  compactQueues :: PostgresQueueStore q -> IO Int64
  compactQueues st@PostgresQueueStore {deletedTTL} = do
    old <- subtract deletedTTL . systemSeconds <$> liftIO getSystemTime
    fmap (fromRight 0) $ runExceptT $ withDB' "removeDeletedQueues" st $ \db ->
      DB.execute db "DELETE FROM msg_queues WHERE deleted_at < ?" (Only old)

  queueCounts :: PostgresQueueStore q -> IO QueueCounts
  queueCounts st =
    withConnection (dbStore st) $ \db -> do
      (queueCount, notifierCount) : _ <-
        DB.query_
          db
          [sql|
            SELECT
              (SELECT COUNT(1) FROM msg_queues WHERE deleted_at IS NULL) AS queue_count, 
              (SELECT COUNT(1) FROM msg_queues WHERE deleted_at IS NULL AND notifier_id IS NOT NULL) AS notifier_count
          |]
      pure QueueCounts {queueCount, notifierCount}

  -- this implementation assumes that the lock is already taken by addQueue
  -- and relies on unique constraints in the database to prevent duplicate IDs.
  addQueue_ :: PostgresQueueStore q -> (RecipientId -> QueueRec -> IO q) -> RecipientId -> QueueRec -> IO (Either ErrorType q)
  addQueue_ st mkQ rId qr = do
    sq <- mkQ rId qr
    withQueueLock sq "addQueue_" $ runExceptT $ do
      void $ withDB "addQueue_" st $ \db ->
        E.try (DB.execute db insertQueueQuery $ queueRecToRow (rId, qr))
          >>= bimapM handleDuplicate pure
      atomically $ TM.insert rId sq queues
      atomically $ TM.insert (senderId qr) rId senders
      withLog "addStoreQueue" st $ \s -> logCreateQueue s rId qr
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
      loadRcvQueue = loadQueue " WHERE recipient_id = ?" $ \_ -> pure ()
      loadSndQueue = loadQueue " WHERE sender_id = ?" $ \rId -> TM.insert qId rId senders
      loadNtfQueue = loadQueue " WHERE notifier_id = ?" $ \_ -> pure () -- do NOT cache ref - ntf subscriptions are rare
      loadQueue condition insertRef = runExceptT $ loadQueueRec >>= liftIO . cachedOrLoadedQueue st mkQ insertRef
        where
          loadQueueRec =
            withDB "getQueue_" st $ \db -> firstRow rowToQueueRec AUTH $
              DB.query db (queueRecQuery <> condition <> " AND deleted_at IS NULL") (Only qId)

  secureQueue :: PostgresQueueStore q -> q -> SndPublicAuthKey -> IO (Either ErrorType ())
  secureQueue st sq sKey =
    withQueueDB sq "secureQueue" $ \q -> do
      verify q
      assertUpdated $ withDB' "secureQueue" st $ \db ->
        DB.execute db "UPDATE msg_queues SET sender_key = ? WHERE recipient_id = ? AND deleted_at IS NULL" (sKey, rId)
      atomically $ writeTVar (queueRec sq) $ Just q {senderKey = Just sKey}
      withLog "secureQueue" st $ \s -> logSecureQueue s rId sKey
    where
      rId = recipientId sq
      verify q = case senderKey q of
        Just k | sKey /= k -> throwE AUTH
        _ -> pure ()

  addQueueNotifier :: PostgresQueueStore q -> q -> NtfCreds -> IO (Either ErrorType (Maybe NotifierId))
  addQueueNotifier st sq ntfCreds@NtfCreds {notifierId = nId, notifierKey, rcvNtfDhSecret} =
    withQueueDB sq "addQueueNotifier" $ \q ->
      ExceptT $ withLockMap (notifierLocks st) nId "addQueueNotifier" $
        ifM (TM.memberIO nId notifiers) (pure $ Left DUPLICATE_) $ runExceptT $ do
          assertUpdated $ withDB "addQueueNotifier" st $ \db ->
            E.try (update db) >>= bimapM handleDuplicate pure
          nId_ <- forM (notifier q) $ \NtfCreds {notifierId} -> atomically (TM.delete notifierId notifiers) $> notifierId
          let !q' = q {notifier = Just ntfCreds}
          atomically $ writeTVar (queueRec sq) $ Just q'
          -- cache queue notifier ID – after notifier is added ntf server will likely subscribe
          atomically $ TM.insert nId rId notifiers
          withLog "addQueueNotifier" st $ \s -> logAddNotifier s rId ntfCreds
          pure nId_
    where
      PostgresQueueStore {notifiers} = st
      rId = recipientId sq
      -- TODO [postgres] test how this query works with duplicate recipient_id (updates) and notifier_id (fails)
      update db =
        DB.execute
          db
          [sql|
            UPDATE msg_queues
            SET notifier_id = ?, notifier_key = ?, rcv_ntf_dh_secret = ?
            WHERE recipient_id = ? AND deleted_at IS NULL
          |]
          (nId, notifierKey, rcvNtfDhSecret, rId)

  deleteQueueNotifier :: PostgresQueueStore q -> q -> IO (Either ErrorType (Maybe NotifierId))
  deleteQueueNotifier st sq =
    withQueueDB sq "deleteQueueNotifier" $ \q ->
      ExceptT $ fmap sequence $ forM (notifier q) $ \NtfCreds {notifierId = nId} ->
        withLockMap (notifierLocks st) nId "deleteQueueNotifier" $ runExceptT $ do
          assertUpdated $ withDB' "deleteQueueNotifier" st update
          atomically $ TM.delete nId $ notifiers st
          atomically $ writeTVar (queueRec sq) $ Just q {notifier = Nothing}
          withLog "deleteQueueNotifier" st (`logDeleteNotifier` rId)
          pure nId
    where
      rId = recipientId sq
      update db =
        DB.execute
          db
          [sql|
            UPDATE msg_queues
            SET notifier_id = NULL, notifier_key = NULL, rcv_ntf_dh_secret = NULL
            WHERE recipient_id = ? AND deleted_at IS NULL
          |]
          (Only rId)

  suspendQueue :: PostgresQueueStore q -> q -> IO (Either ErrorType ())
  suspendQueue st sq =
    setStatusDB "suspendQueue" st sq EntityOff $
      withLog "suspendQueue" st (`logSuspendQueue` recipientId sq)

  blockQueue :: PostgresQueueStore q -> q -> BlockingInfo -> IO (Either ErrorType ())
  blockQueue st sq info =
    setStatusDB "blockQueue" st sq (EntityBlocked info) $
      withLog "blockQueue" st $ \sl -> logBlockQueue sl (recipientId sq) info

  unblockQueue :: PostgresQueueStore q -> q -> IO (Either ErrorType ())
  unblockQueue st sq =
    setStatusDB "unblockQueue" st sq EntityActive $
      withLog "unblockQueue" st (`logUnblockQueue` recipientId sq)
  
  updateQueueTime :: PostgresQueueStore q -> q -> RoundedSystemTime -> IO (Either ErrorType QueueRec)
  updateQueueTime st sq t =
    withQueueDB sq "updateQueueTime" $ \q@QueueRec {updatedAt} ->
      if updatedAt == Just t
        then pure q
        else do
          assertUpdated $ withDB' "updateQueueTime" st $ \db ->
            DB.execute db "UPDATE msg_queues SET updated_at = ? WHERE recipient_id = ? AND deleted_at IS NULL" (t, rId)
          let !q' = q {updatedAt = Just t}
          atomically $ writeTVar (queueRec sq) $ Just q'
          withLog "updateQueueTime" st $ \sl -> logUpdateQueueTime sl rId t
          pure q'
    where
      rId = recipientId sq

  -- this method is called from JournalMsgStore deleteQueue that already locks the queue
  deleteStoreQueue :: PostgresQueueStore q -> q -> IO (Either ErrorType (QueueRec, Maybe (MsgQueue q)))
  deleteStoreQueue st sq = runExceptT $ do
    q <- ExceptT $ readQueueRecIO qr
    RoundedSystemTime ts <- liftIO getSystemDate
    assertUpdated $ withDB' "deleteStoreQueue" st $ \db ->
      DB.execute db "UPDATE msg_queues SET deleted_at = ? WHERE recipient_id = ? AND deleted_at IS NULL" (ts, rId)
    atomically $ writeTVar qr Nothing
    atomically $ TM.delete (senderId q) $ senders st
    forM_ (notifier q) $ \NtfCreds {notifierId} -> atomically $ TM.delete notifierId $ notifiers st
    mq_ <- atomically $ swapTVar (msgQueue sq) Nothing
    withLog "deleteStoreQueue" st (`logDeleteQueue` rId)
    pure (q, mq_)
    where
      rId = recipientId sq
      qr = queueRec sq

batchInsertQueues :: StoreQueueClass q => Bool -> M.Map RecipientId q -> PostgresQueueStore q' -> IO Int64
batchInsertQueues tty queues toStore = do
  qs <- catMaybes <$> mapM (\(rId, q) -> (rId,) <$$> readTVarIO (queueRec q)) (M.assocs queues)
  putStrLn $ "Importing " <> show (length qs) <> " queues..."
  let st = dbStore toStore
  (qCnt, count) <- foldM (processChunk st) (0, 0) $ toChunks 1000000 qs
  putStrLn $ progress count
  pure qCnt
  where
    processChunk st (qCnt, i) qs = do
      qCnt' <- withConnection st $ \db -> DB.executeMany db insertQueueQuery $ map queueRecToRow qs
      let i' = i + length qs
      when tty $ putStr (progress i' <> "\r") >> hFlush stdout
      pure (qCnt + qCnt', i')
    progress i = "Imported: " <> show i <> " queues"
    toChunks :: Int -> [a] -> [[a]]
    toChunks _ [] = []
    toChunks n xs =
      let (ys, xs') = splitAt n xs
       in ys : toChunks n xs'

insertQueueQuery :: Query
insertQueueQuery =
  [sql|
    INSERT INTO msg_queues
      (recipient_id, recipient_key, rcv_dh_secret, sender_id, sender_key, snd_secure, notifier_id, notifier_key, rcv_ntf_dh_secret, status, updated_at)
    VALUES (?,?,?,?,?,?,?,?,?,?,?)
  |]

foldQueues :: Monoid a => Bool -> PostgresQueueStore q -> (RecipientId -> QueueRec -> IO q) -> (q -> IO a) -> IO a
foldQueues tty st mkQ f =
  foldQueueRecs tty st $ cachedOrLoadedQueue st mkQ (\_ -> pure ()) >=> f

foldQueueRecs :: Monoid a => Bool -> PostgresQueueStore q -> ((RecipientId, QueueRec) -> IO a) -> IO a
foldQueueRecs tty st f = do
  (n, r) <- withConnection (dbStore st) $ \db ->
    DB.fold_ db (queueRecQuery <> " WHERE deleted_at IS NULL") (0 :: Int, mempty) $ \(!i, !acc) row -> do
      r <- f $ rowToQueueRec row
      let i' = i + 1
      when (tty && i' `mod` 100000 == 0) $ putStr (progress i <> "\r") >> hFlush stdout
      pure (i', acc <> r)
  when tty $ putStrLn $ progress n
  pure r
  where
    progress i = "Processed: " <> show i <> " records"

queueRecQuery :: Query
queueRecQuery =
  [sql|
    SELECT recipient_id, recipient_key, rcv_dh_secret,
      sender_id, sender_key, snd_secure,
      notifier_id, notifier_key, rcv_ntf_dh_secret,
      status, updated_at
    FROM msg_queues
  |]

cachedOrLoadedQueue :: PostgresQueueStore q -> (RecipientId -> QueueRec -> IO q) -> (RecipientId -> STM ()) -> (RecipientId, QueueRec) -> IO q
cachedOrLoadedQueue PostgresQueueStore {queues} mkQ insertRef (rId, qRec) = do
  sq <- liftIO $ mkQ rId qRec -- loaded queue
  atomically $
    -- checking the cache again for concurrent reads,
    -- use previously loaded queue if exists.
    TM.lookup rId queues >>= \case
      Just sq' -> pure sq'
      Nothing -> do
        insertRef rId
        TM.insert rId sq queues
        pure sq

type QueueRecRow = (RecipientId, RcvPublicAuthKey, RcvDhSecret, SenderId, Maybe SndPublicAuthKey, SenderCanSecure, Maybe NotifierId, Maybe NtfPublicAuthKey, Maybe RcvNtfDhSecret, ServerEntityStatus, Maybe RoundedSystemTime)

queueRecToRow :: (RecipientId, QueueRec) -> QueueRecRow
queueRecToRow (rId, QueueRec {recipientKey, rcvDhSecret, senderId, senderKey, sndSecure, notifier = n, status, updatedAt}) =
  (rId, recipientKey, rcvDhSecret, senderId, senderKey, sndSecure, notifierId <$> n, notifierKey <$> n, rcvNtfDhSecret <$> n, status, updatedAt)

rowToQueueRec :: QueueRecRow -> (RecipientId, QueueRec)
rowToQueueRec (rId, recipientKey, rcvDhSecret, senderId, senderKey, sndSecure, notifierId_, notifierKey_, rcvNtfDhSecret_, status, updatedAt) =
  let notifier = NtfCreds <$> notifierId_ <*> notifierKey_ <*> rcvNtfDhSecret_
   in (rId, QueueRec {recipientKey, rcvDhSecret, senderId, senderKey, sndSecure, notifier, status, updatedAt})

setStatusDB :: StoreQueueClass q => String -> PostgresQueueStore q -> q -> ServerEntityStatus -> ExceptT ErrorType IO () -> IO (Either ErrorType ())
setStatusDB op st sq status writeLog =
  withQueueDB sq op $ \q -> do
    assertUpdated $ withDB' op st $ \db ->
      DB.execute db "UPDATE msg_queues SET status = ? WHERE recipient_id = ? AND deleted_at IS NULL" (status, recipientId sq)
    atomically $ writeTVar (queueRec sq) $ Just q {status}
    writeLog

withQueueDB :: StoreQueueClass q => q -> String -> (QueueRec -> ExceptT ErrorType IO a) -> IO (Either ErrorType a)
withQueueDB sq op action =
  withQueueLock sq op $ runExceptT $ ExceptT (readQueueRecIO $ queueRec sq) >>= action

assertUpdated :: ExceptT ErrorType IO Int64 -> ExceptT ErrorType IO ()
assertUpdated = (>>= \n -> when (n == 0) (throwE AUTH))

withDB' :: String -> PostgresQueueStore q -> (DB.Connection -> IO a) -> ExceptT ErrorType IO a
withDB' op st action = withDB op st $ fmap Right . action

withDB :: forall a q. String -> PostgresQueueStore q -> (DB.Connection -> IO (Either ErrorType a)) -> ExceptT ErrorType IO a
withDB op st action =
  ExceptT $ E.try (withConnection (dbStore st) action) >>= either logErr pure
  where
    logErr :: E.SomeException -> IO (Either ErrorType a)
    logErr e = logError ("STORE: " <> T.pack err) $> Left (STORE err)
      where
        err = op <> ", withLog, " <> show e

withLog :: MonadIO m => String -> PostgresQueueStore q -> (StoreLog 'WriteMode -> IO ()) -> m ()
withLog op PostgresQueueStore {dbStoreLog} action =
  forM_ dbStoreLog $ \sl -> liftIO $ E.uninterruptibleMask_ (action sl) `catchAny` \e ->
    logWarn $ "STORE: " <> T.pack (op <> ", withLog, " <> show e)

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
