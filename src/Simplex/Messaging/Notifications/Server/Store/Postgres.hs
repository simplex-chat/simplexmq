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
import Data.Maybe (fromMaybe, isJust, mapMaybe)
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
import qualified Network.TLS as TLS
import Simplex.Messaging.Agent.Store.AgentStore ()
import Simplex.Messaging.Agent.Store.Postgres (closeDBStore, createDBStore)
import Simplex.Messaging.Agent.Store.Postgres.Common
import Simplex.Messaging.Agent.Store.Postgres.DB (fromTextField_)
import Simplex.Messaging.Agent.Store.Shared (MigrationConfig (..))
import Simplex.Messaging.Client (ProtocolClientError (..), SMPClientError)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Store.Migrations
import Simplex.Messaging.Notifications.Server.Store.Types
import Simplex.Messaging.Protocol (EntityId (..), EncNMsgMeta, ErrorType (..), IdsHash (..), NotifierId, NtfPrivateAuthKey, NtfPublicAuthKey, ProtocolServer (..), SMPServer, ServiceId, ServiceSub (..), pattern SMPServer)
import Simplex.Messaging.Server.QueueStore.Postgres (handleDuplicate)
import Simplex.Messaging.Server.QueueStore.Postgres.Config (PostgresStoreCfg (..))
import Simplex.Messaging.SystemTime
import Simplex.Messaging.Transport.Client (TransportHost)
import Simplex.Messaging.Util (firstRow, maybeFirstRow, tshow)
import System.Exit (exitFailure)
import Text.Hex (decodeHex)

#if !defined(dbPostgres)
import qualified Data.X509 as X
import Simplex.Messaging.Agent.Store.Postgres.DB (blobFieldDecoder)
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Util (eitherToMaybe)
#endif

data NtfPostgresStore = NtfPostgresStore
  { dbStore :: DBStore,
    deletedTTL :: Int64
  }

mkNtfTknRec :: NtfTokenId -> NewNtfEntity 'Token -> C.PrivateKeyX25519 -> C.DhSecretX25519 -> NtfRegCode -> SystemDate -> NtfTknRec
mkNtfTknRec ntfTknId (NewNtfTkn token tknVerifyKey _) tknDhPrivKey tknDhSecret tknRegCode ts =
  NtfTknRec {ntfTknId, token, tknStatus = NTRegistered, tknVerifyKey, tknDhPrivKey, tknDhSecret, tknRegCode, tknCronInterval = 0, tknUpdatedAt = Just ts}

ntfSubServer' :: NtfSubRec -> SMPServer
ntfSubServer' NtfSubRec {smpQueue = SMPQueueNtf {smpServer}} = smpServer

data NtfEntityRec (e :: NtfEntity) where
  NtfTkn :: NtfTknRec -> NtfEntityRec 'Token
  NtfSub :: NtfSubRec -> NtfEntityRec 'Subscription

newNtfDbStore :: PostgresStoreCfg -> IO NtfPostgresStore
newNtfDbStore PostgresStoreCfg {dbOpts, confirmMigrations, deletedTTL} = do
  dbStore <- either err pure =<< createDBStore dbOpts ntfServerMigrations (MigrationConfig confirmMigrations Nothing)
  pure NtfPostgresStore {dbStore, deletedTTL}
  where
    err e = do
      logError $ "STORE: newNtfStore, error opening PostgreSQL database, " <> tshow e
      exitFailure

closeNtfDbStore :: NtfPostgresStore -> IO ()
closeNtfDbStore NtfPostgresStore {dbStore} = closeDBStore dbStore

addNtfToken :: NtfPostgresStore -> NtfTknRec -> IO (Either ErrorType ())
addNtfToken st tkn =
  withFastDB "addNtfToken" st $ \db ->
    E.try (void $ DB.execute db insertNtfTknQuery $ ntfTknToRow tkn)
      >>= bimapM handleDuplicate pure

insertNtfTknQuery :: Query
insertNtfTknQuery =
  [sql|
    INSERT INTO tokens
      (token_id, push_provider, push_provider_token, status, verify_key, dh_priv_key, dh_secret, reg_code, cron_interval, updated_at)
    VALUES (?,?,?,?,?,?,?,?,?,?)
  |]

replaceNtfToken :: NtfPostgresStore -> NtfTknRec -> IO (Either ErrorType ())
replaceNtfToken st NtfTknRec {ntfTknId, token = DeviceToken pp ppToken, tknStatus, tknRegCode = NtfRegCode regCode} =
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
    mapM_ (updateTokenDate db) tkn_
    pure tkn_

updateTokenDate :: DB.Connection -> NtfTknRec -> IO ()
updateTokenDate db NtfTknRec {ntfTknId, tknUpdatedAt} = do
  ts <- getSystemDate
  when (maybe True (ts /=) tknUpdatedAt) $ do
    void $ DB.execute db "UPDATE tokens SET updated_at = ? WHERE token_id = ?" (ts, ntfTknId)

