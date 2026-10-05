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
    rowToQueueRec,
    withLog_,
    withDB,
    withDB',
    assertUpdated,
    renderField,
  )
where

import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Data.ByteString.Builder (Builder)
import qualified Data.ByteString.Builder as BB
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Lazy as LB
import Data.Bitraversable (bimapM)
import Data.Either (fromRight)
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List (foldl', intersperse, partition)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes, fromMaybe)
import qualified Data.Set as S
import Data.Text (Text)
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
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
import Simplex.Messaging.Agent.Store.Postgres.DB (blobFieldDecoder, fromTextField_)
import Simplex.Messaging.Agent.Store.Shared (MigrationConfig (..))
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
import Simplex.Messaging.SystemTime
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (SMPServiceRole (..))
import Simplex.Messaging.Util (eitherToMaybe, firstRow, maybeFirstRow, maybeFirstRow', tshow, (<$$>), ($>>=))
import System.Exit (exitFailure)
import System.IO (IOMode (..), hFlush, stdout)
import UnliftIO.STM

#if !defined(dbPostgres)
import Simplex.Messaging.Encoding.String
#endif

data PostgresQueueStore q = PostgresQueueStore
  { dbStore :: DBStore,
    dbStoreLog :: Maybe (StoreLog 'WriteMode),
    serviceLocks :: TMap CertFingerprint Lock,
    deletedTTL :: Int64
  }

instance StoreQueueClass q => QueueStoreClass q (PostgresQueueStore q) where
  type QueueStoreCfg (PostgresQueueStore q) = PostgresStoreCfg

  newQueueStore :: PostgresStoreCfg -> IO (PostgresQueueStore q)
  newQueueStore PostgresStoreCfg {dbOpts, dbStoreLogPath, confirmMigrations, deletedTTL} = do
    dbStore <- either err pure =<< createDBStore dbOpts serverMigrations (MigrationConfig confirmMigrations Nothing)
    dbStoreLog <- mapM (openWriteStoreLog True) dbStoreLogPath
    serviceLocks <- TM.emptyIO
    pure PostgresQueueStore {dbStore, dbStoreLog, serviceLocks, deletedTTL}
    where
      err e = do
        logError $ "STORE: newQueueStore, error opening PostgreSQL database, " <> tshow e
        exitFailure

  closeQueueStore :: PostgresQueueStore q -> IO ()
  closeQueueStore PostgresQueueStore {dbStore, dbStoreLog} = do
    closeDBStore dbStore
    mapM_ closeStoreLog dbStoreLog

  compactQueues :: PostgresQueueStore q -> IO Int64
  compactQueues st@PostgresQueueStore {deletedTTL} = do
    old <- subtract deletedTTL . systemSeconds <$> liftIO getSystemTime
    fmap (fromRight 0) $ runExceptT $ withDB' "removeDeletedQueues" st $ \db ->
      DB.execute db "DELETE FROM msg_queues WHERE deleted_at < ?" (Only old)

  getEntityCounts :: PostgresQueueStore q -> IO EntityCounts
  getEntityCounts st =
    withTransaction (dbStore st) $ \db -> do
      (queueCount, notifierCount, rcvServiceCount, ntfServiceCount, rcvServiceQueuesCount, ntfServiceQueuesCount) : _ <-
        DB.query
          db
          [sql|
            SELECT
              -- estimate via reltuples to avoid a full heap scan on every scrape
              (SELECT GREATEST(reltuples, 0)::bigint FROM pg_class WHERE oid = 'msg_queues'::regclass) AS queue_count,
              (SELECT COUNT(1) FROM msg_queues WHERE deleted_at IS NULL AND notifier_id IS NOT NULL) AS notifier_count,
              (SELECT COUNT(1) FROM services WHERE service_role = ?) AS rcv_service_count,
              (SELECT COUNT(1) FROM services WHERE service_role = ?) AS ntf_service_count,
              (SELECT COUNT(1) FROM msg_queues WHERE rcv_service_id IS NOT NULL AND deleted_at IS NULL) AS rcv_service_queues_count,
              (SELECT COUNT(1) FROM msg_queues WHERE ntf_service_id IS NOT NULL AND deleted_at IS NULL) AS ntf_service_queues_count
          |]
          (SRMessaging, SRNotifier)
      pure EntityCounts {queueCount, notifierCount, rcvServiceCount, ntfServiceCount, rcvServiceQueuesCount, ntfServiceQueuesCount}

  -- this implementation relies on unique constraints in the database to prevent duplicate IDs.
  addQueue_ :: PostgresQueueStore q -> (RecipientId -> QueueRec -> IO q) -> RecipientId -> QueueRec -> IO (Either ErrorType q)
  addQueue_ st mkQ rId qr = do
    sq <- mkQ rId qr
    E.uninterruptibleMask_ $ runExceptT $ do
      void $ withDB "addQueue_" st $ \db ->
        E.try (DB.execute db insertQueueQuery $ queueRecToRow (rId, qr))
          >>= bimapM handleDuplicate pure
      withLog "addStoreQueue" st $ \s -> logCreateQueue s rId qr
      pure sq

  getQueue_ :: QueueParty p => PostgresQueueStore q -> (RecipientId -> QueueRec -> IO q) -> SParty p -> QueueId -> IO (Either ErrorType q)
  getQueue_ st mkQ party qId = case party of
    SRecipient -> loadQueue " WHERE recipient_id = ?"
    SSender -> loadQueue " WHERE sender_id = ?"
    SSenderLink -> loadQueue " WHERE link_id = ?"
    SNotifier -> loadQueue " WHERE notifier_id = ?"
    where
      loadQueue condition = E.uninterruptibleMask_ $ runExceptT $ do
        (rId, qRec) <- withDB "getQueue_" st $ \db -> firstRow rowToQueueRec AUTH $
          DB.query db (queueRecQuery <> condition <> " AND deleted_at IS NULL") (Only qId)
        liftIO $ mkQ rId qRec

  getQueues_ :: forall p. BatchParty p => PostgresQueueStore q -> (RecipientId -> QueueRec -> IO q) -> SParty p -> [QueueId] -> IO [Either ErrorType q]
  getQueues_ st mkQ party qIds
    | null qIds = pure []
    | otherwise = E.uninterruptibleMask_ $ case party of
        SRecipient -> loadQueues " WHERE recipient_id IN ?" $ \(rId, qRec) ->
          Just . (rId,) <$> mkQ rId qRec
        SNotifier -> loadQueues " WHERE notifier_id IN ?" $ \(rId, qRec) ->
          forM (notifier qRec) $ \NtfCreds {notifierId = nId} -> (nId,) <$> mkQ rId qRec
    where
      loadQueues :: Query -> ((RecipientId, QueueRec) -> IO (Maybe (QueueId, q))) -> IO [Either ErrorType q]
      loadQueues cond mkQueue' = do
        qs_ <-
          runExceptT $ fmap M.fromList $
            withDB' "getQueues_" st (\db -> DB.query db (queueRecQuery <> cond <> " AND deleted_at IS NULL") (Only (In qIds)))
              >>= liftIO . fmap catMaybes . mapM (mkQueue' . rowToQueueRec)
        pure $ map (\qId -> maybe (Left AUTH) Right . M.lookup qId =<< qs_) qIds

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
    withQueueRec sq $ \q -> case queueData q of
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
    withQueueRec sq $ \q -> case queueData q of
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
    withQueueRec sq $ \q -> do
      verify q
      assertUpdated $ withDB' "secureQueue" st $ \db ->
        DB.execute db "UPDATE msg_queues SET sender_key = ? WHERE recipient_id = ? AND deleted_at IS NULL AND (sender_key IS NULL OR sender_key = ?)" (sKey, rId, sKey)
      atomically $ writeTVar (queueRec sq) $ Just q {senderKey = Just sKey}
      withLog "secureQueue" st $ \s -> logSecureQueue s rId sKey
    where
      rId = recipientId sq
      verify q = case senderKey q of
        Just k | sKey /= k -> throwE AUTH
        _ -> pure ()

  updateKeys :: PostgresQueueStore q -> q -> NonEmpty RcvPublicAuthKey -> IO (Either ErrorType ())
  updateKeys st sq rKeys =
    withQueueRec sq $ \q -> do
      assertUpdated $ withDB' "updateKeys" st $ \db ->
        DB.execute db "UPDATE msg_queues SET recipient_keys = ? WHERE recipient_id = ? AND deleted_at IS NULL" (rKeys, rId)
      atomically $ writeTVar (queueRec sq) $ Just q {recipientKeys = rKeys}
      withLog "updateKeys" st $ \s -> logUpdateKeys s rId rKeys
    where
      rId = recipientId sq

  addQueueNotifier :: PostgresQueueStore q -> q -> NtfCreds -> IO (Either ErrorType (Maybe NtfCreds))
  addQueueNotifier st sq ntfCreds@NtfCreds {notifierId = nId, notifierKey, rcvNtfDhSecret} =
    withQueueRec sq $ \q -> do
      assertUpdated $ withDB "addQueueNotifier" st $ \db ->
        E.try (update db) >>= bimapM handleDuplicate pure
      let !q' = q {notifier = Just ntfCreds}
      atomically $ writeTVar (queueRec sq) $ Just q'
      withLog "addQueueNotifier" st $ \s -> logAddNotifier s rId ntfCreds
      pure $ notifier q
    where
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
    withQueueRec sq $ \q ->
      forM (notifier q) $ \nc -> do
        assertUpdated $ withDB' "deleteQueueNotifier" st update
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

  updateQueueTime :: PostgresQueueStore q -> q -> SystemDate -> IO (Either ErrorType QueueRec)
  updateQueueTime st sq t =
    withQueueRec sq $ \q@QueueRec {updatedAt} ->
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

  deleteStoreQueue :: PostgresQueueStore q -> q -> IO (Either ErrorType QueueRec)
  deleteStoreQueue st sq = E.uninterruptibleMask_ $ runExceptT $ do
    q <- ExceptT $ readQueueRecIO qr
    RoundedSystemTime ts <- liftIO getSystemDate
    assertUpdated $ withDB' "deleteStoreQueue" st $ \db ->
      DB.execute db "UPDATE msg_queues SET deleted_at = ? WHERE recipient_id = ? AND deleted_at IS NULL" (ts, rId)
    atomically $ writeTVar qr Nothing
    withLog "deleteStoreQueue" st (`logDeleteQueue` rId)
    pure q
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
  setQueueService st sq party serviceId = withQueueRec sq $ \q -> case party of
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

  setQueueServices :: (PartyI p, ServiceParty p) => PostgresQueueStore q -> SParty p -> Maybe ServiceId -> [q] -> IO (Either ErrorType (M.Map RecipientId (Either ErrorType ())))
  setQueueServices _ _ _ [] = pure $ Right M.empty
  setQueueServices st party serviceId qs = E.uninterruptibleMask_ $ runExceptT $ do
    updated <- S.fromList <$> withDB' "setQueueServices" st (\db ->
      map fromOnly <$> DB.query db updateQuery (serviceId, In (map recipientId qs)))
    results <- liftIO $ forM qs $ \sq -> do
      let rId = recipientId sq
      (rId,) <$> if S.member rId updated
        then readQueueRecIO (queueRec sq) $>>= \q -> do
          atomically $ writeTVar (queueRec sq) $ Just $ updateRec q
          withLog "setQueueServices" st $ \sl -> logQueueService sl rId party serviceId
          pure $ Right ()
        else pure $ Left AUTH
    pure $ M.fromList results
    where
      updateQuery = case party of
        SRecipientService ->
          "UPDATE msg_queues SET rcv_service_id = ? WHERE recipient_id IN ? AND deleted_at IS NULL RETURNING recipient_id"
        SNotifierService ->
          "UPDATE msg_queues SET ntf_service_id = ? WHERE recipient_id IN ? AND notifier_id IS NOT NULL AND deleted_at IS NULL RETURNING recipient_id"
      updateRec q = case party of
        SRecipientService -> q {rcvServiceId = serviceId}
        SNotifierService -> case notifier q of
          Just nc -> q {notifier = Just nc {ntfServiceId = serviceId}}
          Nothing -> q

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

  getServiceQueueCountHash :: (PartyI p, ServiceParty p) => PostgresQueueStore q -> SParty p -> ServiceId -> IO (Either ErrorType (Int64, IdsHash))
  getServiceQueueCountHash st party serviceId =
    E.uninterruptibleMask_ $ runExceptT $ withDB' "getServiceQueueCountHash" st $ \db ->
      maybeFirstRow' (0, mempty) id $
        DB.query db ("SELECT queue_count, queue_ids_hash FROM services WHERE service_id = ? AND service_role = ?") (serviceId, partyServiceRole party)

batchInsertServices :: [STMService] -> PostgresQueueStore q -> IO Int64
batchInsertServices services' toStore =
  withTransaction (dbStore toStore) $ \db ->
    DB.executeMany db insertServiceQuery $ map (serviceRecToRow . serviceRec) services'

batchInsertQueues :: StoreQueueClass q => Bool -> M.Map RecipientId q -> PostgresQueueStore q' -> IO Int64
batchInsertQueues tty queues toStore = do
  qs <- catMaybes <$> mapM (\(rId, q) -> (rId,) <$$> readTVarIO (queueRec q)) (M.assocs queues)
  putStrLn $ "Importing " <> show (length qs) <> " queues..."
  let st = dbStore toStore
  count <-
    withTransaction st $ \db -> do
      DB.copy_
        db
        [sql|
          COPY msg_queues (recipient_id, recipient_keys, rcv_dh_secret, sender_id, sender_key, queue_mode, notifier_id, notifier_key, rcv_ntf_dh_secret, ntf_service_id, status, updated_at, link_id, rcv_service_id, fixed_data, user_data)
          FROM STDIN WITH (FORMAT CSV)
        |]
      mapM_ (putQueue db) (zip [1..] qs)
      DB.putCopyEnd db
  Only qCnt : _ <- withTransaction st (`DB.query_` "SELECT count(*) FROM msg_queues")
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

foldServiceRecs :: Monoid a => PostgresQueueStore q -> (ServiceRec -> IO a) -> IO a
foldServiceRecs st f =
  withTransaction (dbStore st) $ \db ->
    DB.fold_ db "SELECT service_id, service_role, service_cert, service_cert_hash, created_at FROM services" mempty $
      \ !acc -> fmap (acc <>) . f . rowToServiceRec

foldQueueRecs :: Monoid a => Bool -> Bool -> PostgresQueueStore q -> ((RecipientId, QueueRec) -> IO a) -> IO a
foldQueueRecs withData tty st f = do
  (n, r) <- withTransaction (dbStore st) $ \db ->
    foldRecs db (0 :: Int, mempty) $ \(i, acc) qr -> do
      r <- f qr
      let !i' = i + 1
          !acc' = acc <> r
      when (tty && i' `mod` 100000 == 0) $ putStr (progress i' <> "\r") >> hFlush stdout
      pure (i', acc')
  when tty $ putStrLn $ progress n
  pure r
  where
    foldRecs db acc f'
      | withData = DB.fold_ db (queueRecQueryWithData <> cond) acc $ \acc' -> f' acc' . rowToQueueRecWithData
      | otherwise = DB.fold_ db (queueRecQuery <> cond) acc $ \acc' -> f' acc' . rowToQueueRec
    cond = " WHERE deleted_at IS NULL ORDER BY recipient_id ASC"
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
    ServerEntityStatus, Maybe SystemDate, Maybe LinkId, Maybe ServiceId
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

serviceRecToRow :: ServiceRec -> (ServiceId, SMPServiceRole, X.CertificateChain, Binary ByteString, SystemDate)
serviceRecToRow ServiceRec {serviceId, serviceRole, serviceCert, serviceCertHash = XV.Fingerprint fp, serviceCreatedAt} =
  (serviceId, serviceRole, serviceCert, Binary fp, serviceCreatedAt)

rowToServiceRec :: (ServiceId, SMPServiceRole, X.CertificateChain, Binary ByteString, SystemDate) -> ServiceRec
rowToServiceRec (serviceId, serviceRole, serviceCert, Binary fp, serviceCreatedAt) =
  ServiceRec {serviceId, serviceRole, serviceCert, serviceCertHash = XV.Fingerprint fp, serviceCreatedAt}

setStatusDB :: StoreQueueClass q => Text -> PostgresQueueStore q -> q -> ServerEntityStatus -> ExceptT ErrorType IO () -> IO (Either ErrorType ())
setStatusDB op st sq status writeLog =
  withQueueRec sq $ \q -> do
    assertUpdated $ withDB' op st $ \db ->
      DB.execute db "UPDATE msg_queues SET status = ? WHERE recipient_id = ? AND deleted_at IS NULL" (status, recipientId sq)
    atomically $ writeTVar (queueRec sq) $ Just q {status}
    writeLog

withQueueRec :: StoreQueueClass q => q -> (QueueRec -> ExceptT ErrorType IO a) -> IO (Either ErrorType a)
withQueueRec sq action =
  E.uninterruptibleMask_ $ runExceptT $ ExceptT (readQueueRecIO $ queueRec sq) >>= action

assertUpdated :: ExceptT ErrorType IO Int64 -> ExceptT ErrorType IO ()
assertUpdated = (>>= \n -> when (n == 0) (throwE AUTH))

withDB' :: Text -> PostgresQueueStore q -> (DB.Connection -> IO a) -> ExceptT ErrorType IO a
withDB' op st action = withDB op st $ fmap Right . action

withDB :: forall a q. Text -> PostgresQueueStore q -> (DB.Connection -> IO (Either ErrorType a)) -> ExceptT ErrorType IO a
withDB op st action =
  ExceptT $ E.try (withTransaction (dbStore st) action) >>= either logErr pure
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

#if !defined(dbPostgres)
instance ToField EntityId where toField (EntityId s) = toField $ Binary s

deriving newtype instance FromField EntityId

instance FromField QueueMode where fromField = fromTextField_ $ eitherToMaybe . smpDecode . encodeUtf8

instance ToField QueueMode where toField = toField . decodeLatin1 . smpEncode

instance ToField (C.DhSecret 'C.X25519) where toField = toField . Binary . C.dhBytes'

instance FromField (C.DhSecret 'C.X25519) where fromField = blobFieldDecoder strDecode

instance ToField C.APublicAuthKey where toField = toField . Binary . C.encodePubKey

instance FromField C.APublicAuthKey where fromField = blobFieldDecoder C.decodePubKey

instance ToField IdsHash where toField (IdsHash s) = toField (Binary s)

deriving newtype instance FromField IdsHash

instance ToField EncDataBytes where toField (EncDataBytes s) = toField (Binary s)

deriving newtype instance FromField EncDataBytes

deriving newtype instance ToField (RoundedSystemTime t)

deriving newtype instance FromField (RoundedSystemTime t)

instance ToField X.CertificateChain where toField = toField . Binary . smpEncode . C.encodeCertChain

instance FromField X.CertificateChain where fromField = blobFieldDecoder (parseAll C.certChainP)
#endif
