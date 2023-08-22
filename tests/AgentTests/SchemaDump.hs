{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module AgentTests.SchemaDump where

import Control.DeepSeq
import Control.Monad (unless, void)
import Data.List (dropWhileEnd)
import Data.Maybe (fromJust, isJust)
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Agent.Store.SQLite.Migrations (Migration (..), MigrationsToRun (..), toDownMigration)
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import Simplex.Messaging.Util (ifM)
import System.Directory (doesFileExist, removeFile)
import System.Process (readCreateProcess, shell)
import Test.Hspec

testDB :: FilePath
testDB = "tests/tmp/test_agent_schema.db"

appSchema :: FilePath
appSchema = "src/Simplex/Messaging/Agent/Store/SQLite/Migrations/agent_schema.sql"

testSchema :: FilePath
testSchema = "tests/tmp/test_agent_schema.sql"

schemaDumpTest :: Spec
schemaDumpTest = do
  it "verify and overwrite schema dump" testVerifySchemaDump
  it "verify schema down migrations" testSchemaMigrations

testVerifySchemaDump :: IO ()
testVerifySchemaDump = do
  savedSchema <- ifM (doesFileExist appSchema) (readFile appSchema) (pure "")
  savedSchema `deepseq` pure ()
  void $ createSQLiteStore testDB "" Migrations.app MCConsole
  getSchema testDB appSchema `shouldReturn` savedSchema
  removeFile testDB

testSchemaMigrations :: IO ()
testSchemaMigrations = do
  let noDownMigrations = dropWhileEnd (\Migration {down} -> isJust down) Migrations.app
  Right st <- createSQLiteStore testDB "" noDownMigrations MCError
  mapM_ (testDownMigration st) $ drop (length noDownMigrations) Migrations.app
  closeSQLiteStore st
  removeFile testDB
  removeFile testSchema
  where
    testDownMigration st m = do
      putStrLn $ "down migration " <> name m
      let downMigr = fromJust $ toDownMigration m
      schema <- getSchema testDB testSchema
      Migrations.run st $ MTRUp [m]
      schema' <- getSchema testDB testSchema
      schema' `shouldNotBe` schema
      Migrations.run st $ MTRDown [downMigr]
      unless (name m `elem` skipComparisonForDownMigrations) $ do
        schema'' <- getSchema testDB testSchema
        schema'' `shouldBe` schema
      Migrations.run st $ MTRUp [m]
      schema''' <- getSchema testDB testSchema
      schema''' `shouldBe` schema'

skipComparisonForDownMigrations :: [String]
skipComparisonForDownMigrations =
  [ -- on down migration idx_messages_internal_snd_id_ts index moves down to the end of the file
    "m20230814_indexes"
  ]

getSchema :: FilePath -> FilePath -> IO String
getSchema dpPath schemaPath = do
  void $ readCreateProcess (shell $ "sqlite3 " <> dpPath <> " '.schema --indent' > " <> schemaPath) ""
  sch <- readFile schemaPath
  sch `deepseq` pure sch
