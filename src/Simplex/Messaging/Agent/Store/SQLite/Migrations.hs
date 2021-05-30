{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations
  ( Migrations (..),
    app,
    initialize,
    get,
    run,
  )
where

import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import Database.SQLite.Simple (Connection, NamedParam (..), Query (..))
import qualified Database.SQLite.Simple as DB
import Database.SQLite.Simple.QQ (sql)
import qualified Database.SQLite3 as SQLite3
import Simplex.Messaging.Agent.Store.SQLite.Migrations.M_20210101_initial (m_20210101_initial)
import Simplex.Messaging.Agent.Store.SQLite.Migrations.Types (SchemaMigration (..))

-- | The list of migrations in ascending order by date
app :: [SchemaMigration]
app =
  [ m_20210101_initial
  ]

get :: Connection -> [SchemaMigration] -> IO Migrations
get conn migrations = migrationsToRun migrations <$> getDbMigrations conn

run :: Connection -> Migrations -> IO ()
run conn migrations =
  DB.withImmediateTransaction conn $ case migrations of
    MigrateUp ms _ -> mapM_ runUp ms
    MigrateDown ms -> mapM_ runDown ms
    _ -> pure ()
  where
    runUp :: SchemaMigration -> IO ()
    runUp SchemaMigration {name, down, up} = do
      ts <- getCurrentTime
      execSQL up
      DB.executeNamed
        conn
        "INSERT INTO migrations (name, down, ts) VALUES (:name, :down, :ts);"
        [":name" := name, ":down" := fromQuery down, ":ts" := ts]
    runDown :: SchemaMigration -> IO ()
    runDown SchemaMigration {name, down} = do
      execSQL down
      DB.executeNamed conn "DELETE FROM migrations WHERE name = :name;" [":name" := name]
    execSQL :: Query -> IO ()
    execSQL q = DB.connectionHandle conn `SQLite3.exec` fromQuery q

initialize :: Connection -> IO ()
initialize conn =
  DB.execute_
    conn
    [sql|
      CREATE TABLE IF NOT EXISTS migrations (
        name TEXT NOT NULL,
        down TEXT NOT NULL,
        ts TEXT NOT NULL,
        PRIMARY KEY (name)
      );
    |]

getDbMigrations :: Connection -> IO [SchemaMigration]
getDbMigrations conn =
  map migration <$> DB.query_ conn "SELECT name, down FROM migrations ORDER BY name ASC;"
  where
    migration :: (String, Text) -> SchemaMigration
    migration (name, down) = SchemaMigration {name, up = "", down = Query down}

data Migrations
  = NoMigration
  | MigrateDown [SchemaMigration]
  | MigrateUp {use :: [SchemaMigration], dbMigrations :: [SchemaMigration]}
  | MigrateError String

migrationsToRun :: [SchemaMigration] -> [SchemaMigration] -> Migrations
migrationsToRun appMigrations dbMigrations = toRun appMigrations dbMigrations
  where
    toRun [] [] = NoMigration
    toRun appMs [] = MigrateUp {use = appMs, dbMigrations}
    toRun [] dbMs = MigrateDown $ reverse dbMs
    toRun (a : as) (d : ds)
      | name a == name d = toRun as ds
      | otherwise = MigrateError "incompatible database migrations"