type NtfTknRow = (NtfTokenId, PushProvider, Binary ByteString, NtfTknStatus, NtfPublicAuthKey, C.PrivateKeyX25519, C.DhSecretX25519, Binary ByteString, Word16, Maybe SystemDate)

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

getNtfServiceCredentials :: DB.Connection -> SMPServer -> IO (Maybe (Int64, Maybe (C.KeyHash, TLS.Credential)))
getNtfServiceCredentials db srv =
  maybeFirstRow toService $
    DB.query
      db
      [sql|
        SELECT smp_server_id, ntf_service_cert_hash, ntf_service_cert, ntf_service_priv_key
        FROM smp_servers
        WHERE smp_host = ? AND smp_port = ? AND smp_keyhash = ?
        FOR UPDATE
      |]
      (host srv, port srv, keyHash srv)
  where
    toService (Only srvId :. creds) = (srvId, toCredentials creds)
    toCredentials = \case
      (Just kh, Just cert, Just pk) -> Just (kh, (cert, pk))
      _ -> Nothing

setNtfServiceCredentials :: DB.Connection -> Int64 -> (C.KeyHash, TLS.Credential) -> IO ()
setNtfServiceCredentials db srvId (kh, (cert, pk)) =
  void $ DB.execute
    db
    [sql|
      UPDATE smp_servers
      SET ntf_service_cert_hash = ?, ntf_service_cert = ?, ntf_service_priv_key = ?
      WHERE smp_server_id = ?
    |]
    (kh, cert, pk, srvId)

updateNtfServiceId :: DB.Connection -> SMPServer -> Maybe ServiceId -> IO ()
updateNtfServiceId db srv newServiceId_ = do
  maybeFirstRow id (getSMPServiceForUpdate_ db srv) >>= mapM_ updateService
  where
    updateService (srvId, currServiceId_) = unless (currServiceId_ == newServiceId_) $ do
      when (isJust currServiceId_) $ do
        void $ removeServiceAssociation_ db srvId
        logError $ "STORE: service ID for " <> enc (host srv) <> toServiceId <> ", removed sub associations"
      void $ case newServiceId_ of
        Just newServiceId ->
          DB.execute
            db
            [sql|
              UPDATE smp_servers
              SET ntf_service_id = ?,
                  smp_notifier_count = 0,
                  smp_notifier_ids_hash = DEFAULT
              WHERE smp_server_id = ?
            |]
            (newServiceId, srvId)
        Nothing ->
          DB.execute
            db
            [sql|
              UPDATE smp_servers
              SET ntf_service_id = NULL,
                  ntf_service_cert = NULL,
                  ntf_service_cert_hash = NULL,
                  ntf_service_priv_key = NULL,
                  smp_notifier_count = 0,
                  smp_notifier_ids_hash = DEFAULT
              WHERE smp_server_id = ?
            |]
            (Only srvId)
    toServiceId = maybe " removed" ((" changed to " <>) . enc) newServiceId_
    enc :: StrEncoding a => a -> Text
    enc = decodeLatin1 . strEncode

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
    liftIO $ updateTokenDate db tkn
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
    liftIO $ updateTokenDate db tkn
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
  withFastDB' "updateTknStatus" st $ \db -> updateTknStatus_ db tkn status

updateTknStatus_ :: DB.Connection -> NtfTknRec -> NtfTknStatus -> IO ()
updateTknStatus_ db NtfTknRec {ntfTknId} status =
  void $ DB.execute db "UPDATE tokens SET status = ? WHERE token_id = ? AND status != ?" (status, ntfTknId, status)

-- unless it was already active
setTknStatusConfirmed :: NtfPostgresStore -> NtfTknRec -> IO (Either ErrorType ())
setTknStatusConfirmed st NtfTknRec {ntfTknId} =
  withFastDB' "updateTknStatus" st $ \db ->
    void $ DB.execute db "UPDATE tokens SET status = ? WHERE token_id = ? AND status != ? AND status != ?" (NTConfirmed, ntfTknId, NTConfirmed, NTActive)

setTokenActive :: NtfPostgresStore -> NtfTknRec -> IO (Either ErrorType ())
setTokenActive st tkn@NtfTknRec {ntfTknId, token = DeviceToken pp ppToken} =
  withFastDB' "setTokenActive" st $ \db -> do
    updateTknStatus_ db tkn NTActive
    -- this removes other instances of the same token, e.g. because of repeated token registration attempts
    void $ DB.execute
      db
      [sql|
        DELETE FROM tokens
        WHERE push_provider = ? AND push_provider_token = ? AND token_id != ?
      |]
      (pp, Binary ppToken, ntfTknId)

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
  withFastDB "deleteNtfSubscription" st $ \db ->
    assertUpdated <$>
      DB.execute db "DELETE FROM subscriptions WHERE subscription_id = ?" (Only subId)

