module Simplex.Messaging.Agent.Store.Postgres
  ( createPostgresStore,
    closePostgresStore,
    execSQL,
  )
where

import Data.Text (Text)
import qualified Database.PostgreSQL.Simple as DB
import Simplex.Messaging.Agent.Store.Postgres.Common
import Simplex.Messaging.Agent.Store.Shared (Migration (..), MigrationConfirmation (..), MigrationError (..))

-- TODO [postgres] methods
-- createPostgresStore
-- closePostgresStore
-- etc.

-- TODO [postgres] pass db name / ConnectInfo?
createPostgresStore :: MigrationConfirmation -> IO (Either MigrationError PostgresStore)
createPostgresStore = undefined

closePostgresStore :: PostgresStore -> IO ()
closePostgresStore = undefined

execSQL :: DB.Connection -> Text -> IO [Text]
execSQL = undefined

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
