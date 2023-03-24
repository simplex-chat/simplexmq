{-# LANGUAGE OverloadedStrings #-}

module AgentTests.MigrationTests (migrationTests) where

import Data.Maybe (fromJust)
import Simplex.Messaging.Agent.Store.SQLite.Migrations
import Test.Hspec

migrationTests :: Spec
migrationTests = do
  fdescribe "up migrations" $ do
    it "should determine migrations to run" testMigrationsToRun

m1 :: Migration
m1 = Migration "20230301-migration1" "create table test1 (id1 integer primary key);" Nothing

m1' :: Migration
m1' = Migration "20230301-migration1" "create table test1 (id1 integer primary key);" (Just "drop table test1;")

m2 :: Migration
m2 = Migration "20230302-migration2" "create table test2 (id2 integer primary key);" Nothing

m2' :: Migration
m2' = Migration "20230302-migration2" "create table test2 (id2 integer primary key);" (Just "drop table test2;")

m3 :: Migration
m3 = Migration "20230303-migration3" "create table test3 (id3 integer primary key);" Nothing

m3' :: Migration
m3' = Migration "20230303-migration3" "create table test3 (id3 integer primary key);" (Just "drop table test3;")

m4 :: Migration
m4 = Migration "20230304-migration4" "create table test4 (id4 integer primary key);" Nothing

m4' :: Migration
m4' = Migration "20230304-migration4" "create table test4 (id4 integer primary key);" (Just "drop table test4;")

downMigration :: Migration -> DownMigration
downMigration = fromJust . toDownMigration

testMigrationsToRun :: IO ()
testMigrationsToRun = do
  migrationsToRun [] [] `shouldBe` Right MTRNone
  migrationsToRun [m1] [] `shouldBe` Right (MTRUp [m1])
  migrationsToRun [] [m1] `shouldBe` Left "database version is newer than the app, but no down migration for: 20230301-migration1"
  migrationsToRun [] [m1'] `shouldBe` Right (MTRDown [downMigration m1'])
  migrationsToRun [m1, m2] [] `shouldBe` Right (MTRUp [m1, m2])
  migrationsToRun [] [m1, m2] `shouldBe` Left "database version is newer than the app, but no down migration for: 20230301-migration1, 20230302-migration2"
  migrationsToRun [] [m1', m2] `shouldBe` Left "database version is newer than the app, but no down migration for: 20230302-migration2"
  migrationsToRun [] [m1, m2'] `shouldBe` Left "database version is newer than the app, but no down migration for: 20230301-migration1"
  migrationsToRun [] [m1', m2'] `shouldBe` Right (MTRDown [downMigration m1', downMigration m2'])
  migrationsToRun [m1] [m1] `shouldBe` Right MTRNone
  migrationsToRun [m1] [m1'] `shouldBe` Right MTRNone
  migrationsToRun [m1'] [m1] `shouldBe` Right MTRNone
  migrationsToRun [m1, m2] [m1] `shouldBe` Right (MTRUp [m2])
  migrationsToRun [m1] [m1, m2] `shouldBe` Left "database version is newer than the app, but no down migration for: 20230302-migration2"
  migrationsToRun [m1] [m1, m2'] `shouldBe` Right (MTRDown [downMigration m2'])
  migrationsToRun [m1, m2, m3] [m1] `shouldBe` Right (MTRUp [m2, m3])
  migrationsToRun [m1] [m1, m2, m3] `shouldBe` Left "database version is newer than the app, but no down migration for: 20230302-migration2, 20230303-migration3"
  migrationsToRun [m1] [m1, m2', m3] `shouldBe` Left "database version is newer than the app, but no down migration for: 20230303-migration3"
  migrationsToRun [m1] [m1, m2, m3'] `shouldBe` Left "database version is newer than the app, but no down migration for: 20230302-migration2"
  migrationsToRun [m1] [m1, m2', m3'] `shouldBe` Right (MTRDown [downMigration m2', downMigration m3'])
  migrationsToRun [m1, m2] [m1, m2] `shouldBe` Right MTRNone
  migrationsToRun [m1', m2'] [m1, m2] `shouldBe` Right MTRNone
  migrationsToRun [m1, m2] [m1, m2'] `shouldBe` Right MTRNone
  migrationsToRun [m1, m2, m3] [m1, m2] `shouldBe` Right (MTRUp [m3])
  migrationsToRun [m1, m2, m3, m4] [m1, m2] `shouldBe` Right (MTRUp [m3, m4])
  migrationsToRun [m1, m2] [m1, m2, m3, m4] `shouldBe` Left "database version is newer than the app, but no down migration for: 20230303-migration3, 20230304-migration4"
  migrationsToRun [m1, m2] [m1, m2, m3', m4] `shouldBe` Left "database version is newer than the app, but no down migration for: 20230304-migration4"
  migrationsToRun [m1, m2] [m1, m2, m3, m4'] `shouldBe` Left "database version is newer than the app, but no down migration for: 20230303-migration3"
  migrationsToRun [m1, m2] [m1, m2, m3', m4'] `shouldBe` Right (MTRDown [downMigration m3', downMigration m4'])
