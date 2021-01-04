{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module AgentTests.SQLite where

import qualified Database.SQLite.Simple as DB
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Agent.Transmission
import Test.Hspec
import UnliftIO.Directory

testDB :: String
testDB = "smp-agent.test.db"

withStore :: SpecWith SQLiteStore -> Spec
withStore =
  beforeAll (newSQLiteStore testDB)
    . afterAll (\store -> DB.close (conn store) >> removeFile testDB)

storeTests :: Spec
storeTests = withStore do
  describe "store methods" do
    describe "createRcvConnection" testCreateRcvConnection

testCreateRcvConnection :: SpecWith SQLiteStore
testCreateRcvConnection = do
  it "should create connection and return connection data type" $ \store -> do
    let rcvQueue =
          ReceiveQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              rcvId = "1234",
              rcvPrivateKey = "abcd",
              sndId = Just "5678",
              sndKey = Nothing,
              decryptKey = "dcba",
              verifyKey = Nothing,
              status = New,
              ackMode = AckMode On
            }
    createRcvConn store "1" rcvQueue
      `shouldReturn` Right (ReceiveConnection "1" rcvQueue)