updateSubStatus :: NtfPostgresStore -> Int64 -> NotifierId -> NtfSubStatus -> IO (Either ErrorType ())
updateSubStatus st srvId nId status =
  withFastDB' "updateSubStatus" st $ \db -> do
    void $
      DB.execute
        db
        [sql|
          UPDATE subscriptions SET status = ?
          WHERE smp_server_id = ? AND smp_notifier_id = ? AND status != ?
        |]
        (status, srvId, nId, status)

updateSrvSubStatus :: NtfPostgresStore -> SMPQueueNtf -> NtfSubStatus -> IO (Either ErrorType ())
updateSrvSubStatus st q status =
  withFastDB' "updateSrvSubStatus" st $ \db ->
    void $
      DB.execute
        db
        [sql|
          UPDATE subscriptions s
          SET status = ?
          FROM smp_servers p
          WHERE p.smp_server_id = s.smp_server_id
            AND p.smp_host = ? AND p.smp_port = ? AND p.smp_keyhash = ? AND s.smp_notifier_id = ?
            AND s.status != ?
        |]
        (Only status :. smpQueueToRow q :. Only status)

batchUpdateSrvSubStatus :: NtfPostgresStore -> SMPServer -> Maybe ServiceId -> NonEmpty NotifierId -> NtfSubStatus -> IO Int
batchUpdateSrvSubStatus st srv newServiceId nIds status =
  fmap (fromRight (-1)) $ withDB "batchUpdateSrvSubStatus" st $ \db -> runExceptT $ do
    (srvId, currServiceId) <- ExceptT $ firstRow id AUTH $ getSMPServiceForUpdate_ db srv
    -- TODO [certs rcv] should this remove associations/credentials when newServiceId is Nothing or different
    unless (currServiceId == newServiceId) $ liftIO $ void $
      DB.execute db "UPDATE smp_servers SET ntf_service_id = ? WHERE smp_server_id = ?" (newServiceId, srvId)
    let params = L.toList $ L.map (srvId,isJust newServiceId,status,) nIds
    liftIO $ fromIntegral <$> DB.executeMany db updateSubStatusQuery params

getSMPServiceForUpdate_ :: DB.Connection -> SMPServer -> IO [(Int64, Maybe ServiceId)]
getSMPServiceForUpdate_ db srv =
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
    liftIO $ fromIntegral <$> DB.executeMany db updateSubStatusQuery params
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

removeServiceAssociation_ :: DB.Connection -> Int64 -> IO Int64
removeServiceAssociation_ db srvId =
  DB.execute
    db
    [sql|
      UPDATE subscriptions s
      SET status = ?, ntf_service_assoc = FALSE
      WHERE smp_server_id = ?
        AND (s.status != ? OR s.ntf_service_assoc != FALSE)
    |]
    (NSInactive, srvId, NSInactive)

removeServiceAndAssociations :: NtfPostgresStore -> SMPServer -> IO (Either ErrorType (Int64, Int))
removeServiceAndAssociations st srv = do
  withDB "removeServiceAndAssociations" st $ \db -> runExceptT $ do
    srvId <- ExceptT $ getServerId db
    subsCount <- liftIO $ removeServiceAssociation_ db srvId
    liftIO $ removeServerService db srvId
    pure (srvId, fromIntegral subsCount)
  where
    getServerId db =
      firstRow fromOnly AUTH $
        DB.query
          db
          [sql|
            SELECT smp_server_id
            FROM smp_servers
            WHERE smp_host = ? AND smp_port = ? AND smp_keyhash = ?
            FOR UPDATE
          |]
          (srvToRow srv)
    removeServerService db srvId =
      DB.execute
        db
        [sql|
          UPDATE smp_servers
          SET ntf_service_id = NULL,
              ntf_service_cert = NULL,
              ntf_service_cert_hash = NULL,
              ntf_service_priv_key = NULL,
              smp_notifier_count = 0,
              smp_notifier_ids_hash = DEFAULT
          WHERE smp_server_id = ?
        |]
        (Only srvId)

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

withClientDB :: Text -> NtfPostgresStore -> (DB.Connection -> IO a) -> IO (Either SMPClientError a)
withClientDB op st action =
  E.uninterruptibleMask_ $ E.try (withTransaction (dbStore st) action) >>= bimapM logErr pure
  where
    logErr :: E.SomeException -> IO SMPClientError
    logErr e = logError ("STORE: " <> op <> ", withDB, " <> tshow e) $> PCEIOError (E.displayException e)

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

instance ToField X.PrivKey where toField = toField . Binary . C.encodeASNObj

instance FromField X.PrivKey where
  fromField = blobFieldDecoder $ C.decodeASNKey >=> \case (pk, []) -> Right pk; r -> C.asnKeyError r
#endif
