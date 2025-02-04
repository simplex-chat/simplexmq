{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations
  ( app,
    initialize,
    run,
    getCurrent,
  )
where

import Control.Monad (forM_, when)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import Data.Text.Encoding (decodeLatin1)
import Data.Time.Clock (getCurrentTime)
import Database.SQLite.Simple (Only (..), Query (..))
import qualified Database.SQLite.Simple as SQL
import Database.SQLite.Simple.QQ (sql)
import qualified Database.SQLite3 as SQLite3
import Simplex.Messaging.Agent.Protocol (extraSMPServerHosts)
import qualified Simplex.Messaging.Agent.Store.DB as DB
import Simplex.Messaging.Agent.Store.SQLite.Common
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220101_initial
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220301_snd_queue_keys
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220322_notifications
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220608_v2
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220625_v2_ntf_mode
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220811_onion_hosts
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220817_connection_ntfs
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220905_commands
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220915_connection_queues
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230110_users
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230117_fkey_indexes
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230120_delete_errors
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230217_server_key_hash
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230223_files
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230320_retry_state
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230401_snd_files
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230510_files_pending_replicas_indexes
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230516_encrypted_rcv_message_hashes
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230531_switch_status
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230615_ratchet_sync
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230701_delivery_receipts
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230720_delete_expired_messages
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230722_indexes
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230814_indexes
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230829_crypto_files
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20231222_command_created_at
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20231225_failed_work_items
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240121_message_delivery_indexes
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240124_file_redirect
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240223_connections_wait_delivery
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240225_ratchet_kem
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240417_rcv_files_approved_relays
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240624_snd_secure
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240702_servers_stats
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240930_ntf_tokens_to_delete
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20241007_rcv_queues_last_broker_ts
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20241224_ratchet_e2e_snd_params
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20250203_msg_bodies
import Simplex.Messaging.Agent.Store.Shared
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Transport.Client (TransportHost)

schemaMigrations :: [(String, Query, Maybe Query)]
schemaMigrations =
  [ ("20220101_initial", m20220101_initial, Nothing),
    ("20220301_snd_queue_keys", m20220301_snd_queue_keys, Nothing),
    ("20220322_notifications", m20220322_notifications, Nothing),
    ("20220607_v2", m20220608_v2, Nothing),
    ("m20220625_v2_ntf_mode", m20220625_v2_ntf_mode, Nothing),
    ("m20220811_onion_hosts", m20220811_onion_hosts, Nothing),
    ("m20220817_connection_ntfs", m20220817_connection_ntfs, Nothing),
    ("m20220905_commands", m20220905_commands, Nothing),
    ("m20220915_connection_queues", m20220915_connection_queues, Nothing),
    ("m20230110_users", m20230110_users, Nothing),
    ("m20230117_fkey_indexes", m20230117_fkey_indexes, Nothing),
    ("m20230120_delete_errors", m20230120_delete_errors, Nothing),
    ("m20230217_server_key_hash", m20230217_server_key_hash, Nothing),
    ("m20230223_files", m20230223_files, Just down_m20230223_files),
    ("m20230320_retry_state", m20230320_retry_state, Just down_m20230320_retry_state),
    ("m20230401_snd_files", m20230401_snd_files, Just down_m20230401_snd_files),
    ("m20230510_files_pending_replicas_indexes", m20230510_files_pending_replicas_indexes, Just down_m20230510_files_pending_replicas_indexes),
    ("m20230516_encrypted_rcv_message_hashes", m20230516_encrypted_rcv_message_hashes, Just down_m20230516_encrypted_rcv_message_hashes),
    ("m20230531_switch_status", m20230531_switch_status, Just down_m20230531_switch_status),
    ("m20230615_ratchet_sync", m20230615_ratchet_sync, Just down_m20230615_ratchet_sync),
    ("m20230701_delivery_receipts", m20230701_delivery_receipts, Just down_m20230701_delivery_receipts),
    ("m20230720_delete_expired_messages", m20230720_delete_expired_messages, Just down_m20230720_delete_expired_messages),
    ("m20230722_indexes", m20230722_indexes, Just down_m20230722_indexes),
    ("m20230814_indexes", m20230814_indexes, Just down_m20230814_indexes),
    ("m20230829_crypto_files", m20230829_crypto_files, Just down_m20230829_crypto_files),
    ("m20231222_command_created_at", m20231222_command_created_at, Just down_m20231222_command_created_at),
    ("m20231225_failed_work_items", m20231225_failed_work_items, Just down_m20231225_failed_work_items),
    ("m20240121_message_delivery_indexes", m20240121_message_delivery_indexes, Just down_m20240121_message_delivery_indexes),
    ("m20240124_file_redirect", m20240124_file_redirect, Just down_m20240124_file_redirect),
    ("m20240223_connections_wait_delivery", m20240223_connections_wait_delivery, Just down_m20240223_connections_wait_delivery),
    ("m20240225_ratchet_kem", m20240225_ratchet_kem, Just down_m20240225_ratchet_kem),
    ("m20240417_rcv_files_approved_relays", m20240417_rcv_files_approved_relays, Just down_m20240417_rcv_files_approved_relays),
    ("m20240624_snd_secure", m20240624_snd_secure, Just down_m20240624_snd_secure),
    ("m20240702_servers_stats", m20240702_servers_stats, Just down_m20240702_servers_stats),
    ("m20240930_ntf_tokens_to_delete", m20240930_ntf_tokens_to_delete, Just down_m20240930_ntf_tokens_to_delete),
    ("m20241007_rcv_queues_last_broker_ts", m20241007_rcv_queues_last_broker_ts, Just down_m20241007_rcv_queues_last_broker_ts),
    ("m20241224_ratchet_e2e_snd_params", m20241224_ratchet_e2e_snd_params, Just down_m20241224_ratchet_e2e_snd_params),
    ("m20250203_msg_bodies", m20250203_msg_bodies, Just down_m20250203_msg_bodies)
  ]

-- | The list of migrations in ascending order by date
app :: [Migration]
app = sortOn name $ map migration schemaMigrations
  where
    migration (name, up, down) = Migration {name, up = fromQuery up, down = fromQuery <$> down}

getCurrent :: DB.Connection -> IO [Migration]
getCurrent DB.Connection {DB.conn} = map toMigration <$> SQL.query_ conn "SELECT name, down FROM migrations ORDER BY name ASC;"
  where
    toMigration (name, down) = Migration {name, up = "", down}

run :: DBStore -> Bool -> MigrationsToRun -> IO ()
run st vacuum = \case
  MTRUp [] -> pure ()
  MTRUp ms -> do
    mapM_ runUp ms
    when vacuum $ withConnection' st (`execSQL` "VACUUM;")
  MTRDown ms -> mapM_ runDown $ reverse ms
  MTRNone -> pure ()
  where
    runUp Migration {name, up, down} = withTransaction' st $ \db -> do
      when (name == "m20220811_onion_hosts") $ updateServers db
      insert db >> execSQL db up'
      where
        insert db = SQL.execute db "INSERT INTO migrations (name, down, ts) VALUES (?,?,?)" . (name,down,) =<< getCurrentTime
        up'
          | dbNew st && name == "m20230110_users" = fromQuery new_m20230110_users
          | otherwise = up
        updateServers db = forM_ (M.assocs extraSMPServerHosts) $ \(h, h') ->
          let hs = decodeLatin1 . strEncode $ ([h, h'] :: NonEmpty TransportHost)
           in SQL.execute db "UPDATE servers SET host = ? WHERE host = ?" (hs, decodeLatin1 $ strEncode h)
    runDown DownMigration {downName, downQuery} = withTransaction' st $ \db -> do
      execSQL db downQuery
      SQL.execute db "DELETE FROM migrations WHERE name = ?" (Only downName)
    execSQL db = SQLite3.exec $ SQL.connectionHandle db

initialize :: DBStore -> IO ()
initialize st = withTransaction' st $ \db -> do
  cs :: [Text] <- map fromOnly <$> SQL.query_ db "SELECT name FROM pragma_table_info('migrations')"
  case cs of
    [] -> createMigrations db
    _ -> when ("down" `notElem` cs) $ SQL.execute_ db "ALTER TABLE migrations ADD COLUMN down TEXT"
  where
    createMigrations db =
      SQL.execute_
        db
        [sql|
          CREATE TABLE IF NOT EXISTS migrations (
            name TEXT NOT NULL,
            ts TEXT NOT NULL,
            down TEXT,
            PRIMARY KEY (name)
          );
        |]
