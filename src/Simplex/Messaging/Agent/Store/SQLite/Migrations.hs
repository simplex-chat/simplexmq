{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations
  ( Migration (..),
    app,
    initialize,
    get,
    run,
  )
where

import Control.Monad (forM_, when)
import Data.List (intercalate, sortBy)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map as M
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text.Encoding (decodeLatin1)
import Data.Time.Clock (getCurrentTime)
import Database.SQLite.Simple (Connection, Only (..), Query (..))
import qualified Database.SQLite.Simple as DB
import Database.SQLite.Simple.QQ (sql)
import qualified Database.SQLite3 as SQLite3
import Simplex.Messaging.Agent.Protocol (extraSMPServerHosts)
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220101_initial
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220301_snd_queue_keys
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220322_notifications
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220608_v2
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220625_v2_ntf_mode
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220811_onion_hosts
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220817_connection_ntfs
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220822_queue_rotation
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Transport.Client (TransportHost)

data Migration = Migration {name :: String, up :: Text}
  deriving (Show)

schemaMigrations :: [(String, Query)]
schemaMigrations =
  [ ("20220101_initial", m20220101_initial),
    ("20220301_snd_queue_keys", m20220301_snd_queue_keys),
    ("20220322_notifications", m20220322_notifications),
    ("20220607_v2", m20220608_v2),
    ("m20220625_v2_ntf_mode", m20220625_v2_ntf_mode),
    ("m20220811_onion_hosts", m20220811_onion_hosts),
    ("m20220817_connection_ntfs", m20220817_connection_ntfs),
    ("m20220822_queue_rotation", m20220822_queue_rotation)
  ]

-- | The list of migrations in ascending order by date
app :: [Migration]
app = sortBy (comparing name) $ map migration schemaMigrations
  where
    migration (name, query) = Migration {name = name, up = fromQuery query}

get :: Connection -> [Migration] -> IO (Either String [Migration])
get conn migrations =
  migrationsToRun migrations . map fromOnly
    <$> DB.query_ conn "SELECT name FROM migrations ORDER BY name ASC;"

run :: Connection -> [Migration] -> IO ()
run conn ms = forM_ ms $ \Migration {name, up} -> do
  when (name == "m20220811_onion_hosts") updateServers
  DB.withImmediateTransaction conn $ insert name >> execSQL up
  where
    insert name = DB.execute conn "INSERT INTO migrations (name, ts) VALUES (?, ?);" . (name,) =<< getCurrentTime
    execSQL = SQLite3.exec $ DB.connectionHandle conn
    updateServers = forM_ (M.assocs extraSMPServerHosts) $ \(h, h') ->
      DB.withImmediateTransaction conn $
        let hs = decodeLatin1 . strEncode $ ([h, h'] :: NonEmpty TransportHost)
         in DB.execute conn "UPDATE servers SET host = ? WHERE host = ?" (hs, decodeLatin1 $ strEncode h)

initialize :: Connection -> IO ()
initialize conn =
  DB.execute_
    conn
    [sql|
      CREATE TABLE IF NOT EXISTS migrations (
        name TEXT NOT NULL,
        ts TEXT NOT NULL,
        PRIMARY KEY (name)
      );
    |]

migrationsToRun :: [Migration] -> [String] -> Either String [Migration]
migrationsToRun appMs [] = Right appMs
migrationsToRun [] dbMs = Left $ "database version is newer than the app: " <> intercalate ", " dbMs
migrationsToRun (a : as) (d : ds)
  | name a == d = migrationsToRun as ds
  | otherwise = Left $ "different migration in the app/database: " <> name a <> " / " <> d
