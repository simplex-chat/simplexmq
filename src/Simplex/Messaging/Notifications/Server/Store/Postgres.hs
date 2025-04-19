{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Notifications.Server.Store.Postgres where

import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Data.Bitraversable (bimapM)
import Data.ByteString.Char8 (ByteString)
import Data.Either (fromRight)
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Data.Time.Clock.System (SystemTime (..))
import Data.Word (Word16)
import Database.PostgreSQL.Simple (Binary (..), In (..), Only (..), Query, ToRow, (:.) (..))
import qualified Database.PostgreSQL.Simple as DB
import Database.PostgreSQL.Simple.FromField (FromField (..))
import Database.PostgreSQL.Simple.SqlQQ (sql)
import Database.PostgreSQL.Simple.ToField (ToField (..))
import Network.Socket (ServiceName)
import Simplex.Messaging.Agent.Store.AgentStore ()
import Simplex.Messaging.Agent.Store.Postgres (closeDBStore, createDBStore)
import Simplex.Messaging.Agent.Store.Postgres.Common
import Simplex.Messaging.Agent.Store.Postgres.DB (blobFieldDecoder, fromTextField_)
import Simplex.Messaging.Agent.Store.Shared (MigrationConfirmation (..))
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Store (NtfSTMStore (..))
import Simplex.Messaging.Notifications.Server.Store.Migrations
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Protocol (EntityId (..), EncNMsgMeta, ErrorType (..), NotifierId, NtfPrivateAuthKey, NtfPublicAuthKey, SMPServer, pattern SMPServer)
import Simplex.Messaging.Server.QueueStore (RoundedSystemTime, getSystemDate)
import Simplex.Messaging.Server.QueueStore.Postgres (handleDuplicate)
import Simplex.Messaging.Server.StoreLog (closeStoreLog, openWriteStoreLog)
import Simplex.Messaging.Server.StoreLog.Types
import Simplex.Messaging.Transport.Client (TransportHost)
import Simplex.Messaging.Util (eitherToMaybe, firstRow, tshow)
import System.Exit (exitFailure)
import System.IO (IOMode (..))
import Text.Hex (decodeHex)

data NtfPostgresStore = NtfPostgresStore
  { dbStore :: DBStore,
    dbStoreLog :: Maybe (StoreLog 'WriteMode),
    tokenNtfsTTL :: Int64
  }

data NtfPostgresStoreCfg = NtfPostgresStoreCfg
  { dbOpts :: DBOpts,
    dbStoreLogPath :: Maybe FilePath,
    confirmMigrations :: MigrationConfirmation,
    tokenNtfsTTL :: Int64
  }

data NtfTknData' = NtfTknData'
  { ntfTknId :: NtfTokenId,
    token :: DeviceToken,
    tknStatus :: NtfTknStatus,
    tknVerifyKey :: NtfPublicAuthKey,
    tknDhPrivKey :: C.PrivateKeyX25519,
    tknDhSecret :: C.DhSecretX25519,
    tknRegCode :: NtfRegCode,
    tknCronInterval :: Word16,
    tknUpdatedAt :: Maybe RoundedSystemTime
  }
  deriving (Show)

mkNtfTknData :: NtfTokenId -> NewNtfEntity 'Token -> C.PrivateKeyX25519 -> C.DhSecretX25519 -> NtfRegCode -> RoundedSystemTime -> NtfTknData'
mkNtfTknData ntfTknId (NewNtfTkn token tknVerifyKey _) tknDhPrivKey tknDhSecret tknRegCode ts =
  NtfTknData' {ntfTknId, token, tknStatus = NTRegistered, tknVerifyKey, tknDhPrivKey, tknDhSecret, tknRegCode, tknCronInterval = 0, tknUpdatedAt = Just ts}

data NtfSubData' = NtfSubData'
  { ntfSubId :: NtfSubscriptionId,
    tokenId :: NtfTokenId,
    smpQueue :: SMPQueueNtf,
    notifierKey :: NtfPrivateAuthKey,
    subStatus :: NtfSubStatus
  }
  deriving (Show)

data NtfEntityRec' (e :: NtfEntity) where
  NtfTkn' :: NtfTknData' -> NtfEntityRec' 'Token
  NtfSub' :: NtfSubData' -> NtfEntityRec' 'Subscription

newNtfDbStore :: NtfPostgresStoreCfg -> IO NtfPostgresStore
newNtfDbStore NtfPostgresStoreCfg {dbOpts, dbStoreLogPath, confirmMigrations, tokenNtfsTTL} = do
  dbStore <- either err pure =<< createDBStore dbOpts ntfServerMigrations confirmMigrations
  dbStoreLog <- mapM (openWriteStoreLog True) dbStoreLogPath
  pure NtfPostgresStore {dbStore, dbStoreLog, tokenNtfsTTL}
  where
    err e = do
      logError $ "STORE: newNtfStore, error opening PostgreSQL database, " <> tshow e
      exitFailure

closeNtfDbStore :: NtfPostgresStore -> IO ()
closeNtfDbStore NtfPostgresStore {dbStore, dbStoreLog} = do
  closeDBStore dbStore
  mapM_ closeStoreLog dbStoreLog

addNtfToken :: NtfPostgresStore -> NtfTknData' -> IO (Either ErrorType ())
addNtfToken st tkn =
  withDB "addNtfToken" st $ \db ->
    E.try (DB.execute db insertNtfTknQuery $ ntfTknToRow tkn)
      >>= bimapM handleDuplicate (\_ -> pure ())

insertNtfTknQuery :: Query
insertNtfTknQuery =
  [sql|
    INSERT INTO tokens
      (token_id, push_provider, push_provider_token, status, verify_key, dh_priv_key, dh_secret, reg_code, cron_interval, updated_at)
    VALUES (?,?,?,?,?,?,?,?,?,?)
  |]

replaceNtfToken :: NtfPostgresStore -> NtfTknData' -> IO (Either ErrorType ())
replaceNtfToken st NtfTknData' {ntfTknId, token = DeviceToken pp ppToken, tknStatus, tknRegCode = NtfRegCode regCode} =
  withDB "replaceNtfToken" st $ \db ->
    assertUpdated <$>
      DB.execute
        db
        [sql|
          UPDATE tokens
          SET push_provider = ?, push_provider_token = ?, status = ?, reg_code = ?
          WHERE token_id = ?
        |]
        (pp, Binary ppToken, tknStatus, Binary regCode, ntfTknId)

ntfTknToRow :: NtfTknData' -> NtfTknRow
ntfTknToRow NtfTknData' {ntfTknId, token, tknStatus, tknVerifyKey, tknDhPrivKey, tknDhSecret, tknRegCode, tknCronInterval, tknUpdatedAt} =
  let DeviceToken pp ppToken = token
      NtfRegCode regCode = tknRegCode
   in (ntfTknId, pp, Binary ppToken, tknStatus, tknVerifyKey, tknDhPrivKey, tknDhSecret, Binary regCode, tknCronInterval, tknUpdatedAt)

getNtfToken :: NtfPostgresStore -> NtfTokenId -> IO (Either ErrorType NtfTknData')
getNtfToken st tknId = getNtfToken_ st " WHERE token_id = ?" (Only tknId)

getNtfTokenRegistration :: NtfPostgresStore -> NewNtfEntity 'Token -> IO (Either ErrorType NtfTknData')
getNtfTokenRegistration st (NewNtfTkn (DeviceToken pp ppToken) tknVerifyKey _) =
  getNtfToken_ st " WHERE push_provider = ? AND push_provider_token = ? AND verify_key = ?" (pp, Binary ppToken, tknVerifyKey)

getNtfToken_ :: ToRow q => NtfPostgresStore -> Query -> q -> IO (Either ErrorType NtfTknData')
getNtfToken_ st cond params =
  withDB "getNtfToken" st $ \db -> runExceptT $ do
    tkn@NtfTknData' {ntfTknId} <-
      ExceptT $ firstRow rowToNtfTkn AUTH $
        DB.query db (ntfTknQuery <> cond) params
    ts <- liftIO getSystemDate
    liftIO $ void $ DB.execute db "UPDATE tokens SET updated_at = ? WHERE token_id = ?" (ts, ntfTknId)
    pure tkn

type NtfTknRow = (NtfTokenId, PushProvider, Binary ByteString, NtfTknStatus, NtfPublicAuthKey, C.PrivateKeyX25519, C.DhSecretX25519, Binary ByteString, Word16, Maybe RoundedSystemTime)

ntfTknQuery :: Query
ntfTknQuery =
  [sql|
    SELECT token_id, push_provider, push_provider_token, status, verify_key, dh_priv_key, dh_secret, reg_code, cron_interval, updated_at
    FROM tokens
  |]

rowToNtfTkn :: NtfTknRow -> NtfTknData'
rowToNtfTkn (ntfTknId, pp, Binary ppToken, tknStatus, tknVerifyKey, tknDhPrivKey, tknDhSecret, Binary regCode, tknCronInterval, tknUpdatedAt)  =
  let token = DeviceToken pp ppToken
      tknRegCode = NtfRegCode regCode
   in NtfTknData' {ntfTknId, token, tknStatus, tknVerifyKey, tknDhPrivKey, tknDhSecret, tknRegCode, tknCronInterval, tknUpdatedAt}

deleteNtfToken :: NtfPostgresStore -> NtfTokenId -> IO (Either ErrorType [(SMPServer, [NotifierId])])
deleteNtfToken st tknId =
  withDB "deleteNtfToken" st $ \db -> runExceptT $ do
    -- This SELECT obtains exclusive lock on token row and prevents any inserts
    -- into other tables for this token ID until the deletion completes.
    _ <- ExceptT $ firstRow (fromOnly @Int) AUTH $
      DB.query db "SELECT 1 FROM tokens WHERE token_id = ? FOR UPDATE" (Only tknId)
    subs <-
      liftIO $ map toServerSubs <$>
        DB.query
          db
          [sql|
            SELECT p.smp_host, p.smp_port, p.smp_keyhash,
              string_agg(sub.smp_notifier_id :: TEXT, ',') AS notifier_ids
            FROM smp_servers p
            JOIN subscriptions s ON s.smp_server_id = p.smp_server_id
            WHERE s.token_id = ?
            GROUP BY p.smp_host, p.smp_port, p.smp_keyhash;
          |]
          (Only tknId)
    subs <$ liftIO (DB.execute db "DELETE FROM tokens WHERE token_id = ?" (Only tknId))
  where
    toServerSubs :: SMPServerRow :. Only Text -> (SMPServer, [NotifierId])
    toServerSubs (srv :. Only nIdsStr) = (rowToSMPServer srv, parseByteaString nIdsStr)
    parseByteaString :: Text -> [NotifierId]
    parseByteaString s = mapMaybe (fmap EntityId . decodeHex . T.drop 2) $ T.splitOn "," s  -- drop 2 to remove "\\x"

type SMPServerRow = (NonEmpty TransportHost, ServiceName, C.KeyHash)

type SMPQueueNtfRow = (NonEmpty TransportHost, ServiceName, C.KeyHash, NotifierId)

rowToSMPServer :: SMPServerRow -> SMPServer
rowToSMPServer (host, port, kh) = SMPServer host port kh

smpServerToRow :: SMPServer -> SMPServerRow
smpServerToRow (SMPServer host port kh) = (host, port, kh)

smpQueueToRow :: SMPQueueNtf -> SMPQueueNtfRow
smpQueueToRow (SMPQueueNtf (SMPServer host port kh) nId) = (host, port, kh, nId)

rowToSMPQueue :: SMPQueueNtfRow -> SMPQueueNtf
rowToSMPQueue (host, port, kh, nId) = SMPQueueNtf (SMPServer host port kh) nId

updateTknCronInterval :: NtfPostgresStore -> NtfTokenId -> Word16 -> IO (Either ErrorType ())
updateTknCronInterval st tknId cronInt =
  withDB "updateTknCronInterval" st $ \db ->
    assertUpdated <$> DB.execute db "UPDATE tokens SET cron_interval = ? WHERE token_id = ?" (cronInt, tknId)

-- Reads servers that have subscriptions that need subscribing.
-- It is executed on server start, and it is supposed to crash on database error
getUsedSMPServers :: NtfPostgresStore -> IO [SMPServer]
getUsedSMPServers st = 
  withTransaction (dbStore st) $ \db ->
    map rowToSMPServer <$>
      DB.query
        db
        [sql|
          SELECT smp_host, smp_port, smp_keyhash
          FROM smp_servers
          WHERE EXISTS (SELECT 1 FROM subscriptions WHERE status IN ?)
        |]
        (Only (In [NSNew, NSPending, NSActive, NSInactive]))

-- TODO [ntfdb] this function should read all subscriptions for a given SMP server and stream them to action in batches of specified size
-- possibly, action can be called for each row and batching to be done outside

-- ntfShouldSubscribe should be used directly in DB
processNtfSubscriptions :: NtfPostgresStore -> SMPServer -> Int -> (NonEmpty NtfSubData' -> IO ()) -> IO ()
processNtfSubscriptions _st _smpServer _batchSize _action = undefined

findNtfSubscription :: NtfPostgresStore -> NtfTokenId -> SMPQueueNtf -> IO (Either ErrorType (NtfTknData', Maybe NtfSubData'))
findNtfSubscription st tknId q =
  withDB "findNtfSubscription" st $ \db -> runExceptT $ do
    r@(tkn, _) <-
      ExceptT $ firstRow (rowToNtfTknMaybeSub q) AUTH $
        DB.query
          db
          [sql|
            SELECT t.token_id, t.push_provider, t.push_provider_token, t.status, t.verify_key, t.dh_priv_key, t.dh_secret, t.reg_code, t.cron_interval, t.updated_at,
              s.subscription_id, s.smp_notifier_id, s.smp_notifier_key, s.status
            FROM tokens t
            LEFT JOIN subscriptions s ON s.token_id = t.token_id
            LEFT JOIN smp_servers p ON p.smp_server_id = s.smp_server_id
            WHERE t.token_id = ?
              AND (
                (p.smp_host = ? AND p.smp_port = ? AND p.smp_keyhash = ? AND s.smp_notifier_id = ?)
                OR s.smp_notifier_id IS NULL
              )
          |]          
          (Only tknId :. smpQueueToRow q)
    unless (allowNtfSubCommands $ tknStatus tkn) $ throwE AUTH
    pure r

getNtfSubscription :: NtfPostgresStore -> NtfSubscriptionId -> IO (Either ErrorType (NtfTknData', NtfSubData'))
getNtfSubscription st subId =
  withDB "getNtfSubscription" st $ \db -> runExceptT $ do
    r@(tkn, _) <-
      ExceptT $ firstRow rowToNtfTknSub AUTH $
        DB.query
          db
          [sql|
            SELECT t.token_id, t.push_provider, t.push_provider_token, t.status, t.verify_key, t.dh_priv_key, t.dh_secret, t.reg_code, t.cron_interval, t.updated_at,
              s.subscription_id, s.smp_notifier_id, s.smp_notifier_key, s.status,
              p.smp_host, p.smp_port, p.smp_keyhash
            FROM subscriptions s
            JOIN tokens t ON t.token_id = s.token_id
            JOIN smp_servers p ON p.smp_server_id = s.smp_server_id
            WHERE s.subscription_id = ?
          |]          
          (Only subId)
    unless (allowNtfSubCommands $ tknStatus tkn) $ throwE AUTH
    pure r

-- TODO [ntfdb] Currently we seem to reject commands for subscriptions when token is inactive (because of getActiveNtfToken).
-- Probably this needs to change - e.g., it can be subscription creation command,
-- or subscription deletion command, and these commands would permanently fail (?)
-- See comment at NtfTknStatus

type NtfSubRow = (NtfSubscriptionId, NotifierId, NtfPrivateAuthKey, NtfSubStatus)

type MaybeNtfSubRow = (Maybe NtfSubscriptionId, Maybe NotifierId, Maybe NtfPrivateAuthKey, Maybe NtfSubStatus)

rowToNtfTknSub :: NtfTknRow :. NtfSubRow :. SMPServerRow -> (NtfTknData', NtfSubData')
rowToNtfTknSub (tknRow :. (ntfSubId, nId, notifierKey, subStatus) :. srv)  =
  let tkn@NtfTknData' {ntfTknId = tokenId} = rowToNtfTkn tknRow
      smpQueue = SMPQueueNtf (rowToSMPServer srv) nId
   in (tkn, NtfSubData' {ntfSubId, tokenId, smpQueue, notifierKey, subStatus})

rowToNtfTknMaybeSub :: SMPQueueNtf -> NtfTknRow :. MaybeNtfSubRow -> (NtfTknData', Maybe NtfSubData')
rowToNtfTknMaybeSub (SMPQueueNtf srv _) (tknRow :. subRow)  =
  let tkn@NtfTknData' {ntfTknId = tokenId} = rowToNtfTkn tknRow
      sub_ = case subRow of
        (Just ntfSubId, Just nId, Just notifierKey, Just subStatus) ->
          Just NtfSubData' {ntfSubId, tokenId, smpQueue = SMPQueueNtf srv nId, notifierKey, subStatus}
        _ -> Nothing
   in (tkn, sub_)

mkNtfSubData :: NtfSubscriptionId -> NewNtfEntity 'Subscription -> NtfSubData'
mkNtfSubData ntfSubId (NewNtfSub tokenId smpQueue notifierKey) =
  NtfSubData' {ntfSubId, tokenId, smpQueue, subStatus = NSNew, notifierKey}

updateTknStatus :: NtfPostgresStore -> NtfTknData' -> NtfTknStatus -> IO (Either ErrorType ())
updateTknStatus st NtfTknData' {ntfTknId} status =
  withDB "updateTknStatus" st $ \db ->
    assertUpdated <$> DB.execute db "UPDATE tokens SET status = ? WHERE token_id = ?" (status, ntfTknId)

-- this is updateTknStatus combined with removeInactiveTokenRegistrations
setTknStatusActive :: NtfPostgresStore -> NtfTknData' -> IO (Either ErrorType [NtfTokenId])
setTknStatusActive st NtfTknData' {ntfTknId, token = DeviceToken pp ppToken} =
  withDB "setTknStatusActive" st $ \db -> runExceptT $ do
    ExceptT $ assertUpdated <$> DB.execute db "UPDATE tokens SET status = ? WHERE token_id = ?" (NTActive, ntfTknId)
    -- this removes other instances of the same token, e.g. because of repeated token registration attempts
    liftIO $
      map fromOnly <$>
        DB.query
          db
          [sql|
            DELETE FROM tokens
            WHERE push_provider = ? AND push_provider_token = ? AND token_id != ?
            RETURNING token_id
          |]
          (pp, Binary ppToken, ntfTknId)

addNtfSubscription :: NtfPostgresStore -> NtfSubData' -> IO (Either ErrorType Bool)
addNtfSubscription st sub@NtfSubData' {smpQueue = SMPQueueNtf srv _} =
  withDB "addNtfSubscription" st $ \db -> runExceptT $ do
    srvId :: Int64 <- ExceptT $ upsertServer db
    liftIO $ (> 0) <$> DB.execute db insertNtfSubQuery (ntfSubToRow srvId sub)
  where
    -- SELECT ... - to avoid writes in case row exists, this is the most common scenario for this table.
    -- COALESCE prevents evaluation of INSERT when row exists.
    -- ON CONFLICT ... UPDATE ... RETURNING - to return row ID created by a concurrent transaction after SELECT.
    -- no-op update instead of DO NOTHING - for RETURNING to work when row exists.
    upsertServer db =
      firstRow fromOnly (STORE "error inserting SMP server when adding subscription") $
        DB.query
          db
          [sql|
            WITH existing AS (
              SELECT smp_server_id
              FROM smp_servers
              WHERE smp_host = ? AND smp_port = ? AND smp_keyhash = ?
            ),
            inserted AS (
              INSERT INTO smp_servers (smp_host, smp_port, smp_keyhash) VALUES (?, ?, ?)
              ON CONFLICT (smp_host, smp_port, smp_keyhash)
              DO UPDATE SET smp_host = EXCLUDED.smp_host
              RETURNING smp_server_id
            )
            SELECT COALESCE(
              (SELECT smp_server_id FROM existing),
              (SELECT smp_server_id FROM inserted)
            ) AS smp_server_id;
          |]
          (smpServerToRow srv :. smpServerToRow srv)
    insertNtfSubQuery =
      [sql|
        INSERT INTO subscriptions
          (subscription_id, token_id, smp_server_id, smp_notifier_id, smp_notifier_key, status)
        VALUES (?,?,?,?,?,?)
        ON CONFLICT (smp_server_id, smp_notifier_id) DO NOTHING
      |]
    ntfSubToRow srvId NtfSubData' {ntfSubId, tokenId, smpQueue = SMPQueueNtf _ nId, notifierKey, subStatus} =
      (ntfSubId, tokenId, srvId, nId, notifierKey, subStatus)

deleteNtfSubscription :: NtfPostgresStore -> NtfSubscriptionId -> IO (Either ErrorType ())
deleteNtfSubscription st subId =
  withDB "deleteNtfSubscription" st $ \db ->
    assertUpdated <$> DB.execute db "DELETE FROM subscriptions WHERE subscription_id = ?" (Only subId)

updateSrvSubStatus :: NtfPostgresStore -> SMPQueueNtf -> NtfSubStatus -> IO (Either ErrorType ())
updateSrvSubStatus st q status =
  withDB "updateSrvSubStatus" st $ \db ->
    assertUpdated <$>
      DB.execute
      db
      [sql|
        UPDATE subscriptions s
        SET status = ?
        FROM smp_servers p
        WHERE p.smp_server_id = s.smp_server_id
          AND p.smp_host = ? AND p.smp_port = ? AND p.smp_keyhash = ? AND s.smp_notifier_id = ?
      |]
      (Only status :. smpQueueToRow q)

batchUpdateSrvSubStatus :: NtfPostgresStore -> SMPServer -> NonEmpty NotifierId -> NtfSubStatus -> IO Int64
batchUpdateSrvSubStatus st srv nIds status =
  batchUpdateStatus_ st srv $ \srvId -> L.toList $ L.map (status,srvId,) nIds

batchUpdateSrvSubStatuses :: NtfPostgresStore -> SMPServer -> NonEmpty (NotifierId, NtfSubStatus) -> IO Int64
batchUpdateSrvSubStatuses st srv subs =
  batchUpdateStatus_ st srv $ \srvId -> L.toList $ L.map (\(nId, status) -> (status, srvId, nId)) subs

batchUpdateStatus_ :: NtfPostgresStore -> SMPServer -> (Int64 -> [(NtfSubStatus, Int64, NotifierId)]) -> IO Int64
batchUpdateStatus_ st srv mkParams =
  fmap (fromRight (-1)) $ withDB "batchUpdateStatus_" st $ \db -> runExceptT $ do
    srvId :: Int64 <- ExceptT $ getSMPServerId db
    let params = mkParams srvId
    liftIO $ forM_ params $ void . DB.execute db "UPDATE subscriptions SET status = ? WHERE smp_server_id = ? AND smp_notifier_id = ?"
    pure $ fromIntegral $ length params
  where
    getSMPServerId db =
      firstRow fromOnly AUTH $
        DB.query
          db
          [sql|
            SELECT smp_server_id
            FROM smp_servers
            WHERE smp_host = ? AND smp_port = ? AND smp_keyhash = ?
          |]
          (smpServerToRow srv)

batchUpdateSubStatus :: NtfPostgresStore -> NonEmpty NtfSubData' -> NtfSubStatus -> IO Int64
batchUpdateSubStatus st subs status =
  fmap (fromRight (-1)) $ withDB' "batchUpdateSubStatus" st $ \db -> do
    let params = L.toList $ L.map (\s -> (status, ntfSubId s)) subs
    forM_ params $ void . DB.execute db "UPDATE subscriptions SET status = ? WHERE subscription_id = ?"
    pure $ fromIntegral $ length params

addTokenLastNtf :: NtfPostgresStore -> PNMessageData -> IO (Either ErrorType (NtfTknData', NonEmpty PNMessageData))
addTokenLastNtf st newNtf =
  withDB "addTokenLastNtf" st $ \db -> runExceptT $ do
    (tkn@NtfTknData' {ntfTknId = tId}, sId) <-
      ExceptT $ firstRow toTokenSubId AUTH $
        DB.query
          db
          [sql|
            SELECT t.token_id, t.push_provider, t.push_provider_token, t.status, t.verify_key, t.dh_priv_key, t.dh_secret, t.reg_code, t.cron_interval, t.updated_at,
              s.subscription_id
            FROM tokens t
            JOIN subscriptions s ON s.token_id = t.token_id
            JOIN smp_servers p ON p.smp_server_id = s.smp_server_id
            WHERE p.smp_host = ? AND p.smp_port = ? AND p.smp_keyhash = ? AND s.smp_notifier_id = ?
            FOR UPDATE OF t, s
          |]
          (smpQueueToRow q)
    unless (allowNtfSubCommands $ tknStatus tkn) $ throwE AUTH
    lastNtfs_ <-
      liftIO $ map toNtf <$>
        DB.query
          db
            [sql|
              WITH new AS (
                INSERT INTO last_notifications(token_id, subscription_id, sent_at, nmsg_nonce, nmsg_data)
                VALUES (?,?,?,?,?)
                ON CONFLICT (token_id, subscription_id)
                DO UPDATE SET
                  sent_at = EXCLUDED.sent_at,
                  nmsg_nonce = EXCLUDED.nmsg_nonce,
                  nmsg_data = EXCLUDED.nmsg_data
              ),
              last AS (
                SELECT token_ntf_id, subscription_id, sent_at, nmsg_nonce, nmsg_data
                FROM last_notifications
                WHERE token_id = ?
                ORDER BY token_ntf_id DESC
                LIMIT ?
              ),
              delete AS (
                DELETE FROM last_notifications
                WHERE token_id = ?
                  AND token_ntf_id < (SELECT min(token_ntf_id) FROM last)
              )
              SELECT p.smp_host, p.smp_port, p.smp_keyhash, s.smp_notifier_id,
                l.sent_at, l.nmsg_nonce, l.nmsg_data
              FROM last l
              JOIN subscriptions s ON s.subscription_id = l.subscription_id
              JOIN smp_servers p ON p.smp_server_id = s.smp_server_id
              ORDER BY token_ntf_id DESC
            |]
            (tId, sId, ntfTs, nmsgNonce, Binary encNMsgMeta, tId, maxNtfs, tId)
    let lastNtfs = fromMaybe (newNtf :| []) (L.nonEmpty lastNtfs_)
    pure (tkn, lastNtfs)
  where
    maxNtfs = 6 :: Int
    PNMessageData {smpQueue = q, ntfTs, nmsgNonce, encNMsgMeta} = newNtf
    toTokenSubId :: NtfTknRow :. Only NtfSubscriptionId -> (NtfTknData', NtfSubscriptionId)
    toTokenSubId (tknRow :. Only sId) = (rowToNtfTkn tknRow, sId)
    toNtf :: SMPQueueNtfRow :. (SystemTime, C.CbNonce, Binary EncNMsgMeta) -> PNMessageData
    toNtf (qRow :. (ts, nonce, Binary encMeta)) =
      PNMessageData {smpQueue = rowToSMPQueue qRow, ntfTs = ts, nmsgNonce = nonce, encNMsgMeta = encMeta}

-- storeTokenLastNtf -- is it needed?

-- -- This function is expected to be called after store log is read,
-- -- as it checks for token existence when adding last notification.
-- storeTokenLastNtf :: NtfStore -> NtfTokenId -> PNMessageData -> IO ()
-- storeTokenLastNtf (NtfStore {tokens, tokenLastNtfs}) tknId ntf = do
--   TM.lookupIO tknId tokenLastNtfs >>= atomically . maybe newTokenLastNtfs (`modifyTVar'` (ntf <|))
--   where
--     newTokenLastNtfs = TM.lookup tknId tokenLastNtfs >>= maybe insertForExistingToken (`modifyTVar'` (ntf <|))
--     insertForExistingToken =
--       whenM (TM.member tknId tokens) $
--         TM.insertM tknId (newTVar [ntf]) tokenLastNtfs

-- TODO [ntfdb]
importNtfSTMStore :: NtfPostgresStore -> NtfSTMStore -> IO (Int, Int, Int)
importNtfSTMStore _st stmStore = do
  _tokens <- readTVarIO $ tokens stmStore
  _subs <- readTVarIO $ subscriptions stmStore
  _ntfs <- readTVarIO $ tokenLastNtfs stmStore
  pure (0, 0, 0)

exportNtfDbStore :: NtfPostgresStore -> FilePath -> IO (Int, Int, Int)
exportNtfDbStore _st storeLogFilePath = do
  _sl <- openWriteStoreLog False storeLogFilePath
  undefined

withDB' :: String -> NtfPostgresStore -> (DB.Connection -> IO a) -> IO (Either ErrorType a)
withDB' op st action = withDB op st $ fmap Right . action

-- TODO [ntfdb] withTransaction?
-- also check SMP server too
withDB :: forall a. String -> NtfPostgresStore -> (DB.Connection -> IO (Either ErrorType a)) -> IO (Either ErrorType a)
withDB op st action =
  E.try (withTransaction (dbStore st) action) >>= either logErr pure
  where
    logErr :: E.SomeException -> IO (Either ErrorType a)
    logErr e = logError ("STORE: " <> T.pack err) $> Left (STORE err)
      where
        err = op <> ", withDB, " <> show e

assertUpdated :: Int64 -> Either ErrorType ()
assertUpdated 0 = Left AUTH
assertUpdated _ = Right ()

-- SystemTime instances round to a second, as message time everywhere in transmission flow is rounded to second
instance FromField SystemTime where fromField f = fmap (`MkSystemTime` 0) . fromField f

instance ToField SystemTime where toField = toField . systemSeconds

#if !defined(dbPostgres)
instance FromField PushProvider where fromField = fromTextField_ $ eitherToMaybe . strDecode . encodeUtf8

instance ToField PushProvider where toField = toField . decodeLatin1 . strEncode

instance FromField NtfTknStatus where fromField = blobFieldDecoder $ parseAll smpP

instance ToField NtfTknStatus where toField = toField . Binary . smpEncode

instance FromField (C.PrivateKey 'C.X25519) where fromField = blobFieldDecoder C.decodePrivKey

instance ToField (C.PrivateKey 'C.X25519) where toField = toField . Binary . C.encodePrivKey

instance FromField C.APrivateAuthKey where fromField = blobFieldDecoder C.decodePrivKey

instance ToField C.APrivateAuthKey where toField = toField . Binary . C.encodePrivKey

instance FromField (NonEmpty TransportHost) where fromField = fromTextField_ $ eitherToMaybe . strDecode . encodeUtf8

instance ToField (NonEmpty TransportHost) where toField = toField . decodeLatin1 . strEncode

instance FromField C.KeyHash where fromField = blobFieldDecoder $ parseAll strP

instance ToField C.KeyHash where toField = toField . Binary . strEncode

instance FromField NtfSubStatus where fromField = blobFieldDecoder $ parseAll smpP

instance ToField NtfSubStatus where toField = toField . Binary . smpEncode

instance FromField C.CbNonce where fromField = blobFieldDecoder $ parseAll smpP

instance ToField C.CbNonce where toField = toField . Binary . smpEncode
#endif
