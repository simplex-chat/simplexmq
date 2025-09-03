{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fno-warn-orphans -fno-warn-ambiguous-fields #-}

module Simplex.Messaging.Notifications.Server.Store.Postgres where

import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Data.Bitraversable (bimapM)
import qualified Data.ByteString.Base64.URL as B64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Containers.ListUtils (nubOrd)
import Data.Either (fromRight)
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List (findIndex, foldl')
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.System (SystemTime (..), systemToUTCTime, utcToSystemTime)
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
import Simplex.Messaging.Agent.Store.Postgres.DB (fromTextField_)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Store (NtfSTMStore (..), NtfSubData (..), NtfTknData (..), TokenNtfMessageRecord (..), ntfSubServer)
import Simplex.Messaging.Notifications.Server.Store.Migrations
import Simplex.Messaging.Notifications.Server.Store.Types
import Simplex.Messaging.Notifications.Server.StoreLog
import Simplex.Messaging.Protocol (EntityId (..), EncNMsgMeta, ErrorType (..), IdsHash (..), NotifierId, NtfPrivateAuthKey, NtfPublicAuthKey, SMPServer, ServiceId, ServiceSub (..), pattern SMPServer)
import Simplex.Messaging.Server.QueueStore (RoundedSystemTime, getSystemDate)
import Simplex.Messaging.Server.QueueStore.Postgres (handleDuplicate, withLog_)
import Simplex.Messaging.Server.QueueStore.Postgres.Config (PostgresStoreCfg (..))
import Simplex.Messaging.Server.StoreLog (openWriteStoreLog)
import Simplex.Messaging.Transport.Client (TransportHost)
import Simplex.Messaging.Util (anyM, firstRow, maybeFirstRow, toChunks, tshow)
import System.Exit (exitFailure)
import System.IO (IOMode (..), hFlush, stdout, withFile)
import Text.Hex (decodeHex)

#if !defined(dbPostgres)
import Simplex.Messaging.Agent.Store.Postgres.DB (blobFieldDecoder)
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Util (eitherToMaybe)
#endif

data NtfPostgresStore = NtfPostgresStore
  { dbStore :: DBStore,
    dbStoreLog :: Maybe (StoreLog 'WriteMode),
    deletedTTL :: Int64
  }

mkNtfTknRec :: NtfTokenId -> NewNtfEntity 'Token -> C.PrivateKeyX25519 -> C.DhSecretX25519 -> NtfRegCode -> RoundedSystemTime -> NtfTknRec
mkNtfTknRec ntfTknId (NewNtfTkn token tknVerifyKey _) tknDhPrivKey tknDhSecret tknRegCode ts =
  NtfTknRec {ntfTknId, token, tknStatus = NTRegistered, tknVerifyKey, tknDhPrivKey, tknDhSecret, tknRegCode, tknCronInterval = 0, tknUpdatedAt = Just ts}

ntfSubServer' :: NtfSubRec -> SMPServer
ntfSubServer' NtfSubRec {smpQueue = SMPQueueNtf {smpServer}} = smpServer

data NtfEntityRec (e :: NtfEntity) where
  NtfTkn :: NtfTknRec -> NtfEntityRec 'Token
  NtfSub :: NtfSubRec -> NtfEntityRec 'Subscription

newNtfDbStore :: PostgresStoreCfg -> IO NtfPostgresStore
newNtfDbStore PostgresStoreCfg {dbOpts, dbStoreLogPath, confirmMigrations, deletedTTL} = do
  dbStore <- either err pure =<< createDBStore dbOpts ntfServerMigrations confirmMigrations
  dbStoreLog <- mapM (openWriteStoreLog True) dbStoreLogPath
  pure NtfPostgresStore {dbStore, dbStoreLog, deletedTTL}
  where
    err e = do
      logError $ "STORE: newNtfStore, error opening PostgreSQL database, " <> tshow e
      exitFailure

closeNtfDbStore :: NtfPostgresStore -> IO ()
closeNtfDbStore NtfPostgresStore {dbStore, dbStoreLog} = do
  closeDBStore dbStore
  mapM_ closeStoreLog dbStoreLog

addNtfToken :: NtfPostgresStore -> NtfTknRec -> IO (Either ErrorType ())
addNtfToken st tkn =
  withFastDB "addNtfToken" st $ \db ->
    E.try (DB.execute db insertNtfTknQuery $ ntfTknToRow tkn)
      >>= bimapM handleDuplicate (\_ -> withLog "addNtfToken" st (`logCreateToken` tkn))

insertNtfTknQuery :: Query
insertNtfTknQuery =
  [sql|
    INSERT INTO tokens
      (token_id, push_provider, push_provider_token, status, verify_key, dh_priv_key, dh_secret, reg_code, cron_interval, updated_at)
    VALUES (?,?,?,?,?,?,?,?,?,?)
  |]

replaceNtfToken :: NtfPostgresStore -> NtfTknRec -> IO (Either ErrorType ())
replaceNtfToken st NtfTknRec {ntfTknId, token = token@(DeviceToken pp ppToken), tknStatus, tknRegCode = code@(NtfRegCode regCode)} =
  withFastDB "replaceNtfToken" st $ \db -> runExceptT $ do
    ExceptT $ assertUpdated <$>
      DB.execute
        db
        [sql|
          UPDATE tokens
          SET push_provider = ?, push_provider_token = ?, status = ?, reg_code = ?
          WHERE token_id = ?
        |]
        (pp, Binary ppToken, tknStatus, Binary regCode, ntfTknId)
    withLog "replaceNtfToken" st $ \sl -> logUpdateToken sl ntfTknId token code

ntfTknToRow :: NtfTknRec -> NtfTknRow
ntfTknToRow NtfTknRec {ntfTknId, token, tknStatus, tknVerifyKey, tknDhPrivKey, tknDhSecret, tknRegCode, tknCronInterval, tknUpdatedAt} =
  let DeviceToken pp ppToken = token
      NtfRegCode regCode = tknRegCode
   in (ntfTknId, pp, Binary ppToken, tknStatus, tknVerifyKey, tknDhPrivKey, tknDhSecret, Binary regCode, tknCronInterval, tknUpdatedAt)

getNtfToken :: NtfPostgresStore -> NtfTokenId -> IO (Either ErrorType NtfTknRec)
getNtfToken st tknId =
  (maybe (Left AUTH) Right =<<) <$>
    getNtfToken_ st " WHERE token_id = ?" (Only tknId)

findNtfTokenRegistration :: NtfPostgresStore -> NewNtfEntity 'Token -> IO (Either ErrorType (Maybe NtfTknRec))
findNtfTokenRegistration st (NewNtfTkn (DeviceToken pp ppToken) tknVerifyKey _) =
  getNtfToken_ st " WHERE push_provider = ? AND push_provider_token = ? AND verify_key = ?" (pp, Binary ppToken, tknVerifyKey)

getNtfToken_ :: ToRow q => NtfPostgresStore -> Query -> q -> IO (Either ErrorType (Maybe NtfTknRec))
getNtfToken_ st cond params =
  withFastDB' "getNtfToken" st $ \db -> do
    tkn_ <- maybeFirstRow rowToNtfTkn $ DB.query db (ntfTknQuery <> cond) params
    mapM_ (updateTokenDate st db) tkn_
    pure tkn_

updateTokenDate :: NtfPostgresStore -> DB.Connection -> NtfTknRec -> IO ()
updateTokenDate st db NtfTknRec {ntfTknId, tknUpdatedAt} = do
  ts <- getSystemDate
  when (maybe True (ts /=) tknUpdatedAt) $ do
    void $ DB.execute db "UPDATE tokens SET updated_at = ? WHERE token_id = ?" (ts, ntfTknId)
    withLog "updateTokenDate" st $ \sl -> logUpdateTokenTime sl ntfTknId ts

type NtfTknRow = (NtfTokenId, PushProvider, Binary ByteString, NtfTknStatus, NtfPublicAuthKey, C.PrivateKeyX25519, C.DhSecretX25519, Binary ByteString, Word16, Maybe RoundedSystemTime)

ntfTknQuery :: Query
ntfTknQuery =
  [sql|
    SELECT token_id, push_provider, push_provider_token, status, verify_key, dh_priv_key, dh_secret, reg_code, cron_interval, updated_at
    FROM tokens
  |]

rowToNtfTkn :: NtfTknRow -> NtfTknRec
rowToNtfTkn (ntfTknId, pp, Binary ppToken, tknStatus, tknVerifyKey, tknDhPrivKey, tknDhSecret, Binary regCode, tknCronInterval, tknUpdatedAt)  =
  let token = DeviceToken pp ppToken
      tknRegCode = NtfRegCode regCode
   in NtfTknRec {ntfTknId, token, tknStatus, tknVerifyKey, tknDhPrivKey, tknDhSecret, tknRegCode, tknCronInterval, tknUpdatedAt}

deleteNtfToken :: NtfPostgresStore -> NtfTokenId -> IO (Either ErrorType [(SMPServer, [NotifierId])])
deleteNtfToken st tknId =
  withFastDB "deleteNtfToken" st $ \db -> runExceptT $ do
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
              string_agg(s.smp_notifier_id :: TEXT, ',') AS notifier_ids
            FROM smp_servers p
            JOIN subscriptions s ON s.smp_server_id = p.smp_server_id
            WHERE s.token_id = ?
            GROUP BY p.smp_host, p.smp_port, p.smp_keyhash;
          |]
          (Only tknId)
    liftIO $ void $ DB.execute db "DELETE FROM tokens WHERE token_id = ?" (Only tknId)
    withLog "deleteNtfToken" st (`logDeleteToken` tknId)
    pure subs
  where
    toServerSubs :: SMPServerRow :. Only Text -> (SMPServer, [NotifierId])
    toServerSubs (srv :. Only nIdsStr) = (rowToSrv srv, parseByteaString nIdsStr)
    parseByteaString :: Text -> [NotifierId]
    parseByteaString s = mapMaybe (fmap EntityId . decodeHex . T.drop 2) $ T.splitOn "," s  -- drop 2 to remove "\\x"

type SMPServerRow = (NonEmpty TransportHost, ServiceName, C.KeyHash)

type SMPQueueNtfRow = (NonEmpty TransportHost, ServiceName, C.KeyHash, NotifierId)

rowToSrv :: SMPServerRow -> SMPServer
rowToSrv (host, port, kh) = SMPServer host port kh

srvToRow :: SMPServer -> SMPServerRow
srvToRow (SMPServer host port kh) = (host, port, kh)

smpQueueToRow :: SMPQueueNtf -> SMPQueueNtfRow
smpQueueToRow (SMPQueueNtf (SMPServer host port kh) nId) = (host, port, kh, nId)

rowToSMPQueue :: SMPQueueNtfRow -> SMPQueueNtf
rowToSMPQueue (host, port, kh, nId) = SMPQueueNtf (SMPServer host port kh) nId

updateTknCronInterval :: NtfPostgresStore -> NtfTokenId -> Word16 -> IO (Either ErrorType ())
updateTknCronInterval st tknId cronInt =
  withFastDB "updateTknCronInterval" st $ \db -> runExceptT $ do
    ExceptT $ assertUpdated <$>
      DB.execute db "UPDATE tokens SET cron_interval = ? WHERE token_id = ?" (cronInt, tknId)
    withLog "updateTknCronInterval" st $ \sl -> logTokenCron sl tknId 0

-- Reads servers that have subscriptions that need subscribing.
-- It is executed on server start, and it is supposed to crash on database error
getUsedSMPServers :: NtfPostgresStore -> IO [(SMPServer, Int64, Maybe ServiceSub)]
getUsedSMPServers st =
  withTransaction (dbStore st) $ \db ->
    map rowToSrvSubs <$>
      DB.query
        db
        [sql|
          SELECT
            smp_host, smp_port, smp_keyhash, smp_server_id,
            ntf_service_id, smp_notifier_count, smp_notifier_ids_hash
          FROM smp_servers
          WHERE EXISTS (SELECT 1 FROM subscriptions WHERE status IN ?)
        |]
        (Only (In subscribeNtfStatuses))
  where
    rowToSrvSubs :: SMPServerRow :. (Int64, Maybe ServiceId, Int64, IdsHash) -> (SMPServer, Int64, Maybe ServiceSub)
    rowToSrvSubs ((host, port, kh) :. (srvId, serviceId_, n, idsHash)) =
      let service_ = (\serviceId -> ServiceSub serviceId n idsHash) <$> serviceId_
       in (SMPServer host port kh, srvId, service_)

getServerNtfSubscriptions :: NtfPostgresStore -> Int64 -> Maybe NtfSubscriptionId -> Int -> IO (Either ErrorType [ServerNtfSub])
getServerNtfSubscriptions st srvId afterSubId_ count =
  withDB' "getServerNtfSubscriptions" st $ \db -> do
    subs <-
      map toServerNtfSub <$> case afterSubId_ of
        Nothing ->
          DB.query db (query <> orderLimit) (srvId, In subscribeNtfStatuses, count)
        Just afterSubId ->
          DB.query db (query <> " AND subscription_id > ?" <> orderLimit) (srvId, In subscribeNtfStatuses, afterSubId, count)
    void $
      DB.executeMany
        db
        [sql|
          UPDATE subscriptions s
          SET status = upd.status
          FROM (VALUES(?, ?)) AS upd(status, subscription_id)
          WHERE s.subscription_id = (upd.subscription_id :: BYTEA)
            AND s.status != upd.status
        |]
        (map ((NSPending,) . fst) subs)
    pure subs
  where
    query =
      [sql|
        SELECT subscription_id, smp_notifier_id, smp_notifier_key
        FROM subscriptions
        WHERE smp_server_id = ? AND NOT ntf_service_assoc AND status IN ?
      |]
    orderLimit = " ORDER BY subscription_id LIMIT ?"
    toServerNtfSub (ntfSubId, notifierId, notifierKey) = (ntfSubId, (notifierId, notifierKey))

-- Returns token and subscription.
-- If subscription exists but belongs to another token, returns Left AUTH
findNtfSubscription :: NtfPostgresStore -> NtfTokenId -> SMPQueueNtf -> IO (Either ErrorType (NtfTknRec, Maybe NtfSubRec))
findNtfSubscription st tknId q =
  withFastDB "findNtfSubscription" st $ \db -> runExceptT $ do
    tkn@NtfTknRec {ntfTknId, tknStatus} <- ExceptT $ getNtfToken st tknId
    unless (allowNtfSubCommands tknStatus) $ throwE AUTH
    liftIO $ updateTokenDate st db tkn
    sub_ <-
      liftIO $ maybeFirstRow (rowToNtfSub q) $
        DB.query
          db
          [sql|
            SELECT s.token_id, s.subscription_id, s.smp_notifier_key, s.status, s.ntf_service_assoc
            FROM subscriptions s
            JOIN smp_servers p ON p.smp_server_id = s.smp_server_id
            WHERE p.smp_host = ? AND p.smp_port = ? AND p.smp_keyhash = ?
              AND s.smp_notifier_id = ?
          |]
          (smpQueueToRow q)
    forM_ sub_ $ \NtfSubRec {tokenId} -> unless (ntfTknId == tokenId) $ throwE AUTH
    pure (tkn, sub_)

getNtfSubscription :: NtfPostgresStore -> NtfSubscriptionId -> IO (Either ErrorType (NtfTknRec, NtfSubRec))
getNtfSubscription st subId =
  withFastDB "getNtfSubscription" st $ \db -> runExceptT $ do
    r@(tkn@NtfTknRec {tknStatus}, _) <-
      ExceptT $ firstRow rowToNtfTknSub AUTH $
        DB.query
          db
          [sql|
            SELECT t.token_id, t.push_provider, t.push_provider_token, t.status, t.verify_key, t.dh_priv_key, t.dh_secret, t.reg_code, t.cron_interval, t.updated_at,
              s.subscription_id, s.smp_notifier_key, s.status, s.ntf_service_assoc,
              p.smp_host, p.smp_port, p.smp_keyhash, s.smp_notifier_id
            FROM subscriptions s
            JOIN tokens t ON t.token_id = s.token_id
            JOIN smp_servers p ON p.smp_server_id = s.smp_server_id
            WHERE s.subscription_id = ?
          |]
          (Only subId)
    liftIO $ updateTokenDate st db tkn
    unless (allowNtfSubCommands tknStatus) $ throwE AUTH
    pure r

type NtfSubRow = (NtfSubscriptionId, NtfPrivateAuthKey, NtfSubStatus, NtfAssociatedService)

rowToNtfTknSub :: NtfTknRow :. NtfSubRow :. SMPQueueNtfRow -> (NtfTknRec, NtfSubRec)
rowToNtfTknSub (tknRow :. (ntfSubId, notifierKey, subStatus, ntfServiceAssoc) :. qRow)  =
  let tkn@NtfTknRec {ntfTknId = tokenId} = rowToNtfTkn tknRow
      smpQueue = rowToSMPQueue qRow
   in (tkn, NtfSubRec {ntfSubId, tokenId, smpQueue, notifierKey, subStatus, ntfServiceAssoc})

rowToNtfSub :: SMPQueueNtf -> Only NtfTokenId :. NtfSubRow -> NtfSubRec
rowToNtfSub smpQueue (Only tokenId :. (ntfSubId, notifierKey, subStatus, ntfServiceAssoc)) =
  NtfSubRec {ntfSubId, tokenId, smpQueue, notifierKey, subStatus, ntfServiceAssoc}

mkNtfSubRec :: NtfSubscriptionId -> NewNtfEntity 'Subscription -> NtfSubRec
mkNtfSubRec ntfSubId (NewNtfSub tokenId smpQueue notifierKey) =
  NtfSubRec {ntfSubId, tokenId, smpQueue, subStatus = NSNew, notifierKey, ntfServiceAssoc = False}

updateTknStatus :: NtfPostgresStore -> NtfTknRec -> NtfTknStatus -> IO (Either ErrorType ())
updateTknStatus st tkn status =
  withFastDB' "updateTknStatus" st $ \db -> updateTknStatus_ st db tkn status

updateTknStatus_ :: NtfPostgresStore -> DB.Connection -> NtfTknRec -> NtfTknStatus -> IO ()
updateTknStatus_ st db NtfTknRec {ntfTknId} status = do
  updated <- DB.execute db "UPDATE tokens SET status = ? WHERE token_id = ? AND status != ?" (status, ntfTknId, status)
  when (updated > 0) $ withLog "updateTknStatus" st $ \sl -> logTokenStatus sl ntfTknId status

-- unless it was already active
setTknStatusConfirmed :: NtfPostgresStore -> NtfTknRec -> IO (Either ErrorType ())
setTknStatusConfirmed st NtfTknRec {ntfTknId} =
  withFastDB' "updateTknStatus" st $ \db -> do
    updated <- DB.execute db "UPDATE tokens SET status = ? WHERE token_id = ? AND status != ? AND status != ?" (NTConfirmed, ntfTknId, NTConfirmed, NTActive)
    when (updated > 0) $ withLog "updateTknStatus" st $ \sl -> logTokenStatus sl ntfTknId NTConfirmed

setTokenActive :: NtfPostgresStore -> NtfTknRec -> IO (Either ErrorType ())
setTokenActive st tkn@NtfTknRec {ntfTknId, token = DeviceToken pp ppToken} =
  withFastDB' "setTokenActive" st $ \db -> do
    updateTknStatus_ st db tkn NTActive
    -- this removes other instances of the same token, e.g. because of repeated token registration attempts
    tknIds <-
      liftIO $ map fromOnly <$>
        DB.query
          db
          [sql|
            DELETE FROM tokens
            WHERE push_provider = ? AND push_provider_token = ? AND token_id != ?
            RETURNING token_id
          |]
          (pp, Binary ppToken, ntfTknId)
    withLog "deleteNtfToken" st $ \sl -> mapM_ (logDeleteToken sl) tknIds

withPeriodicNtfTokens :: NtfPostgresStore -> Int64 -> (NtfTknRec -> IO ()) -> IO Int
withPeriodicNtfTokens st now notify =
  fmap (fromRight 0) $ withDB' "withPeriodicNtfTokens" st $ \db ->
    DB.fold db (ntfTknQuery <> " WHERE status = ? AND cron_interval != 0 AND (cron_sent_at + cron_interval * 60) < ?") (NTActive, now) 0 $ \ !n row -> do
      notify (rowToNtfTkn row) $> (n + 1)

updateTokenCronSentAt :: NtfPostgresStore -> NtfTokenId -> Int64 -> IO (Either ErrorType ())
updateTokenCronSentAt st tknId now =
  withDB' "updateTokenCronSentAt" st $ \db ->
    void $ DB.execute db "UPDATE tokens t SET cron_sent_at = ? WHERE token_id = ?" (now, tknId)

addNtfSubscription :: NtfPostgresStore -> NtfSubRec -> IO (Either ErrorType (Int64, Bool))
addNtfSubscription st sub =
  withFastDB "addNtfSubscription" st $ \db -> runExceptT $ do
    srvId :: Int64 <- ExceptT $ upsertServer db $ ntfSubServer' sub
    n <- liftIO $ DB.execute db insertNtfSubQuery $ ntfSubToRow srvId sub
    withLog "addNtfSubscription" st (`logCreateSubscription` sub)
    pure (srvId, n > 0)
  where
    -- It is possible to combine these two statements into one with CTEs,
    -- to reduce roundtrips in case of `insert`, but it would be making 2 queries in all cases.
    -- With 2 statements it will succeed on the first `select` in most cases.
    upsertServer db srv = getServer >>= maybe insertServer (pure . Right)
      where
        getServer =
          maybeFirstRow fromOnly $
            DB.query
              db
              [sql|
                SELECT smp_server_id
                FROM smp_servers
                WHERE smp_host = ? AND smp_port = ? AND smp_keyhash = ?
              |]
              (srvToRow srv)
        insertServer =
          firstRow fromOnly (STORE "error inserting SMP server when adding subscription") $
            DB.query
              db
              [sql|
                INSERT INTO smp_servers (smp_host, smp_port, smp_keyhash) VALUES (?, ?, ?)
                ON CONFLICT (smp_host, smp_port, smp_keyhash)
                DO UPDATE SET smp_host = EXCLUDED.smp_host
                RETURNING smp_server_id
              |]
              (srvToRow srv)

insertNtfSubQuery :: Query
insertNtfSubQuery =
  [sql|
    INSERT INTO subscriptions (token_id, smp_server_id, smp_notifier_id, subscription_id, smp_notifier_key, status, ntf_service_assoc)
    VALUES (?,?,?,?,?,?,?)
  |]

ntfSubToRow :: Int64 -> NtfSubRec -> (NtfTokenId, Int64, NotifierId) :. NtfSubRow
ntfSubToRow srvId NtfSubRec {ntfSubId, tokenId, smpQueue = SMPQueueNtf _ nId, notifierKey, subStatus, ntfServiceAssoc} =
  (tokenId, srvId, nId) :. (ntfSubId, notifierKey, subStatus, ntfServiceAssoc)

deleteNtfSubscription :: NtfPostgresStore -> NtfSubscriptionId -> IO (Either ErrorType ())
deleteNtfSubscription st subId =
  withFastDB "deleteNtfSubscription" st $ \db -> runExceptT $ do
    ExceptT $ assertUpdated <$>
      DB.execute db "DELETE FROM subscriptions WHERE subscription_id = ?" (Only subId)
    withLog "deleteNtfSubscription" st (`logDeleteSubscription` subId)

updateSubStatus :: NtfPostgresStore -> Int64 -> NotifierId -> NtfSubStatus -> IO (Either ErrorType ())
updateSubStatus st srvId nId status =
  withFastDB' "updateSubStatus" st $ \db -> do
    sub_ :: Maybe (NtfSubscriptionId, NtfAssociatedService) <-
      maybeFirstRow id $
        DB.query
          db
          [sql|
            UPDATE subscriptions SET status = ?
            WHERE smp_server_id = ? AND smp_notifier_id = ? AND status != ?
            RETURNING subscription_id, ntf_service_assoc
          |]
          (status, srvId, nId, status)
    forM_ sub_ $ \(subId, serviceAssoc) ->
      withLog "updateSubStatus" st $ \sl -> logSubscriptionStatus sl (subId, status, serviceAssoc)

updateSrvSubStatus :: NtfPostgresStore -> SMPQueueNtf -> NtfSubStatus -> IO (Either ErrorType ())
updateSrvSubStatus st q status =
  withFastDB' "updateSrvSubStatus" st $ \db -> do
    sub_ :: Maybe (NtfSubscriptionId, NtfAssociatedService) <-
      maybeFirstRow id $
        DB.query
          db
          [sql|
            UPDATE subscriptions s
            SET status = ?
            FROM smp_servers p
            WHERE p.smp_server_id = s.smp_server_id
              AND p.smp_host = ? AND p.smp_port = ? AND p.smp_keyhash = ? AND s.smp_notifier_id = ?
              AND s.status != ?
            RETURNING s.subscription_id, s.ntf_service_assoc
          |]
          (Only status :. smpQueueToRow q :. Only status)
    forM_ sub_ $ \(subId, serviceAssoc) ->
      withLog "updateSrvSubStatus" st $ \sl -> logSubscriptionStatus sl (subId, status, serviceAssoc)

batchUpdateSrvSubStatus :: NtfPostgresStore -> SMPServer -> Maybe ServiceId -> NonEmpty NotifierId -> NtfSubStatus -> IO Int
batchUpdateSrvSubStatus st srv newServiceId nIds status =
  fmap (fromRight (-1)) $ withDB "batchUpdateSrvSubStatus" st $ \db -> runExceptT $ do
    (srvId :: Int64, currServiceId) <- ExceptT $ getSMPServerService db
    unless (currServiceId == newServiceId) $ liftIO $ void $
      DB.execute db "UPDATE smp_servers SET ntf_service_id = ? WHERE smp_server_id = ?" (newServiceId, srvId)
    let params = L.toList $ L.map (srvId,isJust newServiceId,status,) nIds
    liftIO $ fromIntegral <$> DB.executeMany db updateSubStatusQuery params
  where
    getSMPServerService db =
      firstRow id AUTH $
        DB.query
          db
          [sql|
            SELECT smp_server_id, ntf_service_id
            FROM smp_servers
            WHERE smp_host = ? AND smp_port = ? AND smp_keyhash = ?
            FOR UPDATE
          |]
          (srvToRow srv)

batchUpdateSrvSubErrors :: NtfPostgresStore -> SMPServer -> NonEmpty (NotifierId, NtfSubStatus) -> IO Int
batchUpdateSrvSubErrors st srv subs =
  fmap (fromRight (-1)) $ withDB "batchUpdateSrvSubErrors" st $ \db -> runExceptT $ do
    srvId :: Int64 <- ExceptT $ getSMPServerId db
    let params = map (\(nId, status) -> (srvId, False, status, nId)) $ L.toList subs
    subs' <- liftIO $ DB.returning db (updateSubStatusQuery <> " RETURNING s.subscription_id, s.status, s.ntf_service_assoc") params
    withLog "batchUpdateStatus_" st $ forM_ subs' . logSubscriptionStatus
    pure $ length subs'
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
          (srvToRow srv)

updateSubStatusQuery :: Query
updateSubStatusQuery =
  [sql|
    UPDATE subscriptions s
    SET status = upd.status, ntf_service_assoc = upd.ntf_service_assoc
    FROM (VALUES(?, ?, ?, ?)) AS upd(smp_server_id, ntf_service_assoc, status, smp_notifier_id)
    WHERE s.smp_server_id = upd.smp_server_id
      AND s.smp_notifier_id = (upd.smp_notifier_id :: BYTEA)
      AND (s.status != upd.status OR s.ntf_service_assoc != upd.ntf_service_assoc)
  |]

removeServiceAssociation :: NtfPostgresStore -> SMPServer -> IO (Either ErrorType (Int64, Int))
removeServiceAssociation st srv = do
  withDB "removeServiceAssociation" st $ \db -> runExceptT $ do
    srvId <- ExceptT $ removeServerService db
    subs <-
      liftIO $
        DB.query
          db
          [sql|
            UPDATE subscriptions s
            SET status = ?, ntf_service_assoc = FALSE
            WHERE smp_server_id = ?
              AND (s.status != ? OR s.ntf_service_assoc != FALSE)
            RETURNING s.subscription_id, s.status, s.ntf_service_assoc
          |]
          (NSInactive, srvId, NSInactive)
    withLog "removeServiceAssociation" st $ forM_ subs . logSubscriptionStatus
    pure (srvId, length subs)
  where
    removeServerService db =
      firstRow fromOnly AUTH $
        DB.query
          db
          [sql|
            UPDATE smp_servers
            SET ntf_service_id = NULL
            WHERE smp_host = ? AND smp_port = ? AND smp_keyhash = ?
            RETURNING smp_server_id
          |]
          (srvToRow srv)

addTokenLastNtf :: NtfPostgresStore -> PNMessageData -> IO (Either ErrorType (NtfTknRec, NonEmpty PNMessageData))
addTokenLastNtf st newNtf =
  withFastDB "addTokenLastNtf" st $ \db -> runExceptT $ do
    (tkn@NtfTknRec {ntfTknId = tId, tknStatus}, sId) <-
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
    unless (tknStatus == NTActive) $ throwE AUTH
    lastNtfs_ <-
      liftIO $ map toLastNtf <$>
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
                RETURNING subscription_id, sent_at, nmsg_nonce, nmsg_data
              ),
              last AS (
                SELECT subscription_id, sent_at, nmsg_nonce, nmsg_data
                FROM last_notifications
                WHERE token_id = ? AND subscription_id != (SELECT subscription_id FROM new)
                UNION
                SELECT subscription_id, sent_at, nmsg_nonce, nmsg_data
                FROM new
                ORDER BY sent_at DESC
                LIMIT ?
              ),
              delete AS (
                DELETE FROM last_notifications
                WHERE token_id = ?
                  AND sent_at < (SELECT min(sent_at) FROM last)
              )
              SELECT p.smp_host, p.smp_port, p.smp_keyhash, s.smp_notifier_id,
                l.sent_at, l.nmsg_nonce, l.nmsg_data
              FROM last l
              JOIN subscriptions s ON s.subscription_id = l.subscription_id
              JOIN smp_servers p ON p.smp_server_id = s.smp_server_id
              ORDER BY sent_at ASC
            |]
            (tId, sId, systemToUTCTime ntfTs, nmsgNonce, Binary encNMsgMeta, tId, maxNtfs, tId)
    let lastNtfs = fromMaybe (newNtf :| []) (L.nonEmpty lastNtfs_)
    pure (tkn, lastNtfs)
  where
    maxNtfs = 6 :: Int
    PNMessageData {smpQueue = q, ntfTs, nmsgNonce, encNMsgMeta} = newNtf
    toTokenSubId :: NtfTknRow :. Only NtfSubscriptionId -> (NtfTknRec, NtfSubscriptionId)
    toTokenSubId (tknRow :. Only sId) = (rowToNtfTkn tknRow, sId)

