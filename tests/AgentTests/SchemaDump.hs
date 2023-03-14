{-# LANGUAGE OverloadedStrings #-}

module AgentTests.SchemaDump where

import Control.DeepSeq
import Control.Monad (void)
import Simplex.Messaging.Agent.Store.SQLite
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import System.Process (readCreateProcess, shell)
import Test.Hspec

testDB :: FilePath
testDB = "tests/tmp/test_agent_schema.db"

schema :: FilePath
schema = "src/Simplex/Messaging/Agent/Store/SQLite/Migrations/agent_schema.sql"

schemaDumpTest :: Spec
schemaDumpTest =
  it "verify and overwrite schema dump" testVerifySchemaDump

testVerifySchemaDump :: IO ()
testVerifySchemaDump = do
  void $ createSQLiteStore testDB "" Migrations.app False
  void $ readCreateProcess (shell $ "touch " <> schema) ""
  savedSchema <- readFile schema
  savedSchema `deepseq` pure ()
  void $ readCreateProcess (shell $ "sqlite3 " <> testDB <> " '.schema --indent' > " <> schema) ""
  currentSchema <- readFile schema
  savedSchema `shouldBe` currentSchema
