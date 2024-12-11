module Simplex.Messaging.Agent.Store.Postgres where

-- TODO [postgres] methods
-- createPostgresStore
-- migrateSchema
-- closePostgresStore
-- etc.

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
