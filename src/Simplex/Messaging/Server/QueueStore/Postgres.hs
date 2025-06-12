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
    batchInsertServices,
    batchInsertQueues,
    foldServiceRecs,
    foldQueueRecs,
    handleDuplicate,
    withLog_,
    withDB',
  )
where

import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Data.Bifunctor (first)
import Data.ByteString.Builder (Builder)
import qualified Data.ByteString.Builder as BB
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Lazy as LB
import Data.Bitraversable (bimapM)
import Data.Either (fromRight, lefts)
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List (foldl', intersperse, partition)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes, fromMaybe)
import qualified Data.Set as S
import Data.Text (Text)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import qualified Data.X509 as X
import qualified Data.X509.Validation as XV
import Database.PostgreSQL.Simple (Binary (..), In (..), Only (..), Query, SqlError, (:.) (..))
import qualified Database.PostgreSQL.Simple as DB
import qualified Database.PostgreSQL.Simple.Copy as DB
import Database.PostgreSQL.Simple.FromField (FromField (..))
import Database.PostgreSQL.Simple.ToField (Action (..), ToField (..))
import Database.PostgreSQL.Simple.Errors (ConstraintViolation (..), constraintViolation)
import Database.PostgreSQL.Simple.SqlQQ (sql)
import GHC.IO (catchAny)
import Simplex.Messaging.Agent.Client (withLockMap)
import Simplex.Messaging.Agent.Lock (Lock)
import Simplex.Messaging.Agent.Store.AgentStore ()
import Simplex.Messaging.Agent.Store.Postgres (createDBStore, closeDBStore)
import Simplex.Messaging.Agent.Store.Postgres.Common
import Simplex.Messaging.Agent.Store.Postgres.DB (blobFieldDecoder)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.Postgres.Config
import Simplex.Messaging.Server.QueueStore.Postgres.Migrations (serverMigrations)
import Simplex.Messaging.Server.QueueStore.STM (STMService (..), readQueueRecIO)
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (SMPServiceRole (..))
import Simplex.Messaging.Util (eitherToMaybe, firstRow, ifM, maybeFirstRow, tshow, (<$$>))
import System.Exit (exitFailure)
import System.IO (IOMode (..), hFlush, stdout)
import UnliftIO.STM

#if !defined(dbPostgres)
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Simplex.Messaging.Agent.Store.Postgres.DB (fromTextField_)
import Simplex.Messaging.Encoding.String
#endif

data PostgresQueueStore q = PostgresQueueStore
  { dbStore :: DBStore,
    dbStoreLog :: Maybe (StoreLog 'WriteMode),
    -- this map caches all created and opened queues
    queues :: TMap RecipientId q,
    -- this map only cashes the queues that were attempted to send messages to,
    senders :: TMap SenderId RecipientId,
    links :: TMap LinkId RecipientId,
    -- this map only cashes the queues that were attempted to be subscribed to,
    notifiers :: TMap NotifierId RecipientId,
    notifierLocks :: TMap NotifierId Lock,
    serviceLocks :: TMap CertFingerprint Lock,
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
    links <- TM.emptyIO
    notifiers <- TM.emptyIO
    notifierLocks <- TM.emptyIO
    serviceLocks <- TM.emptyIO
    pure PostgresQueueStore {dbStore, dbStoreLog, queues, senders, links, notifiers, notifierLocks, serviceLocks, deletedTTL}
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

  getEntityCounts :: PostgresQueueStore q -> IO EntityCounts
  getEntityCounts st =
    withConnection (dbStore st) $ \db -> do
      (queueCount, notifierCount, rcvServiceCount, ntfServiceCount, rcvServiceQueuesCount, ntfServiceQueuesCount) : _ <-
        DB.query
          db
          [sql|
            SELECT
              (SELECT COUNT(1) FROM msg_queues WHERE deleted_at IS NULL) AS queue_count,
              (SELECT COUNT(1) FROM msg_queues WHERE deleted_at IS NULL AND notifier_id IS NOT NULL) AS notifier_count,
              (SELECT COUNT(1) FROM services WHERE service_role = ?) AS rcv_service_count,
              (SELECT COUNT(1) FROM services WHERE service_role = ?) AS ntf_service_count,
              (SELECT COUNT(1) FROM msg_queues WHERE rcv_service_id IS NOT NULL AND deleted_at IS NULL) AS rcv_service_queues_count,
              (SELECT COUNT(1) FROM msg_queues WHERE ntf_service_id IS NOT NULL AND deleted_at IS NULL) AS ntf_service_queues_count
          |]
          (SRMessaging, SRNotifier)
      pure EntityCounts {queueCount, notifierCount, rcvServiceCount, ntfServiceCount, rcvServiceQueuesCount, ntfServiceQueuesCount}

  -- this implementation assumes that the lock is already taken by addQueue
  -- and relies on unique constraints in the database to prevent duplicate IDs.
  addQueue_ :: PostgresQueueStore q -> (RecipientId -> QueueRec -> IO q) -> RecipientId -> QueueRec -> IO (Either ErrorType q)
  addQueue_ st mkQ rId qr = do
    sq <- mkQ rId qr
    withQueueLock sq "addQueue_" $ E.uninterruptibleMask_ $ runExceptT $ do
      void $ withDB "addQueue_" st $ \db ->
        E.try (DB.execute db insertQueueQuery $ queueRecToRow (rId, qr))
          >>= bimapM handleDuplicate pure
      atomically $ TM.insert rId sq queues
      atomically $ TM.insert (senderId qr) rId senders
      forM_ (notifier qr) $ \NtfCreds {notifierId = nId} -> atomically $ TM.insert nId rId notifiers
      forM_ (queueData qr) $ \(lnkId, _) -> atomically $ TM.insert lnkId rId links
      withLog "addStoreQueue" st $ \s -> logCreateQueue s rId qr
      pure sq
    where
      PostgresQueueStore {queues, senders, links, notifiers} = st
      -- Not doing duplicate checks in maps as the probability of duplicates is very low.
      -- It needs to be reconsidered when IDs are supplied by the users.
      -- hasId = anyM [TM.memberIO rId queues, TM.memberIO senderId senders, hasNotifier]
      -- hasNotifier = maybe (pure False) (\NtfCreds {notifierId} -> TM.memberIO notifierId notifiers) notifier

  getQueue_ :: QueueParty p => PostgresQueueStore q -> (Bool -> RecipientId -> QueueRec -> IO q) -> SParty p -> QueueId -> IO (Either ErrorType q)
  getQueue_ st mkQ party qId = case party of
    SRecipient -> getRcvQueue qId
    SSender -> TM.lookupIO qId senders >>= maybe (mask loadSndQueue) getRcvQueue
    SSenderLink -> TM.lookupIO qId links >>= maybe (mask loadLinkQueue) getRcvQueue
    -- loaded queue is deleted from notifiers map to reduce cache size after queue was subscribed to by ntf server
    SNotifier -> TM.lookupIO qId notifiers >>= maybe (mask loadNtfQueue) (getRcvQueue >=> (atomically (TM.delete qId notifiers) $>))
    where
      PostgresQueueStore {queues, senders, links, notifiers} = st
      getRcvQueue rId = TM.lookupIO rId queues >>= maybe (mask loadRcvQueue) (pure . Right)
      loadRcvQueue = do
        (rId, qRec) <- loadQueue " WHERE recipient_id = ?"
        liftIO $ cacheQueue rId qRec $ \_ -> pure () -- recipient map already checked, not caching sender ref
      loadSndQueue = loadSndQueue_ " WHERE sender_id = ?"
      loadLinkQueue = loadSndQueue_ " WHERE link_id = ?"
      loadNtfQueue = do
        (rId, qRec) <- loadQueue " WHERE notifier_id = ?"
        liftIO $
          TM.lookupIO rId queues -- checking recipient map first, not creating lock in map, not caching queue
            >>= maybe (mkQ False rId qRec) pure
      loadSndQueue_ condition = do
        (rId, qRec) <- loadQueue condition
        liftIO $
          TM.lookupIO rId queues -- checking recipient map first
            >>= maybe (cacheQueue rId qRec cacheSender) (atomically (cacheSender rId) $>)
      mask = E.uninterruptibleMask_ . runExceptT
      cacheSender rId = TM.insert qId rId senders
      loadQueue condition =
        withDB "getQueue_" st $ \db -> firstRow rowToQueueRec AUTH $
          DB.query db (queueRecQuery <> condition <> " AND deleted_at IS NULL") (Only qId)
      cacheQueue rId qRec insertRef = do
        sq <- mkQ True rId qRec -- loaded queue
        -- This lock prevents the scenario when the queue is added to cache,
        -- while another thread is proccessing the same queue in withAllMsgQueues
        -- without adding it to cache, possibly trying to open the same files twice.
        -- Alse see comment in idleDeleteExpiredMsgs.
        withQueueLock sq "getQueue_" $ atomically $
          -- checking the cache again for concurrent reads,
          -- use previously loaded queue if exists.
          TM.lookup rId queues >>= \case
            Just sq' -> pure sq'
            Nothing -> do
              insertRef rId
              TM.insert rId sq queues
              pure sq

  getQueues_ :: forall p. BatchParty p => PostgresQueueStore q -> (Bool -> RecipientId -> QueueRec -> IO q) -> SParty p -> [QueueId] -> IO [Either ErrorType q]
  getQueues_ st mkQ party qIds = case party of
    SRecipient -> do
      qs <- readTVarIO queues
      let qs' = map (\qId -> get qs qId qId) qIds
      E.uninterruptibleMask_ $ loadQueues qs' " WHERE recipient_id IN ?" cacheRcvQueue
    SNotifier -> do
      ns <- readTVarIO notifiers
      qs <- readTVarIO queues
      let qs' = map (\qId -> get ns qId qId >>= get qs qId) qIds
      E.uninterruptibleMask_ $ loadQueues qs' " WHERE notifier_id IN ?" $ \(rId, qRec) ->
        forM (notifier qRec) $ \NtfCreds {notifierId = nId} -> -- it is always Just with this query
          (nId,) <$> maybe (mkQ False rId qRec) pure (M.lookup rId qs)
    where
      PostgresQueueStore {queues, notifiers} = st
      get :: M.Map QueueId a -> QueueId -> QueueId -> Either QueueId a
      get m qId = maybe (Left qId) Right . (`M.lookup` m)
      loadQueues :: [Either QueueId q] -> Query -> ((RecipientId, QueueRec) -> IO (Maybe (QueueId, q))) -> IO [Either ErrorType q]
      loadQueues qs' cond mkCacheQueue = do
        let qIds' = lefts qs'
        if null qIds'
          then pure $ map (first (const INTERNAL)) qs'
          else do
            qs_ <-
              runExceptT $ fmap M.fromList $
                withDB' "getQueues_" st (\db -> DB.query db (queueRecQuery <> cond <> " AND deleted_at IS NULL") (Only (In qIds')))
                  >>= liftIO . fmap catMaybes . mapM (mkCacheQueue . rowToQueueRec)
            pure $ map (result qs_) qs'
        where
          result :: Either ErrorType (M.Map QueueId q) -> Either QueueId q -> Either ErrorType q
          result _ (Right q) = Right q
          result qs_ (Left qId) = maybe (Left AUTH) Right . M.lookup qId =<< qs_
      cacheRcvQueue (rId, qRec) = do
        sq <- mkQ True rId qRec
        sq' <- withQueueLock sq "getQueue_" $ atomically $
          -- checking the cache again for concurrent reads, use previously loaded queue if exists.
          TM.lookup rId queues >>= \case
            Just sq' -> pure sq'
            Nothing -> sq <$ TM.insert rId sq queues
        pure $ Just (rId, sq')

  getQueueLinkData :: PostgresQueueStore q -> q -> LinkId -> IO (Either ErrorType QueueLinkData)
  getQueueLinkData st sq lnkId = runExceptT $ do
    qr <- ExceptT $ readQueueRecIO $ queueRec sq
    case queueData qr of
      Just (lnkId', _) | lnkId' == lnkId ->
        withDB "getQueueLinkData" st $ \db -> firstRow id AUTH $
          DB.query db "SELECT fixed_data, user_data FROM msg_queues WHERE link_id = ? AND deleted_at IS NULL" (Only lnkId)
      _ -> throwE AUTH

  addQueueLinkData :: PostgresQueueStore q -> q -> LinkId -> QueueLinkData -> IO (Either ErrorType ())
  addQueueLinkData st sq lnkId d =
    withQueueRec sq "addQueueLinkData" $ \q -> case queueData q of
      Nothing ->
        addLink q $ \db -> DB.execute db qry (d :. (lnkId, rId))
      Just (lnkId', _) | lnkId' == lnkId ->
        addLink q $ \db -> DB.execute db (qry <> " AND (fixed_data IS NULL OR fixed_data = ?)") (d :. (lnkId, rId, fst d))
      _ -> throwE AUTH
    where
      rId = recipientId sq
      addLink q update = do
        assertUpdated $ withDB' "addQueueLinkData" st update
        atomically $ writeTVar (queueRec sq) $ Just q {queueData = Just (lnkId, d)}
        withLog "addQueueLinkData" st $ \s -> logCreateLink s rId lnkId d
      qry = "UPDATE msg_queues SET fixed_data = ?, user_data = ?, link_id = ? WHERE recipient_id = ? AND deleted_at IS NULL"

  deleteQueueLinkData :: PostgresQueueStore q -> q -> IO (Either ErrorType ())
  deleteQueueLinkData st sq =
    withQueueRec sq "deleteQueueLinkData" $ \q -> case queueData q of
      Just _ -> do
        assertUpdated $ withDB' "deleteQueueLinkData" st $ \db ->
          DB.execute db "UPDATE msg_queues SET link_id = NULL, fixed_data = NULL, user_data = NULL WHERE recipient_id = ? AND deleted_at IS NULL" (Only rId)
        atomically $ writeTVar (queueRec sq) $ Just q {queueData = Nothing}
        withLog "deleteQueueLinkData" st (`logDeleteLink` rId)
      _ -> throwE AUTH
    where
      rId = recipientId sq

  secureQueue :: PostgresQueueStore q -> q -> SndPublicAuthKey -> IO (Either ErrorType ())
  secureQueue st sq sKey =
    withQueueRec sq "secureQueue" $ \q -> do
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

  updateKeys :: PostgresQueueStore q -> q -> NonEmpty RcvPublicAuthKey -> IO (Either ErrorType ())
  updateKeys st sq rKeys =
    withQueueRec sq "updateKeys" $ \q -> do
      assertUpdated $ withDB' "updateKeys" st $ \db ->
        DB.execute db "UPDATE msg_queues SET recipient_keys = ? WHERE recipient_id = ? AND deleted_at IS NULL" (rKeys, rId)
      atomically $ writeTVar (queueRec sq) $ Just q {recipientKeys = rKeys}
      withLog "updateKeys" st $ \s -> logUpdateKeys s rId rKeys
    where
      rId = recipientId sq

  addQueueNotifier :: PostgresQueueStore q -> q -> NtfCreds -> IO (Either ErrorType (Maybe NtfCreds))
  addQueueNotifier st sq ntfCreds@NtfCreds {notifierId = nId, notifierKey, rcvNtfDhSecret} =
    withQueueRec sq "addQueueNotifier" $ \q ->
      ExceptT $ withLockMap (notifierLocks st) nId "addQueueNotifier" $
        ifM (TM.memberIO nId notifiers) (pure $ Left DUPLICATE_) $ runExceptT $ do
          assertUpdated $ withDB "addQueueNotifier" st $ \db ->
            E.try (update db) >>= bimapM handleDuplicate pure
          nc_ <- forM (notifier q) $ \nc@NtfCreds {notifierId} -> atomically (TM.delete notifierId notifiers) $> nc
          let !q' = q {notifier = Just ntfCreds}
          atomically $ writeTVar (queueRec sq) $ Just q'
          -- cache queue notifier ID – after notifier is added ntf server will likely subscribe
          atomically $ TM.insert nId rId notifiers
          withLog "addQueueNotifier" st $ \s -> logAddNotifier s rId ntfCreds
          pure nc_
    where
      PostgresQueueStore {notifiers} = st
      rId = recipientId sq
      update db =
        DB.execute
          db
          [sql|
            UPDATE msg_queues
            SET notifier_id = ?, notifier_key = ?, rcv_ntf_dh_secret = ?, ntf_service_id = NULL
            WHERE recipient_id = ? AND deleted_at IS NULL
          |]
          (nId, notifierKey, rcvNtfDhSecret, rId)

  deleteQueueNotifier :: PostgresQueueStore q -> q -> IO (Either ErrorType (Maybe NtfCreds))
  deleteQueueNotifier st sq =
    withQueueRec sq "deleteQueueNotifier" $ \q ->
      ExceptT $ fmap sequence $ forM (notifier q) $ \nc@NtfCreds {notifierId = nId} ->
        withLockMap (notifierLocks st) nId "deleteQueueNotifier" $ runExceptT $ do
          assertUpdated $ withDB' "deleteQueueNotifier" st update
          atomically $ TM.delete nId $ notifiers st
          atomically $ writeTVar (queueRec sq) $ Just q {notifier = Nothing}
          withLog "deleteQueueNotifier" st (`logDeleteNotifier` rId)
          pure nc
    where
      rId = recipientId sq
      update db =
        DB.execute
          db
          [sql|
            UPDATE msg_queues
            SET notifier_id = NULL, notifier_key = NULL, rcv_ntf_dh_secret = NULL, ntf_service_id = NULL
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
    withQueueRec sq "updateQueueTime" $ \q@QueueRec {updatedAt} ->
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
  deleteStoreQueue st sq = E.uninterruptibleMask_ $ runExceptT $ do
    q <- ExceptT $ readQueueRecIO qr
    RoundedSystemTime ts <- liftIO getSystemDate
    assertUpdated $ withDB' "deleteStoreQueue" st $ \db ->
      DB.execute db "UPDATE msg_queues SET deleted_at = ? WHERE recipient_id = ? AND deleted_at IS NULL" (ts, rId)
    atomically $ writeTVar qr Nothing
    atomically $ TM.delete (senderId q) $ senders st
    forM_ (notifier q) $ \NtfCreds {notifierId} -> do
      atomically $ TM.delete notifierId $ notifiers st
      atomically $ TM.delete notifierId $ notifierLocks st
    mq_ <- atomically $ swapTVar (msgQueue sq) Nothing
    withLog "deleteStoreQueue" st (`logDeleteQueue` rId)
    pure (q, mq_)
    where
      rId = recipientId sq
      qr = queueRec sq

  getCreateService :: PostgresQueueStore q -> ServiceRec -> IO (Either ErrorType ServiceId)
  getCreateService st sr@ServiceRec {serviceId = newSrvId, serviceRole, serviceCertHash = XV.Fingerprint fp} =
    withLockMap (serviceLocks st) fp "getCreateService" $ E.uninterruptibleMask_ $ runExceptT $ do
      (serviceId, new) <-
        withDB "getCreateService" st $ \db ->
          maybeFirstRow id (DB.query db "SELECT service_id, service_role FROM services WHERE service_cert_hash = ?" (Only (Binary fp))) >>= \case
            Just (serviceId, role)
              | role == serviceRole -> pure $ Right (serviceId, False)
              | otherwise -> pure $ Left SERVICE
            Nothing ->
              E.try (DB.execute db insertServiceQuery (serviceRecToRow sr))
                >>= bimapM handleDuplicate (\_ -> pure (newSrvId, True))
      when new $ withLog "getCreateService" st (`logNewService` sr)
      pure serviceId

  setQueueService :: (PartyI p, ServiceParty p) => PostgresQueueStore q -> q -> SParty p -> Maybe ServiceId -> IO (Either ErrorType ())
  setQueueService st sq party serviceId = withQueueRec sq "setQueueService" $ \q -> case party of
    SRecipientService
      | rcvServiceId q == serviceId -> pure ()
      | otherwise -> do
          assertUpdated $ withDB' "setQueueService" st $ \db ->
            DB.execute db "UPDATE msg_queues SET rcv_service_id = ? WHERE recipient_id = ? AND deleted_at IS NULL" (serviceId, rId)
          updateQueueRec q {rcvServiceId = serviceId}
    SNotifierService -> case notifier q of
      Nothing -> throwE AUTH
      Just nc@NtfCreds {ntfServiceId = prevSrvId}
        | prevSrvId == serviceId -> pure ()
        | otherwise -> do
            assertUpdated $ withDB' "setQueueService" st $ \db ->
              DB.execute db "UPDATE msg_queues SET ntf_service_id = ? WHERE recipient_id = ? AND notifier_id IS NOT NULL AND deleted_at IS NULL" (serviceId, rId)
            updateQueueRec q {notifier = Just nc {ntfServiceId = serviceId}}
    where
      rId = recipientId sq
      updateQueueRec :: QueueRec -> ExceptT ErrorType IO ()
      updateQueueRec q' = do
        atomically $ writeTVar (queueRec sq) $ Just q'
        withLog "setQueueService" st $ \sl -> logQueueService sl rId party serviceId

  getQueueNtfServices :: PostgresQueueStore q -> [(NotifierId, a)] -> IO (Either ErrorType ([(Maybe ServiceId, [(NotifierId, a)])], [(NotifierId, a)]))
  getQueueNtfServices st ntfs = E.uninterruptibleMask_ $ runExceptT $ do
    snIds <-
      withDB' "getQueueNtfServices" st $ \db ->
        DB.query db "SELECT ntf_service_id, notifier_id FROM msg_queues WHERE notifier_id IN ? AND deleted_at IS NULL" (Only (In (map fst ntfs)))
    pure $
      if null snIds
        then ([], ntfs)
        else
          let snIds' = foldl' (\m (sId, nId) -> M.alter (Just . maybe (S.singleton nId) (S.insert nId)) sId m) M.empty snIds
           in foldr addService ([], ntfs) (M.assocs snIds')
    where
      addService ::
        (Maybe ServiceId, S.Set NotifierId) ->
        ([(Maybe ServiceId, [(NotifierId, a)])], [(NotifierId, a)]) ->
        ([(Maybe ServiceId, [(NotifierId, a)])], [(NotifierId, a)])
      addService (serviceId, snIds) (ssNtfs, ntfs') =
        let (sNtfs, restNtfs) = partition (\(nId, _) -> S.member nId snIds) ntfs'
         in ((serviceId, sNtfs) : ssNtfs, restNtfs)

  getNtfServiceQueueCount :: PostgresQueueStore q -> ServiceId -> IO (Either ErrorType Int64)
  getNtfServiceQueueCount st serviceId =
    E.uninterruptibleMask_ $ runExceptT $ withDB' "getNtfServiceQueueCount" st $ \db ->
      fmap (fromMaybe 0) $ maybeFirstRow fromOnly $
        DB.query db "SELECT count(1) FROM msg_queues WHERE ntf_service_id = ? AND deleted_at IS NULL" (Only serviceId)

batchInsertServices :: [STMService] -> PostgresQueueStore q -> IO Int64
batchInsertServices services' toStore =
  withConnection (dbStore toStore) $ \db ->
    DB.executeMany db insertServiceQuery $ map (serviceRecToRow . serviceRec) services'

batchInsertQueues :: StoreQueueClass q => Bool -> M.Map RecipientId q -> PostgresQueueStore q' -> IO Int64
batchInsertQueues tty queues toStore = do
  qs <- catMaybes <$> mapM (\(rId, q) -> (rId,) <$$> readTVarIO (queueRec q)) (M.assocs queues)
  putStrLn $ "Importing " <> show (length qs) <> " queues..."
  let st = dbStore toStore
  count <-
    withConnection st $ \db -> do
      DB.copy_
        db
        [sql|
          COPY msg_queues (recipient_id, recipient_keys, rcv_dh_secret, sender_id, sender_key, queue_mode, notifier_id, notifier_key, rcv_ntf_dh_secret, ntf_service_id, status, updated_at, link_id, rcv_service_id, fixed_data, user_data)
          FROM STDIN WITH (FORMAT CSV)
        |]
      mapM_ (putQueue db) (zip [1..] qs)
      DB.putCopyEnd db
  Only qCnt : _ <- withConnection st (`DB.query_` "SELECT count(*) FROM msg_queues")
  putStrLn $ progress count
  pure qCnt
  where
    putQueue db (i :: Int, q) = do
      DB.putCopyData db $ queueRecToText q
      when (tty && i `mod` 100000 == 0) $ putStr (progress i <> "\r") >> hFlush stdout
    progress i = "Imported: " <> show i <> " queues"

insertQueueQuery :: Query
insertQueueQuery =
  [sql|
    INSERT INTO msg_queues
      (recipient_id, recipient_keys, rcv_dh_secret, sender_id, sender_key, queue_mode, notifier_id, notifier_key, rcv_ntf_dh_secret, ntf_service_id, status, updated_at, link_id, rcv_service_id, fixed_data, user_data)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
  |]

insertServiceQuery :: Query
insertServiceQuery =
  [sql|
    INSERT INTO services
      (service_id, service_role, service_cert, service_cert_hash, created_at)
    VALUES (?,?,?,?,?)
  |]

foldServiceRecs :: forall a q. Monoid a => PostgresQueueStore q -> (ServiceRec -> IO a) -> IO a
foldServiceRecs st f =
  withConnection (dbStore st) $ \db ->
    DB.fold_ db "SELECT service_id, service_role, service_cert, service_cert_hash, created_at FROM services" mempty $
      \ !acc -> fmap (acc <>) . f . rowToServiceRec

foldQueueRecs :: forall a q. Monoid a => Bool -> Bool -> PostgresQueueStore q -> Maybe Int64 -> ((RecipientId, QueueRec) -> IO a) -> IO a
foldQueueRecs tty withData st skipOld_ f = do
  (n, r) <- withConnection (dbStore st) $ \db ->
    foldRecs db (0 :: Int, mempty) $ \(i, acc) qr -> do
      r <- f qr
      let !i' = i + 1
          !acc' = acc <> r
      when (tty && i' `mod` 100000 == 0) $ putStr (progress i' <> "\r") >> hFlush stdout
      pure (i', acc')
  when tty $ putStrLn $ progress n
  pure r
  where
    foldRecs db acc f' = case skipOld_ of
      Nothing
        | withData -> DB.fold_ db (queueRecQueryWithData <> " WHERE deleted_at IS NULL") acc $ \acc' -> f' acc' . rowToQueueRecWithData
        | otherwise -> DB.fold_ db (queueRecQuery <> " WHERE deleted_at IS NULL") acc $ \acc' -> f' acc' . rowToQueueRec
      Just old
        | withData -> DB.fold db (queueRecQueryWithData <> " WHERE deleted_at IS NULL AND updated_at > ?") (Only old) acc $ \acc' -> f' acc' . rowToQueueRecWithData
        | otherwise -> DB.fold db (queueRecQuery <> " WHERE deleted_at IS NULL AND updated_at > ?") (Only old) acc $ \acc' -> f' acc' . rowToQueueRec
    progress i = "Processed: " <> show i <> " records"

queueRecQuery :: Query
queueRecQuery =
  [sql|
    SELECT recipient_id, recipient_keys, rcv_dh_secret,
      sender_id, sender_key, queue_mode,
      notifier_id, notifier_key, rcv_ntf_dh_secret, ntf_service_id,
      status, updated_at, link_id, rcv_service_id
    FROM msg_queues
  |]

queueRecQueryWithData :: Query
queueRecQueryWithData =
  [sql|
    SELECT recipient_id, recipient_keys, rcv_dh_secret,
      sender_id, sender_key, queue_mode,
      notifier_id, notifier_key, rcv_ntf_dh_secret, ntf_service_id,
      status, updated_at, link_id, rcv_service_id,
      fixed_data, user_data
    FROM msg_queues
  |]

type QueueRecRow =
  ( RecipientId, NonEmpty RcvPublicAuthKey, RcvDhSecret,
    SenderId, Maybe SndPublicAuthKey, Maybe QueueMode,
    Maybe NotifierId, Maybe NtfPublicAuthKey, Maybe RcvNtfDhSecret, Maybe ServiceId,
    ServerEntityStatus, Maybe RoundedSystemTime, Maybe LinkId, Maybe ServiceId
  )

queueRecToRow :: (RecipientId, QueueRec) -> QueueRecRow :. (Maybe EncDataBytes, Maybe EncDataBytes)
queueRecToRow (rId, QueueRec {recipientKeys, rcvDhSecret, senderId, senderKey, queueMode, queueData, notifier = n, status, updatedAt, rcvServiceId}) =
  (rId, recipientKeys, rcvDhSecret, senderId, senderKey, queueMode, notifierId <$> n, notifierKey <$> n, rcvNtfDhSecret <$> n, ntfServiceId =<< n, status, updatedAt, linkId_, rcvServiceId)
    :. (fst <$> queueData_, snd <$> queueData_)
  where
    (linkId_, queueData_) = queueDataColumns queueData

queueRecToText :: (RecipientId, QueueRec) -> ByteString
queueRecToText (rId, QueueRec {recipientKeys, rcvDhSecret, senderId, senderKey, queueMode, queueData, notifier = n, status, updatedAt, rcvServiceId}) =
  LB.toStrict $ BB.toLazyByteString $ mconcat tabFields <> BB.char7 '\n'
  where
    tabFields = BB.char7 ',' `intersperse` fields
    fields =
      [ renderField (toField rId),
        renderField (toField recipientKeys),
        renderField (toField rcvDhSecret),
        renderField (toField senderId),
        nullable senderKey,
        nullable queueMode,
        nullable (notifierId <$> n),
        nullable (notifierKey <$> n),
        nullable (rcvNtfDhSecret <$> n),
        nullable (ntfServiceId =<< n),
        BB.char7 '"' <> renderField (toField status) <> BB.char7 '"',
        nullable updatedAt,
        nullable linkId_,
        nullable rcvServiceId,
        nullable (fst <$> queueData_),
        nullable (snd <$> queueData_)
      ]
    (linkId_, queueData_) = queueDataColumns queueData
    nullable :: ToField a => Maybe a -> Builder
    nullable = maybe mempty (renderField . toField)
    renderField :: Action -> Builder
    renderField = \case
      Plain bld -> bld
      Escape s -> BB.byteString s
      EscapeByteA s -> BB.string7 "\\x" <> BB.byteStringHex s
      EscapeIdentifier s -> BB.byteString s -- Not used in COPY data
      Many as -> mconcat (map renderField as)

queueDataColumns :: Maybe (LinkId, QueueLinkData) -> (Maybe LinkId, Maybe QueueLinkData)
queueDataColumns = \case
  Just (linkId, linkData) -> (Just linkId, Just linkData)
  Nothing -> (Nothing, Nothing)

rowToQueueRec :: QueueRecRow -> (RecipientId, QueueRec)
rowToQueueRec (rId, recipientKeys, rcvDhSecret, senderId, senderKey, queueMode, notifierId_, notifierKey_, rcvNtfDhSecret_, ntfServiceId, status, updatedAt, linkId_, rcvServiceId) =
  let notifier = mkNotifier (notifierId_, notifierKey_, rcvNtfDhSecret_) ntfServiceId
      queueData = (,(EncDataBytes "", EncDataBytes "")) <$> linkId_
   in (rId, QueueRec {recipientKeys, rcvDhSecret, senderId, senderKey, queueMode, queueData, notifier, status, updatedAt, rcvServiceId})

rowToQueueRecWithData :: QueueRecRow :. (Maybe EncDataBytes, Maybe EncDataBytes) -> (RecipientId, QueueRec)
rowToQueueRecWithData ((rId, recipientKeys, rcvDhSecret, senderId, senderKey, queueMode, notifierId_, notifierKey_, rcvNtfDhSecret_, ntfServiceId, status, updatedAt, linkId_, rcvServiceId) :. (immutableData_, userData_)) =
  let notifier = mkNotifier (notifierId_, notifierKey_, rcvNtfDhSecret_) ntfServiceId
      encData =  fromMaybe (EncDataBytes "")
      queueData = (,(encData immutableData_, encData userData_)) <$> linkId_
   in (rId, QueueRec {recipientKeys, rcvDhSecret, senderId, senderKey, queueMode, queueData, notifier, status, updatedAt, rcvServiceId})

mkNotifier :: (Maybe NotifierId, Maybe NtfPublicAuthKey, Maybe RcvNtfDhSecret) -> Maybe ServiceId -> Maybe NtfCreds
mkNotifier (Just notifierId, Just notifierKey, Just rcvNtfDhSecret) ntfServiceId =
  Just NtfCreds {notifierId, notifierKey, rcvNtfDhSecret, ntfServiceId}
mkNotifier _ _ = Nothing

serviceRecToRow :: ServiceRec -> (ServiceId, SMPServiceRole, X.CertificateChain, Binary ByteString, RoundedSystemTime)
serviceRecToRow ServiceRec {serviceId, serviceRole, serviceCert, serviceCertHash = XV.Fingerprint fp, serviceCreatedAt} =
  (serviceId, serviceRole, serviceCert, Binary fp, serviceCreatedAt)

rowToServiceRec :: (ServiceId, SMPServiceRole, X.CertificateChain, Binary ByteString, RoundedSystemTime) -> ServiceRec
rowToServiceRec (serviceId, serviceRole, serviceCert, Binary fp, serviceCreatedAt) =
  ServiceRec {serviceId, serviceRole, serviceCert, serviceCertHash = XV.Fingerprint fp, serviceCreatedAt}

setStatusDB :: StoreQueueClass q => Text -> PostgresQueueStore q -> q -> ServerEntityStatus -> ExceptT ErrorType IO () -> IO (Either ErrorType ())
setStatusDB op st sq status writeLog =
  withQueueRec sq op $ \q -> do
    assertUpdated $ withDB' op st $ \db ->
      DB.execute db "UPDATE msg_queues SET status = ? WHERE recipient_id = ? AND deleted_at IS NULL" (status, recipientId sq)
    atomically $ writeTVar (queueRec sq) $ Just q {status}
    writeLog

withQueueRec :: StoreQueueClass q => q -> Text -> (QueueRec -> ExceptT ErrorType IO a) -> IO (Either ErrorType a)
withQueueRec sq op action =
  withQueueLock sq op $ E.uninterruptibleMask_ $ runExceptT $ ExceptT (readQueueRecIO $ queueRec sq) >>= action

assertUpdated :: ExceptT ErrorType IO Int64 -> ExceptT ErrorType IO ()
assertUpdated = (>>= \n -> when (n == 0) (throwE AUTH))

withDB' :: Text -> PostgresQueueStore q -> (DB.Connection -> IO a) -> ExceptT ErrorType IO a
withDB' op st action = withDB op st $ fmap Right . action

withDB :: forall a q. Text -> PostgresQueueStore q -> (DB.Connection -> IO (Either ErrorType a)) -> ExceptT ErrorType IO a
withDB op st action =
  ExceptT $ E.try (withConnection (dbStore st) action) >>= either logErr pure
  where
    logErr :: E.SomeException -> IO (Either ErrorType a)
    logErr e = logError ("STORE: " <> err) $> Left (STORE err)
      where
        err = op <> ", withDB, " <> tshow e

withLog :: MonadIO m => Text -> PostgresQueueStore q -> (StoreLog 'WriteMode -> IO ()) -> m ()
withLog op PostgresQueueStore {dbStoreLog} = withLog_ op dbStoreLog
{-# INLINE withLog #-}

withLog_ :: MonadIO m => Text -> Maybe (StoreLog 'WriteMode) -> (StoreLog 'WriteMode -> IO ()) -> m ()
withLog_ op sl_ action =
  forM_ sl_ $ \sl -> liftIO $ action sl `catchAny` \e ->
    logWarn $ "STORE: " <> op <> ", withLog, " <> tshow e

handleDuplicate :: SqlError -> IO ErrorType
handleDuplicate e = case constraintViolation e of
  Just (UniqueViolation _) -> pure AUTH
  _ -> E.throwIO e

-- The orphan instances below are copy-pasted, but here they are defined specifically for PostgreSQL

instance ToField (NonEmpty C.APublicAuthKey) where toField = toField . Binary . smpEncode

instance FromField (NonEmpty C.APublicAuthKey) where fromField = blobFieldDecoder smpDecode

instance ToField SMPServiceRole where toField = toField . decodeLatin1 . smpEncode

instance FromField SMPServiceRole where fromField = fromTextField_ $ eitherToMaybe . smpDecode . encodeUtf8

instance ToField X.CertificateChain where toField = toField . Binary . smpEncode . C.encodeCertChain

instance FromField X.CertificateChain where fromField = blobFieldDecoder (parseAll C.certChainP)

#if !defined(dbPostgres)
instance ToField EntityId where toField (EntityId s) = toField $ Binary s

deriving newtype instance FromField EntityId

instance FromField QueueMode where fromField = fromTextField_ $ eitherToMaybe . smpDecode . encodeUtf8

instance ToField QueueMode where toField = toField . decodeLatin1 . smpEncode

instance ToField (C.DhSecret 'C.X25519) where toField = toField . Binary . C.dhBytes'

instance FromField (C.DhSecret 'C.X25519) where fromField = blobFieldDecoder strDecode

instance ToField C.APublicAuthKey where toField = toField . Binary . C.encodePubKey

instance FromField C.APublicAuthKey where fromField = blobFieldDecoder C.decodePubKey

instance ToField EncDataBytes where toField (EncDataBytes s) = toField (Binary s)

deriving newtype instance FromField EncDataBytes
#endif
