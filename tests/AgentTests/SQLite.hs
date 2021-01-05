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
    describe "createRcvConn" testCreateRcvConn
    describe "createSndConn" testCreateSndConn

testCreateRcvConn :: SpecWith SQLiteStore
testCreateRcvConn = do
  it "should create receiver connection and return receiver connection data type" $ \store -> do
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

testCreateSndConn :: SpecWith SQLiteStore
testCreateSndConn = do
  it "should create sender connection and return sender connection data type" $ \store -> do
    let sndQueue =
          SendQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              sndId = "5678",
              sndPrivateKey = "abcd",
              encryptKey = "dcba",
              signKey = "edcb",
              status = New,
              ackMode = AckMode On
            }
    createSndConn store "2" sndQueue
      `shouldReturn` Right (SendConnection "2" sndQueue)
