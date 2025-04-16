{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module ServerTests.SchemaDump where

import Control.Concurrent (threadDelay)
import Control.DeepSeq
import Control.Monad (unless, void)
import qualified Data.ByteString.Char8 as B
import Data.List (dropWhileEnd)
import Data.Maybe (fromJust, isJust)
import SMPClient
import Simplex.Messaging.Agent.Store.Postgres (closeDBStore, createDBStore)
import Simplex.Messaging.Agent.Store.Postgres.Common (DBOpts (..))
import qualified Simplex.Messaging.Agent.Store.Postgres.Migrations as Migrations
import Simplex.Messaging.Agent.Store.Shared (Migration (..), MigrationConfirmation (..), MigrationsToRun (..), toDownMigration)
import Simplex.Messaging.Server.QueueStore.Postgres.Migrations (serverMigrations)
import Simplex.Messaging.Util (ifM)
import System.Directory (doesFileExist, removeFile)
import System.Environment (lookupEnv)
import System.Process (readCreateProcess, readCreateProcessWithExitCode, shell)
import Test.Hspec

testDBSchema :: B.ByteString
testDBSchema = "smp_server"

serverSchemaPath :: FilePath
serverSchemaPath = "src/Simplex/Messaging/Server/QueueStore/Postgres/server_schema.sql"

testSchemaPath :: FilePath
testSchemaPath = "tests/tmp/test_server_schema.sql"

testServerDBOpts :: DBOpts
testServerDBOpts = 
  DBOpts
    { connstr = testServerDBConnstr,
      schema = testDBSchema,
      poolSize = 3,
      createSchema = True
    }

serverSchemaDumpTest :: Spec
serverSchemaDumpTest = do
  it "verify and overwrite schema dump" testVerifySchemaDump
  it "verify schema down migrations" testSchemaMigrations

testVerifySchemaDump :: IO ()
testVerifySchemaDump = do
  savedSchema <- ifM (doesFileExist serverSchemaPath) (readFile serverSchemaPath) (pure "")
  savedSchema `deepseq` pure ()
  void $ createDBStore testServerDBOpts serverMigrations MCConsole
  getSchema serverSchemaPath `shouldReturn` savedSchema

testSchemaMigrations :: IO ()
testSchemaMigrations = do
  let noDownMigrations = dropWhileEnd (\Migration {down} -> isJust down) serverMigrations
  Right st <- createDBStore testServerDBOpts noDownMigrations MCError
  mapM_ (testDownMigration st) $ drop (length noDownMigrations) serverMigrations
  closeDBStore st
  removeFile testSchemaPath
  where
    testDownMigration st m = do
      putStrLn $ "down migration " <> name m
      let downMigr = fromJust $ toDownMigration m
      schema <- getSchema testSchemaPath
      Migrations.run st $ MTRUp [m]
      schema' <- getSchema testSchemaPath
      schema' `shouldNotBe` schema
      Migrations.run st $ MTRDown [downMigr]
      unless (name m `elem` skipComparisonForDownMigrations) $ do
        schema'' <- getSchema testSchemaPath
        schema'' `shouldBe` schema
      Migrations.run st $ MTRUp [m]
      schema''' <- getSchema testSchemaPath
      schema''' `shouldBe` schema'

skipComparisonForDownMigrations :: [String]
skipComparisonForDownMigrations =
  [ -- snd_secure moves to the bottom on down migration
    "20250320_short_links"
  ]

getSchema :: FilePath -> IO String
getSchema schemaPath = do
  ci <- (Just "true" ==) <$> lookupEnv "CI"
  let cmd =
        ("pg_dump " <> B.unpack testServerDBConnstr <> " --schema " <> B.unpack testDBSchema)
          <> " --schema-only --no-owner --no-privileges --no-acl --no-subscriptions --no-tablespaces > "
          <> schemaPath
  (code, out, err) <- readCreateProcessWithExitCode (shell cmd) ""
  threadDelay 20000
  let sed = (if ci then "sed -i" else "sed -i ''")
  void $ readCreateProcess (shell $ sed <> " '/^--/d' " <> schemaPath) ""
  sch <- readFile schemaPath
  sch `deepseq` pure sch
