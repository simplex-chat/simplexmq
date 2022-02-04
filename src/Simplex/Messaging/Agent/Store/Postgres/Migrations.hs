{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations where

-- module Simplex.Messaging.Agent.Store.Postgres.Migrations
--   ( Migration (..),
--     app,
--     initialize,
--     get,
--     run,
--   )
-- where

-- import Control.Monad (forM_, void)
-- import Data.Function (on)
-- import Data.List (intercalate, sortBy)
-- import Data.Time.Clock (getCurrentTime)
-- import Database.PostgreSQL.Simple (Connection, Only (..), Query)
-- import qualified Database.PostgreSQL.Simple as DB
-- import Database.PostgreSQL.Simple.SqlQQ (sql)
-- import Database.PostgreSQL.Simple.Internal (exec)
-- import Database.PostgreSQL.Simple.Transaction (withTransaction)
-- import Simplex.Messaging.Agent.Store.Postgres.Migrations.M20220202_initial (m20220202_initial)

-- data Migration = Migration {name :: String, up :: Query}
--   deriving (Show)

-- schemaMigrations :: [(String, Query)]
-- schemaMigrations =
--   [ ("20220101_initial", m20220202_initial)
--   ]

-- -- | The list of migrations in ascending order by date
-- app :: [Migration]
-- app = sortBy (compare `on` name) $ map migration schemaMigrations
--   where
--     migration (name, query) = Migration {name, up = query}

-- get :: Connection -> [Migration] -> IO (Either String [Migration])
-- get conn migrations =
--   migrationsToRun migrations . map fromOnly
--     <$> DB.query_ conn "SELECT name FROM migrations ORDER BY name ASC;"

-- run :: Connection -> [Migration] -> IO ()
-- run conn ms = withTransaction conn . forM_ ms $
--   \Migration {name, up} -> insert name >> exec conn up
--   where
--     insert name = DB.execute conn "INSERT INTO migrations (name, ts) VALUES (?, ?);" . (name,) =<< getCurrentTime

-- initialize :: Connection -> IO ()
-- initialize conn =
--   void $
--     DB.execute_
--       conn
--       [sql|
--     CREATE TABLE IF NOT EXISTS migrations (
--       name TEXT NOT NULL,
--       ts TEXT NOT NULL,
--       PRIMARY KEY (name)
--     );
--   |]

-- migrationsToRun :: [Migration] -> [String] -> Either String [Migration]
-- migrationsToRun appMs [] = Right appMs
-- migrationsToRun [] dbMs = Left $ "database version is newer than the app: " <> intercalate ", " dbMs
-- migrationsToRun (a : as) (d : ds)
--   | name a == d = migrationsToRun as ds
--   | otherwise = Left $ "different migration in the app/database: " <> name a <> " / " <> d