toLastNtf :: SMPQueueNtfRow :. (UTCTime, C.CbNonce, Binary EncNMsgMeta) -> PNMessageData
toLastNtf (qRow :. (ts, nonce, Binary encMeta)) =
  let ntfTs = MkSystemTime (systemSeconds $ utcToSystemTime ts) 0
   in PNMessageData {smpQueue = rowToSMPQueue qRow, ntfTs, nmsgNonce = nonce, encNMsgMeta = encMeta}

getEntityCounts :: NtfPostgresStore -> IO (Int64, Int64, Int64)
getEntityCounts st =
  fmap (fromRight (0, 0, 0)) $ withDB' "getEntityCounts" st $ \db -> do
    tCnt <- count <$> DB.query_ db "SELECT count(1) FROM tokens"
    sCnt <- count <$> DB.query_ db "SELECT reltuples::BIGINT FROM pg_class WHERE relname = 'subscriptions' AND relkind = 'r'"
    nCnt <- count <$> DB.query_ db "SELECT count(1) FROM last_notifications"
    pure (tCnt, sCnt, nCnt)
  where
    count (Only n : _) = n
    count [] = 0

importNtfSTMStore :: NtfPostgresStore -> NtfSTMStore -> S.Set NtfTokenId -> IO (Int64, Int64, Int64, Int64)
importNtfSTMStore NtfPostgresStore {dbStore = s} stmStore skipTokens = do
  (tIds, tCnt) <- importTokens
  subLookup <- readTVarIO $ subscriptionLookup stmStore
  sCnt <- importSubscriptions tIds subLookup
  nCnt <- importLastNtfs tIds subLookup
  serviceCnt <- importNtfServiceIds
  pure (tCnt, sCnt, nCnt, serviceCnt)
  where
    importTokens = do
      allTokens <- M.elems <$> readTVarIO (tokens stmStore)
      tokens <- filterTokens allTokens
      let skipped = length allTokens - length tokens
      when (skipped /= 0) $ putStrLn $ "Total skipped tokens " <> show skipped
      -- uncomment this line instead of the next two to import tokens one by one.
      -- tCnt <- withConnection s $ \db -> foldM (importTkn db) 0 tokens
      -- token interval is reset to 0 to only send notifications to devices with periodic mode,
      -- and before clients are upgraded - to all active devices.
      tRows <- mapM (fmap (ntfTknToRow . (\t -> t {tknCronInterval = 0} :: NtfTknRec)) . mkTknRec) tokens
      tCnt <- withConnection s $ \db -> DB.executeMany db insertNtfTknQuery tRows
      let tokenIds = S.fromList $ map (\NtfTknData {ntfTknId} -> ntfTknId) tokens
      (tokenIds,) <$> checkCount "token" (length tokens) tCnt
      where
        filterTokens tokens = do
          let deviceTokens = foldl' (\m t -> M.alter (Just . (t :) . fromMaybe []) (tokenKey t) m) M.empty tokens
          tokenSubs <- readTVarIO (tokenSubscriptions stmStore)
          filterM (keepTokenRegistration deviceTokens tokenSubs) tokens
        tokenKey NtfTknData {token, tknVerifyKey} = strEncode token <> ":" <> C.toPubKey C.pubKeyBytes tknVerifyKey
        keepTokenRegistration deviceTokens tokenSubs tkn@NtfTknData {ntfTknId, tknStatus} =
          case M.lookup (tokenKey tkn) deviceTokens of
            Just ts
              | length ts < 2 -> pure True
              | ntfTknId `S.member` skipTokens -> False <$ putStrLn ("Skipped token " <> enc ntfTknId <> " from --skip-tokens")
              | otherwise ->
                  readTVarIO tknStatus >>= \case
                    NTConfirmed -> do
                      hasSubs <- maybe (pure False) (\v -> not . S.null <$> readTVarIO v) $ M.lookup ntfTknId tokenSubs
                      if hasSubs
                        then pure True
                        else do
                          anyBetterToken <- anyM $ map (\NtfTknData {tknStatus = tknStatus'} -> activeOrInvalid <$> readTVarIO tknStatus') ts
                          if anyBetterToken
                            then False <$ putStrLn ("Skipped duplicate inactive token " <> enc ntfTknId)
                            else case findIndex (\NtfTknData {ntfTknId = tId} -> tId == ntfTknId) ts of
                              Just 0 -> pure True -- keeping the first token
                              Just _ -> False <$ putStrLn ("Skipped duplicate inactive token " <> enc ntfTknId <> " (no active token)")
                              Nothing -> True <$ putStrLn "Error: no device token in the list"
                    _ -> pure True
            Nothing -> True <$ putStrLn "Error: no device token in lookup map"
        activeOrInvalid = \case
          NTActive -> True
          NTInvalid _ -> True
          _ -> False
        -- importTkn db !n tkn@NtfTknData {ntfTknId} = do
        --   tknRow <- ntfTknToRow <$> mkTknRec tkn
        --   (DB.execute db insertNtfTknQuery tknRow >>= pure . (n + )) `E.catch` \(e :: E.SomeException) ->
        --     putStrLn ("Error inserting token " <> enc ntfTknId <> " " <> show e) $> n
    importSubscriptions :: S.Set NtfTokenId -> M.Map SMPQueueNtf NtfSubscriptionId -> IO Int64
    importSubscriptions tIds subLookup = do
      subs <- filterSubs . M.elems =<< readTVarIO (subscriptions stmStore)
      srvIds <- importServers subs
      putStrLn $ "Importing " <> show (length subs) <> " subscriptions..."
      -- uncomment this line instead of the next to import subs one by one.
      -- (sCnt, errTkns) <- withConnection s $ \db -> foldM (importSub db srvIds) (0, M.empty) subs
      sCnt <- foldM (importSubs srvIds) 0 $ toChunks 500000 subs
      checkCount "subscription" (length subs) sCnt
      where
        filterSubs allSubs = do
          let subs = filter (\NtfSubData {tokenId} -> S.member tokenId tIds) allSubs
              skipped = length allSubs - length subs
          when (skipped /= 0) $ putStrLn $ "Skipped " <> show skipped <> " subscriptions of missing tokens"
          let (removedSubTokens, removeSubs, dupQueues) = foldl' addSubToken (S.empty, S.empty, S.empty) subs
          unless (null removeSubs) $ putStrLn $ "Skipped " <> show (S.size removeSubs) <> " duplicate subscriptions of " <> show (S.size removedSubTokens) <> " tokens for " <> show (S.size dupQueues) <> " queues"
          pure $ filter (\NtfSubData {ntfSubId} -> S.notMember ntfSubId removeSubs) subs
          where
            addSubToken acc@(!stIds, !sIds, !qs) NtfSubData {ntfSubId, smpQueue, tokenId} =
              case M.lookup smpQueue subLookup of
                Just sId | sId /= ntfSubId ->
                  (S.insert tokenId stIds, S.insert ntfSubId sIds, S.insert smpQueue qs)
                _ -> acc
        importSubs srvIds !n subs = do
          rows <- mapM (ntfSubRow srvIds) subs
          cnt <- withConnection s $ \db -> DB.executeMany db insertNtfSubQuery $ L.toList rows
          let n' = n + cnt
          putStr $ "Imported " <> show n' <> " subscriptions" <> "\r"
          hFlush stdout
          pure n'
        -- importSub db srvIds (!n, !errTkns) sub@NtfSubData {ntfSubId = sId, tokenId} = do
        --   subRow <- ntfSubRow srvIds sub
        --   E.try (DB.execute db insertNtfSubQuery subRow) >>= \case
        --     Right i -> do
        --       let n' = n + i
        --       when (n' `mod` 100000 == 0) $ do
        --         putStr $ "Imported " <> show n' <> " subscriptions" <> "\r"
        --         hFlush stdout
        --       pure (n', errTkns)
        --     Left (e :: E.SomeException) -> do
        --       when (n `mod` 100000 == 0) $ putStrLn ""
        --       putStrLn $ "Error inserting subscription " <> enc sId <> " for token " <> enc tokenId <> " " <> show e
        --       pure (n, M.alter (Just . maybe [sId] (sId :)) tokenId errTkns)
        ntfSubRow srvIds sub = case M.lookup srv srvIds of
          Just sId -> ntfSubToRow sId <$> mkSubRec sub
          Nothing -> E.throwIO $ userError $ "no matching server ID for server " <> show srv
          where
            srv = ntfSubServer sub
    importServers subs = do
      sIds <- withConnection s $ \db -> map fromOnly <$> DB.returning db srvQuery (map srvToRow srvs)
      void $ checkCount "server" (length srvs) (length sIds)
      pure $ M.fromList $ zip srvs sIds
      where
        srvQuery = "INSERT INTO smp_servers (smp_host, smp_port, smp_keyhash) VALUES (?, ?, ?) RETURNING smp_server_id"
        srvs = nubOrd $ map ntfSubServer subs
    importLastNtfs :: S.Set NtfTokenId -> M.Map SMPQueueNtf NtfSubscriptionId -> IO Int64
    importLastNtfs tIds subLookup = do
      ntfs <- readTVarIO (tokenLastNtfs stmStore)
      ntfRows <- filterLastNtfRows ntfs
      nCnt <- withConnection s $ \db -> DB.executeMany db lastNtfQuery ntfRows
      checkCount "last notification" (length ntfRows) nCnt
      where
        lastNtfQuery = "INSERT INTO last_notifications(token_id, subscription_id, sent_at, nmsg_nonce, nmsg_data) VALUES (?,?,?,?,?)"
        filterLastNtfRows ntfs = do
          (skippedTkns, ntfCnt, (skippedQueues, ntfRows)) <- foldM lastNtfRows (S.empty, 0, (S.empty, [])) $ M.assocs ntfs
          let skipped = ntfCnt - length ntfRows
          when (skipped /= 0) $ putStrLn $ "Skipped last notifications " <> show skipped <> " for " <> show (S.size skippedTkns) <> " missing tokens and " <> show (S.size skippedQueues) <> " missing subscriptions with token present"
          pure ntfRows
        lastNtfRows (!stIds, !cnt, !acc) (tId, ntfVar) = do
          ntfs <- L.toList <$> readTVarIO ntfVar
          let cnt' = cnt + length ntfs
          pure $
            if S.member tId tIds
              then (stIds, cnt', foldl' ntfRow acc ntfs)
              else (S.insert tId stIds, cnt', acc)
          where
            ntfRow (!qs, !rows) PNMessageData {smpQueue, ntfTs, nmsgNonce, encNMsgMeta} = case M.lookup smpQueue subLookup of
              Just ntfSubId ->
                let row = (tId, ntfSubId, systemToUTCTime ntfTs, nmsgNonce, Binary encNMsgMeta)
                 in (qs, row : rows)
              Nothing -> (S.insert smpQueue qs, rows)
    importNtfServiceIds = do
      ss <- M.assocs <$> readTVarIO (ntfServices stmStore)
      withConnection s $ \db -> DB.executeMany db serviceQuery $ map serviceToRow ss
      where
        serviceQuery =
          [sql|
            INSERT INTO smp_servers (smp_host, smp_port, smp_keyhash, ntf_service_id)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (smp_host, smp_port, smp_keyhash)
            DO UPDATE SET ntf_service_id = EXCLUDED.ntf_service_id
          |]
        serviceToRow (srv, serviceId) = srvToRow srv :. Only serviceId
    checkCount name expected inserted
      | fromIntegral expected == inserted = do
          putStrLn $ "Imported " <> show inserted <> " " <> name <> "s."
          pure inserted
      | otherwise = do
          putStrLn $ "Incorrect " <> name <> " count: expected " <> show expected <> ", imported " <> show inserted
          putStrLn "Import aborted, fix data and repeat"
          exitFailure
    enc = B.unpack . B64.encode . unEntityId

exportNtfDbStore :: NtfPostgresStore -> FilePath -> IO (Int, Int, Int)
exportNtfDbStore NtfPostgresStore {dbStoreLog = Nothing} _ =
  putStrLn "Internal error: export requires store log" >> exitFailure
exportNtfDbStore NtfPostgresStore {dbStore = s, dbStoreLog = Just sl} lastNtfsFile =
  (,,) <$> exportTokens <*> exportSubscriptions <*> exportLastNtfs
  where
    exportTokens = do
      tCnt <- withConnection s $ \db -> DB.fold_ db ntfTknQuery 0 $ \ !i tkn ->
        logCreateToken sl (rowToNtfTkn tkn) $> (i + 1)
      putStrLn $ "Exported " <> show tCnt <> " tokens"
      pure tCnt
    exportSubscriptions = do
      sCnt <- withConnection s $ \db -> DB.fold_ db ntfSubQuery 0 $ \ !i sub -> do
        let i' = i + 1
        logCreateSubscription sl (toNtfSub sub)
        when (i' `mod` 500000 == 0) $ do
          putStr $ "Exported " <> show i' <> " subscriptions" <> "\r"
          hFlush stdout
        pure i'
      putStrLn $ "Exported " <> show sCnt <> " subscriptions"
      pure sCnt
      where
        ntfSubQuery =
          [sql|
            SELECT s.token_id, s.subscription_id, s.smp_notifier_key, s.status, s.ntf_service_assoc,
              p.smp_host, p.smp_port, p.smp_keyhash, s.smp_notifier_id
            FROM subscriptions s
            JOIN smp_servers p ON p.smp_server_id = s.smp_server_id
          |]
        toNtfSub :: Only NtfTokenId :. NtfSubRow :. SMPQueueNtfRow -> NtfSubRec
        toNtfSub (Only tokenId :. (ntfSubId, notifierKey, subStatus, ntfServiceAssoc) :. qRow)  =
          let smpQueue = rowToSMPQueue qRow
           in NtfSubRec {ntfSubId, tokenId, smpQueue, notifierKey, subStatus, ntfServiceAssoc}
    exportLastNtfs =
      withFile lastNtfsFile WriteMode $ \h ->
        withConnection s $ \db -> DB.fold_ db lastNtfsQuery 0 $ \ !i (Only tknId :. ntfRow) ->
          B.hPutStr h (encodeLastNtf tknId $ toLastNtf ntfRow) $> (i + 1)
      where
        -- Note that the order here is ascending, to be compatible with how it is imported
        lastNtfsQuery =
          [sql|
            SELECT s.token_id, p.smp_host, p.smp_port, p.smp_keyhash, s.smp_notifier_id,
              n.sent_at, n.nmsg_nonce, n.nmsg_data
            FROM last_notifications n
            JOIN subscriptions s ON s.subscription_id = n.subscription_id
            JOIN smp_servers p ON p.smp_server_id = s.smp_server_id
            ORDER BY token_ntf_id ASC
          |]
        encodeLastNtf tknId ntf = strEncode (TNMRv1 tknId ntf) `B.snoc` '\n'

withFastDB' :: Text -> NtfPostgresStore -> (DB.Connection -> IO a) -> IO (Either ErrorType a)
withFastDB' op st action = withFastDB op st $ fmap Right . action
{-# INLINE withFastDB' #-}

withDB' :: Text -> NtfPostgresStore -> (DB.Connection -> IO a) -> IO (Either ErrorType a)
withDB' op st action = withDB op st $ fmap Right . action
{-# INLINE withDB' #-}

withFastDB :: forall a. Text -> NtfPostgresStore -> (DB.Connection -> IO (Either ErrorType a)) -> IO (Either ErrorType a)
withFastDB op st = withDB_ op st True
{-# INLINE withFastDB #-}

withDB :: forall a. Text -> NtfPostgresStore -> (DB.Connection -> IO (Either ErrorType a)) -> IO (Either ErrorType a)
withDB op st = withDB_ op st False
{-# INLINE withDB #-}

withDB_ :: forall a. Text -> NtfPostgresStore -> Bool -> (DB.Connection -> IO (Either ErrorType a)) -> IO (Either ErrorType a)
withDB_ op st priority action =
  E.uninterruptibleMask_ $ E.try (withTransactionPriority (dbStore st) priority action) >>= either logErr pure
  where
    logErr :: E.SomeException -> IO (Either ErrorType a)
    logErr e = logError ("STORE: " <> err) $> Left (STORE err)
      where
        err = op <> ", withDB, " <> tshow e

withLog :: MonadIO m => Text -> NtfPostgresStore -> (StoreLog 'WriteMode -> IO ()) -> m ()
withLog op NtfPostgresStore {dbStoreLog} = withLog_ op dbStoreLog
{-# INLINE withLog #-}

assertUpdated :: Int64 -> Either ErrorType ()
assertUpdated 0 = Left AUTH
assertUpdated _ = Right ()

instance FromField NtfSubStatus where fromField = fromTextField_ $ either (const Nothing) Just . smpDecode . encodeUtf8

instance ToField NtfSubStatus where toField = toField . decodeLatin1 . smpEncode

#if !defined(dbPostgres)
instance FromField PushProvider where fromField = fromTextField_ $ eitherToMaybe . strDecode . encodeUtf8

instance ToField PushProvider where toField = toField . decodeLatin1 . strEncode

instance FromField NtfTknStatus where fromField = fromTextField_ $ either (const Nothing) Just . smpDecode . encodeUtf8

instance ToField NtfTknStatus where toField = toField . decodeLatin1 . smpEncode

instance FromField (C.PrivateKey 'C.X25519) where fromField = blobFieldDecoder C.decodePrivKey

instance ToField (C.PrivateKey 'C.X25519) where toField = toField . Binary . C.encodePrivKey

instance FromField C.APrivateAuthKey where fromField = blobFieldDecoder C.decodePrivKey

instance ToField C.APrivateAuthKey where toField = toField . Binary . C.encodePrivKey

instance FromField (NonEmpty TransportHost) where fromField = fromTextField_ $ eitherToMaybe . strDecode . encodeUtf8

instance ToField (NonEmpty TransportHost) where toField = toField . decodeLatin1 . strEncode

instance FromField C.KeyHash where fromField = blobFieldDecoder $ parseAll strP

instance ToField C.KeyHash where toField = toField . Binary . strEncode

instance FromField C.CbNonce where fromField = blobFieldDecoder $ parseAll smpP

instance ToField C.CbNonce where toField = toField . Binary . smpEncode
#endif
