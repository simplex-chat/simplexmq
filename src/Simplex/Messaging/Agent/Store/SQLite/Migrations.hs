{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations
  ( initialize,
    run,
    getCurrentMigrations,
  )
where

import Control.Monad (forM_, when)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text.Encoding (decodeLatin1)
import Data.Time.Clock (getCurrentTime)
import Database.SQLite.Simple (Only (..), Query (..))
import qualified Database.SQLite.Simple as SQL
import qualified Database.SQLite3 as SQLite3
import Simplex.Messaging.Agent.Protocol (extraSMPServerHosts)
import qualified Simplex.Messaging.Agent.Store.DB as DB
import Simplex.Messaging.Agent.Store.SQLite.Common
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230110_users
import Simplex.Messaging.Agent.Store.Shared
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Transport.Client (TransportHost)

getCurrentMigrations :: Maybe Query -> DB.Connection -> IO [Migration]
getCurrentMigrations migrationsTable DB.Connection {DB.conn} =
  map toMigration
    <$> SQL.query_ conn ("SELECT name, down FROM " <> table <> " ORDER BY name ASC;")
  where
    table = fromMaybe "migrations" migrationsTable
    toMigration (name, down) = Migration {name, up = "", down}

run :: DBStore -> Maybe Query -> Bool -> MigrationsToRun -> IO ()
run st migrationsTable vacuum = \case
  MTRUp [] -> pure ()
  MTRUp ms -> do
    mapM_ runUp ms
    when vacuum $ withConnection' st (`execSQL` "VACUUM;")
  MTRDown ms -> mapM_ runDown $ reverse ms
  MTRNone -> pure ()
  where
    table = fromMaybe "migrations" migrationsTable
    runUp Migration {name, up, down} = withTransaction' st $ \db -> do
      when (name == "m20220811_onion_hosts") $ updateServers db
      insert db >> execSQL db up'
      where
        insert db = SQL.execute db ("INSERT INTO " <> table <> " (name, down, ts) VALUES (?,?,?)") . (name,down,) =<< getCurrentTime
        up'
          | dbNew st && name == "m20230110_users" = fromQuery new_m20230110_users
          | otherwise = up
        updateServers db = forM_ (M.assocs extraSMPServerHosts) $ \(h, h') ->
          let hs = decodeLatin1 . strEncode $ ([h, h'] :: NonEmpty TransportHost)
           in SQL.execute db "UPDATE servers SET host = ? WHERE host = ?" (hs, decodeLatin1 $ strEncode h)
    runDown DownMigration {downName, downQuery} = withTransaction' st $ \db -> do
      execSQL db downQuery
      SQL.execute db ("DELETE FROM " <> table <> " WHERE name = ?") (Only downName)
    execSQL db = SQLite3.exec $ SQL.connectionHandle db

initialize :: DBStore -> Maybe Query -> IO ()
initialize st migrationsTable = withTransaction' st $ \db -> do
  cs :: [Text] <- map fromOnly <$> SQL.query_ db ("SELECT name FROM pragma_table_info('" <> table <> "')")
  case cs of
    [] -> createMigrations db
    _ -> when ("down" `notElem` cs) $ SQL.execute_ db $ "ALTER TABLE " <> table <> " ADD COLUMN down TEXT"
  where
    table = fromMaybe "migrations" migrationsTable
    createMigrations db =
      SQL.execute_ db $
        "CREATE TABLE IF NOT EXISTS "
          <> table
          <> " (name TEXT NOT NULL PRIMARY KEY, ts TEXT NOT NULL, down TEXT)"
