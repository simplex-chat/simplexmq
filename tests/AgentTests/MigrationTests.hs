{-# LANGUAGE OverloadedStrings #-}

module AgentTests.MigrationTests (migrationTests) where

import Control.Monad
import Data.Maybe (fromJust)
import Data.Word (Word32)
import Database.SQLite.Simple (fromOnly)
import Simplex.Messaging.Agent.Store.SQLite (MigrationConfirmation (..), MigrationError (MEDowngrade, MEUpgrade, MigrationError), SQLiteStore, closeSQLiteStore, createSQLiteStore, upMigration, withTransaction)
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import Simplex.Messaging.Agent.Store.SQLite.Migrations
import System.Directory (removeFile)
import System.Random (randomIO)
import Test.Hspec

migrationTests :: Spec
migrationTests = do
  it "should determine migrations to run" testMigrationsToRun
  describe "run migrations" $ do
    -- (init migrs, tables)
    -- (final migrs, confirm modes, final tables or error)
    it "up 1-2 tables (yes)" $
      testMigration
        ([m1], [t1])
        ([m1, m2], [MCYesUp, MCYesUpDown], Right [t1, t2])
    it "up 1-2 tables (error)" $
      testMigration
        ([m1], [t1])
        ([m1, m2], [MCError], Left $ MEUpgrade [upMigration m2])
    it "up 1-2 tables (error, down)" $
      testMigration
        ([m1], [t1])
        ([m1, m2'], [MCError], Left $ MEUpgrade [upMigration m2'])
    it "1-2 (different)" $
      testMigration
        ([m2], [t2])
        ([m1, m2], [MCYesUp, MCYesUpDown, MCError], Left $ MigrationError $ MTREDifferent (name m1) (name m2))
    it "up 2-4 tables (yes)" $
      testMigration
        ([m1, m2], [t1, t2])
        ([m1, m2, m3, m4], [MCYesUp, MCYesUpDown], Right [t1, t2, t3, t4])
    it "up 2-4 tables (error)" $
      testMigration
        ([m1, m2], [t1, t2])
        ([m1, m2, m3, m4], [MCError], Left $ MEUpgrade [upMigration m3, upMigration m4])
    it "up 2-4 tables (error, down)" $
      testMigration
        ([m1, m2], [t1, t2])
        ([m1, m2, m3', m4'], [MCError], Left $ MEUpgrade [upMigration m3', upMigration m4'])
    it "no change 2 tables" $
      testMigration
        ([m1, m2], [t1, t2])
        ([m1, m2], [MCYesUp, MCYesUpDown, MCError], Right [t1, t2])
    it "2 tables (different order)" $
      testMigration
        ([m1, m2], [t1, t2])
        ([m2, m1], [MCYesUp, MCYesUpDown, MCError], Left $ MigrationError $ MTREDifferent (name m2) (name m1))
    it "down 2-1 tables (no down)" $
      testMigration
        ([m1, m2], [t1, t2])
        ([m1], [MCYesUp, MCYesUpDown, MCError], Left . MigrationError $ MTRENoDown [name m2])
    it "down 2-1 tables (error)" $
      testMigration
        ([m1, m2'], [t1, t2])
        ([m1], [MCYesUp, MCError], Left $ MEDowngrade [name m2])
    it "down 2-1 tables (yes)" $
      testMigration
        ([m1, m2'], [t1, t2])
        ([m1], [MCYesUpDown], Right [t1])
    it "down 4-2 tables (no down)" $
      testMigration
        ([m1, m2, m3, m4], [t1, t2, t3, t4])
        ([m1, m2], [MCYesUp, MCYesUpDown, MCError], Left . MigrationError $ MTRENoDown [name m3, name m4])
    it "down 4-2 tables (partial down)" $ do
      testMigration
        ([m1, m2, m3, m4'], [t1, t2, t3, t4])
        ([m1, m2], [MCYesUp, MCYesUpDown, MCError], Left . MigrationError $ MTRENoDown [name m3])
      testMigration
        ([m1, m2, m3', m4], [t1, t2, t3, t4])
        ([m1, m2], [MCYesUp, MCYesUpDown, MCError], Left . MigrationError $ MTRENoDown [name m4])
    it "down 4-2 tables (error)" $
      testMigration
        ([m1, m2, m3', m4'], [t1, t2, t3, t4])
        ([m1, m2], [MCYesUp, MCError], Left $ MEDowngrade [name m3, name m4])
    it "down 4-2 tables (yes)" $
      testMigration
        ([m1, m2, m3', m4'], [t1, t2, t3, t4])
        ([m1, m2], [MCYesUpDown], Right [t1, t2])
    it "4-2 tables (different)" $
      testMigration
        ([m1, m2, m3', m4'], [t1, t2, t3, t4])
        ([m1, m3], [MCYesUp, MCYesUpDown, MCError], Left . MigrationError $ MTREDifferent (name m3) (name m2))
    it "4-3 tables (different)" $
      testMigration
        ([m1, m2, m3, m4], [t1, t2, t3, t4])
        ([m1, m2, m4], [MCYesUp, MCYesUpDown, MCError], Left . MigrationError $ MTREDifferent (name m4) (name m3))

testDB :: FilePath
testDB = "tests/tmp/test_migrations.db"

m1 :: Migration
m1 = Migration "20230301-migration1" "create table test1 (id1 integer primary key);" Nothing

m1' :: Migration
m1' = Migration "20230301-migration1" "create table test1 (id1 integer primary key);" (Just "drop table test1;")

t1 :: String
t1 = "test1"

m2 :: Migration
m2 = Migration "20230302-migration2" "create table test2 (id2 integer primary key);" Nothing

m2' :: Migration
m2' = Migration "20230302-migration2" "create table test2 (id2 integer primary key);" (Just "drop table test2;")

t2 :: String
t2 = "test2"

m3 :: Migration
m3 = Migration "20230303-migration3" "create table test3 (id3 integer primary key);" Nothing

m3' :: Migration
m3' = Migration "20230303-migration3" "create table test3 (id3 integer primary key);" (Just "drop table test3;")

t3 :: String
t3 = "test3"

m4 :: Migration
m4 = Migration "20230304-migration4" "create table test4 (id4 integer primary key);" Nothing

m4' :: Migration
m4' = Migration "20230304-migration4" "create table test4 (id4 integer primary key);" (Just "drop table test4;")

t4 :: String
t4 = "test4"

downMigration :: Migration -> DownMigration
downMigration = fromJust . toDownMigration

testMigrationsToRun :: IO ()
testMigrationsToRun = do
  migrationsToRun [] [] `shouldBe` Right MTRNone
  migrationsToRun [m1] [] `shouldBe` Right (MTRUp [m1])
  migrationsToRun [] [m1] `shouldBe` Left (MTRENoDown ["20230301-migration1"])
  migrationsToRun [] [m1'] `shouldBe` Right (MTRDown [downMigration m1'])
  migrationsToRun [m1, m2] [] `shouldBe` Right (MTRUp [m1, m2])
  migrationsToRun [] [m1, m2] `shouldBe` Left (MTRENoDown ["20230301-migration1", "20230302-migration2"])
  migrationsToRun [] [m1', m2] `shouldBe` Left (MTRENoDown ["20230302-migration2"])
  migrationsToRun [] [m1, m2'] `shouldBe` Left (MTRENoDown ["20230301-migration1"])
  migrationsToRun [] [m1', m2'] `shouldBe` Right (MTRDown [downMigration m1', downMigration m2'])
  migrationsToRun [m1] [m1] `shouldBe` Right MTRNone
  migrationsToRun [m1] [m1'] `shouldBe` Right MTRNone
  migrationsToRun [m1'] [m1] `shouldBe` Right MTRNone
  migrationsToRun [m1] [m2] `shouldBe` Left (MTREDifferent "20230301-migration1" "20230302-migration2")
  migrationsToRun [m1, m2] [m1] `shouldBe` Right (MTRUp [m2])
  migrationsToRun [m1] [m1, m2] `shouldBe` Left (MTRENoDown ["20230302-migration2"])
  migrationsToRun [m1] [m1, m2'] `shouldBe` Right (MTRDown [downMigration m2'])
  migrationsToRun [m1, m2, m3] [m1] `shouldBe` Right (MTRUp [m2, m3])
  migrationsToRun [m1] [m1, m2, m3] `shouldBe` Left (MTRENoDown ["20230302-migration2", "20230303-migration3"])
  migrationsToRun [m1] [m1, m2', m3] `shouldBe` Left (MTRENoDown ["20230303-migration3"])
  migrationsToRun [m1] [m1, m2, m3'] `shouldBe` Left (MTRENoDown ["20230302-migration2"])
  migrationsToRun [m1] [m1, m2', m3'] `shouldBe` Right (MTRDown [downMigration m2', downMigration m3'])
  migrationsToRun [m1, m2] [m1, m2] `shouldBe` Right MTRNone
  migrationsToRun [m1, m2] [m2] `shouldBe` Left (MTREDifferent "20230301-migration1" "20230302-migration2")
  migrationsToRun [m1', m2'] [m1, m2] `shouldBe` Right MTRNone
  migrationsToRun [m1, m2] [m1, m2'] `shouldBe` Right MTRNone
  migrationsToRun [m1, m2, m3] [m1, m2] `shouldBe` Right (MTRUp [m3])
  migrationsToRun [m1, m2, m3, m4] [m1, m2] `shouldBe` Right (MTRUp [m3, m4])
  migrationsToRun [m1, m2] [m1, m2, m3, m4] `shouldBe` Left (MTRENoDown ["20230303-migration3", "20230304-migration4"])
  migrationsToRun [m1, m2] [m1, m2, m3', m4] `shouldBe` Left (MTRENoDown ["20230304-migration4"])
  migrationsToRun [m1, m2] [m1, m2, m3, m4'] `shouldBe` Left (MTRENoDown ["20230303-migration3"])
  migrationsToRun [m1, m2] [m1, m2, m3', m4'] `shouldBe` Right (MTRDown [downMigration m3', downMigration m4'])

testMigration ::
  ([Migration], [String]) ->
  ([Migration], [MigrationConfirmation], Either MigrationError [String]) ->
  IO ()
testMigration (initMs, initTables) (finalMs, confirmModes, tablesOrError) = forM_ confirmModes $ \confirmMode -> do
  r <- randomIO :: IO Word32
  let dpPath = testDB <> show r
  Right st <- createSQLiteStore dpPath "" initMs MCError
  st `shouldHaveTables` initTables
  closeSQLiteStore st
  case tablesOrError of
    Right tables -> do
      Right st' <- createSQLiteStore dpPath "" finalMs confirmMode
      st' `shouldHaveTables` tables
      closeSQLiteStore st'
    Left e -> do
      Left e' <- createSQLiteStore dpPath "" finalMs confirmMode
      e `shouldBe` e'
  removeFile dpPath
  where
    shouldHaveTables :: SQLiteStore -> [String] -> IO ()
    st `shouldHaveTables` expected = do
      tables <- map fromOnly <$> withTransaction st (`DB.query_` "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY 1;")
      tables `shouldBe` "migrations" : expected
