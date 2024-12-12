module Simplex.Messaging.Agent.Store.Postgres
  ( createDBStore,
    closeDBStore,
    execSQL,
  )
where

import Data.Text (Text)
import qualified Database.PostgreSQL.Simple as PSQL
import Simplex.Messaging.Agent.Store.Postgres.Common
import Simplex.Messaging.Agent.Store.Shared (Migration (..), MigrationConfirmation (..), MigrationError (..))

-- TODO [postgres] pass db name / ConnectInfo?
createDBStore :: [Migration] -> MigrationConfirmation -> IO (Either MigrationError DBStore)
createDBStore = undefined

closeDBStore :: DBStore -> IO ()
closeDBStore = undefined

execSQL :: PSQL.Connection -> Text -> IO [Text]
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
