{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.Postgres.Util
  ( createDBAndUserIfNotExists,
    dropSchema,
    dropAllSchemasExceptSystem,
    dropDatabaseAndUser,
  )
where

import Control.Exception (bracket)
import Control.Monad (forM_, unless, void, when)
import Data.String (fromString)
import Database.PostgreSQL.Simple (ConnectInfo (..), Only (..), defaultConnectInfo)
import qualified Database.PostgreSQL.Simple as PSQL
import Database.PostgreSQL.Simple.SqlQQ (sql)

createDBAndUserIfNotExists :: ConnectInfo -> IO ()
createDBAndUserIfNotExists ConnectInfo {connectUser = user, connectDatabase = dbName} = do
  -- connect to the default "postgres" maintenance database
  bracket (PSQL.connect defaultConnectInfo {connectUser = "postgres", connectDatabase = "postgres"}) PSQL.close $ \db -> do
    execSQL db "SET client_min_messages TO WARNING"
    -- check if the user exists, create if not
    [Only userExists] <-
      PSQL.query
        db
        [sql|
          SELECT EXISTS (
            SELECT 1 FROM pg_catalog.pg_roles
            WHERE rolname = ?
          )
        |]
        (Only user)
    unless userExists $ execSQL db $ "CREATE USER " <> user
    -- check if the database exists, create if not
    dbExists <- checkDBExists db dbName
    unless dbExists $ do
      execSQL db $ "CREATE DATABASE " <> dbName <> " OWNER " <> user
      bracket (PSQL.connect defaultConnectInfo {connectUser = "postgres", connectDatabase = dbName}) PSQL.close $
        (`execSQL` "CREATE EXTENSION IF NOT EXISTS pgcrypto")

checkDBExists :: PSQL.Connection -> String -> IO Bool
checkDBExists db dbName = do
  [Only dbExists] <-
    PSQL.query
      db
      [sql|
        SELECT EXISTS (
          SELECT 1 FROM pg_catalog.pg_database
          WHERE datname = ?
        )
      |]
      (Only dbName)
  pure dbExists

dropSchema :: ConnectInfo -> String -> IO ()
dropSchema connectInfo schema =
  bracket (PSQL.connect connectInfo) PSQL.close $ \db -> do
    execSQL db "SET client_min_messages TO WARNING"
    execSQL db $ "DROP SCHEMA IF EXISTS " <> schema <> " CASCADE"

dropAllSchemasExceptSystem :: ConnectInfo -> IO ()
dropAllSchemasExceptSystem connectInfo =
  bracket (PSQL.connect connectInfo) PSQL.close $ \db -> do
    execSQL db "SET client_min_messages TO WARNING"
    schemaNames :: [Only String] <-
      PSQL.query_
        db
        [sql|
          SELECT schema_name
          FROM information_schema.schemata
          WHERE schema_name NOT IN ('public', 'pg_catalog', 'information_schema')
        |]
    forM_ schemaNames $ \(Only schema) ->
      execSQL db $ "DROP SCHEMA " <> schema <> " CASCADE"

dropDatabaseAndUser :: ConnectInfo -> IO ()
dropDatabaseAndUser ConnectInfo {connectUser = user, connectDatabase = dbName} =
  bracket (PSQL.connect defaultConnectInfo {connectUser = "postgres", connectDatabase = "postgres"}) PSQL.close $ \db -> do
    execSQL db "SET client_min_messages TO WARNING"
    dbExists <- checkDBExists db dbName
    when dbExists $ do
      execSQL db $ "ALTER DATABASE " <> dbName <> " WITH ALLOW_CONNECTIONS false"
      -- terminate all connections to the database
      _r :: [Only Bool] <-
        PSQL.query
          db
          [sql|
            SELECT pg_terminate_backend(pg_stat_activity.pid)
            FROM pg_stat_activity
            WHERE datname = ?
              AND pid <> pg_backend_pid()
          |]
          (Only dbName)
      execSQL db $ "DROP DATABASE " <> dbName
    execSQL db $ "DROP USER IF EXISTS " <> user

execSQL :: PSQL.Connection -> String -> IO ()
execSQL db = void . PSQL.execute_ db . fromString
