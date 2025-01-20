{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations
  ( app,
    initialize,
    run,
    getCurrent,
  )
where

import Control.Monad (void)
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (getCurrentTime)
import qualified Database.PostgreSQL.LibPQ as LibPQ
import Database.PostgreSQL.Simple (Only (..))
import qualified Database.PostgreSQL.Simple as PSQL
import Database.PostgreSQL.Simple.Internal (Connection (..))
import Database.PostgreSQL.Simple.SqlQQ (sql)
import Simplex.Messaging.Agent.Store.Postgres.Common
import Simplex.Messaging.Agent.Store.Postgres.Migrations.M20241210_initial
import Simplex.Messaging.Agent.Store.Shared
import UnliftIO.MVar

schemaMigrations :: [(String, Text, Maybe Text)]
schemaMigrations =
  [ ("20241210_initial", m20241210_initial, Nothing)
  ]

-- | The list of migrations in ascending order by date
app :: [Migration]
app = sortOn name $ map migration schemaMigrations
  where
    migration (name, up, down) = Migration {name, up, down = down}

initialize :: DBStore -> IO ()
initialize st = withTransaction' st $ \db ->
  void $
    PSQL.execute_
      db
      [sql|
      CREATE TABLE IF NOT EXISTS migrations (
        name TEXT NOT NULL,
        ts TIMESTAMP NOT NULL,
        down TEXT,
        PRIMARY KEY (name)
      )
    |]

run :: DBStore -> Bool -> MigrationsToRun -> IO ()
run st _vacuum = \case
  MTRUp [] -> pure ()
  MTRUp ms -> mapM_ runUp ms
  MTRDown ms -> mapM_ runDown $ reverse ms
  MTRNone -> pure ()
  where
    runUp Migration {name, up, down} = withTransaction' st $ \db -> do
      insert db
      execSQL db up
      where
        insert db = void $ PSQL.execute db "INSERT INTO migrations (name, down, ts) VALUES (?,?,?)" . (name,down,) =<< getCurrentTime
    runDown DownMigration {downName, downQuery} = withTransaction' st $ \db -> do
      execSQL db downQuery
      void $ PSQL.execute db "DELETE FROM migrations WHERE name = ?" (Only downName)
    execSQL db query =
      withMVar (connectionHandle db) $ \pqConn ->
        void $ LibPQ.exec pqConn (TE.encodeUtf8 query)

getCurrent :: PSQL.Connection -> IO [Migration]
getCurrent db = map toMigration <$> PSQL.query_ db "SELECT name, down FROM migrations ORDER BY name ASC;"
  where
    toMigration (name, down) = Migration {name, up = T.pack "", down}
