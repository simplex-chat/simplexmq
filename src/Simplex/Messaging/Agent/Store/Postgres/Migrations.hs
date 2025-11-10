{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations
  ( initialize,
    run,
    getCurrentMigrations,
  )
where

import Control.Exception (throwIO)
import Control.Monad (void)
import qualified Data.ByteString.Char8 as B
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (getCurrentTime)
import qualified Database.PostgreSQL.LibPQ as LibPQ
import Database.PostgreSQL.Simple (Only (..), Query)
import qualified Database.PostgreSQL.Simple as PSQL
import Database.PostgreSQL.Simple.Internal (Connection (..))
import Simplex.Messaging.Agent.Store.Postgres.Common
import Simplex.Messaging.Agent.Store.Shared
import Simplex.Messaging.Util (($>>=))
import UnliftIO.MVar

initialize :: DBStore -> Maybe Query -> IO ()
initialize st migrationsTable = withTransaction' st $ \db ->
  void $ PSQL.execute_ db $
    "CREATE TABLE IF NOT EXISTS "
      <> fromMaybe "migrations" migrationsTable
      <> " (name TEXT NOT NULL PRIMARY KEY, ts TIMESTAMP NOT NULL, down TEXT)"

run :: DBStore -> Maybe Query -> MigrationsToRun -> IO ()
run st migrationsTable = \case
  MTRUp [] -> pure ()
  MTRUp ms -> mapM_ runUp ms
  MTRDown ms -> mapM_ runDown $ reverse ms
  MTRNone -> pure ()
  where
    table = fromMaybe "migrations" migrationsTable
    runUp Migration {name, up, down} = withTransaction' st $ \db -> do
      insert db
      execSQL db up
      where
        insert db = void $ PSQL.execute db ("INSERT INTO " <> table <> " (name, down, ts) VALUES (?,?,?)") . (name,down,) =<< getCurrentTime
    runDown DownMigration {downName, downQuery} = withTransaction' st $ \db -> do
      execSQL db downQuery
      void $ PSQL.execute db ("DELETE FROM " <> table <> " WHERE name = ?") (Only downName)
    execSQL db query =
      withMVar (connectionHandle db) $ \pqConn ->
        LibPQ.exec pqConn (TE.encodeUtf8 query) $>>= LibPQ.resultErrorMessage >>= \case
          Just e | not (B.null e) -> throwIO $ userError $ B.unpack e
          _ -> pure ()

getCurrentMigrations :: Maybe Query -> PSQL.Connection -> IO [Migration]
getCurrentMigrations migrationsTable db = map toMigration <$> PSQL.query_ db ("SELECT name, down FROM " <> table <> " ORDER BY name ASC;")
  where
    table = fromMaybe "migrations" migrationsTable
    toMigration (name, down) = Migration {name, up = T.pack "", down}
