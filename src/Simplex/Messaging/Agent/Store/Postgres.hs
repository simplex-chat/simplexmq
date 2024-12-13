{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Agent.Store.Postgres
  ( createDBStore,
    closeDBStore,
    execSQL,
  )
where

import Control.Exception (throwIO)
import Data.Text (Text)
import qualified Database.PostgreSQL.Simple as PSQL
import Simplex.Messaging.Agent.Store.Postgres.Common
import qualified Simplex.Messaging.Agent.Store.Postgres.DB as DB
import Simplex.Messaging.Agent.Store.Shared (Migration (..), MigrationConfirmation (..), MigrationError (..))
import Simplex.Messaging.Util (ifM)
import UnliftIO.STM

-- TODO [postgres] pass db name / ConnectInfo?
createDBStore :: [Migration] -> MigrationConfirmation -> IO (Either MigrationError DBStore)
createDBStore = undefined

-- can share with SQLite
closeDBStore :: DBStore -> IO ()
closeDBStore st@DBStore {dbClosed} =
  ifM (readTVarIO dbClosed) (putStrLn "closeDBStore: already closed") $
    withConnection st $ \conn -> do
      DB.close conn
      atomically $ writeTVar dbClosed True

-- TODO [postgres] not necessary for postgres (used for ExecAgentStoreSQL, ExecChatStoreSQL)
execSQL :: PSQL.Connection -> Text -> IO [Text]
execSQL _db _query = throwIO (userError "not implemented")

-- createDatabaseIfNotExists :: ConnectInfo -> String -> IO ()
-- createDatabaseIfNotExists defaultConnectInfo targetDbName = do
--     -- Connect to the default maintenance database (e.g., postgres)
--     bracket (connect defaultConnectInfo) close $ \conn -> do
--         -- Check if the database already exists
--         [Only dbExists] <- query conn
--             [sql|
--                 SELECT EXISTS (
--                     SELECT 1 FROM pg_catalog.pg_database
--                     WHERE datname = ?
--                 )
--             |] (Only targetDbName)

--         -- If it doesn't exist, create the database
--         if not dbExists
--             then do
--                 putStrLn $ "Creating database: " ++ targetDbName
--                 execute_ conn (Query $ "CREATE DATABASE " <> targetDbName)
--                 putStrLn "Database created."
--             else putStrLn "Database already exists."
