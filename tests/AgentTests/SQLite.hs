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
    describe "addSndQueue" testAddSndQueue
    describe "addRcvQueue" testAddRcvQueue

testCreateRcvConn :: SpecWith SQLiteStore
testCreateRcvConn = do
  it "should create receive connection and add send queue" $ \store -> do
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
    getConn store "1"
      `shouldReturn` Right (SomeConn SCReceive $ ReceiveConnection "1" rcvQueue)
    let sndQueue =
          SendQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              sndId = "1234",
              sndPrivateKey = "abcd",
              encryptKey = "dcba",
              signKey = "edcb",
              status = New,
              ackMode = AckMode On
            }
    addSndQueue store "1" sndQueue
      `shouldReturn` Right ()
    getConn store "1"
      `shouldReturn` Right (SomeConn SCDuplex $ DuplexConnection "1" rcvQueue sndQueue)

testCreateSndConn :: SpecWith SQLiteStore
testCreateSndConn = do
  it "should create send connection and add receive queue" $ \store -> do
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
    getConn store "2"
      `shouldReturn` Right (SomeConn SCSend $ SendConnection "2" sndQueue)
    let rcvQueue =
          ReceiveQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              rcvId = "2345",
              rcvPrivateKey = "abcd",
              sndId = Just "2345",
              sndKey = Nothing,
              decryptKey = "dcba",
              verifyKey = Nothing,
              status = New,
              ackMode = AckMode On
            }
    addRcvQueue store "2" rcvQueue
      `shouldReturn` Right ()
    getConn store "2"
      `shouldReturn` Right (SomeConn SCDuplex $ DuplexConnection "2" rcvQueue sndQueue)

testAddSndQueue :: SpecWith SQLiteStore
testAddSndQueue = do
  it "should return error on attempts to add send queue to SendConnection or DuplexConnection" $ \store -> do
    let sndQueue =
          SendQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              sndId = "6789",
              sndPrivateKey = "abcd",
              encryptKey = "dcba",
              signKey = "edcb",
              status = New,
              ackMode = AckMode On
            }
    _ <- createSndConn store "3" sndQueue
    let anotherSndQueue =
          SendQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              sndId = "7890",
              sndPrivateKey = "abcd",
              encryptKey = "dcba",
              signKey = "edcb",
              status = New,
              ackMode = AckMode On
            }
    addSndQueue store "3" anotherSndQueue
      `shouldReturn` Left (SEBadConnType CSend)
    let rcvQueue =
          ReceiveQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              rcvId = "6789",
              rcvPrivateKey = "abcd",
              sndId = Just "6789",
              sndKey = Nothing,
              decryptKey = "dcba",
              verifyKey = Nothing,
              status = New,
              ackMode = AckMode On
            }
    _ <- addRcvQueue store "3" rcvQueue
    addSndQueue store "3" anotherSndQueue
      `shouldReturn` Left (SEBadConnType CDuplex)

testAddRcvQueue :: SpecWith SQLiteStore
testAddRcvQueue = do
  it "should return error on attempts to add receive queue to ReceiveConnection or DuplexConnection" $ \store -> do
    let rcvQueue =
          ReceiveQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              rcvId = "3456",
              rcvPrivateKey = "abcd",
              sndId = Just "3456",
              sndKey = Nothing,
              decryptKey = "dcba",
              verifyKey = Nothing,
              status = New,
              ackMode = AckMode On
            }
    _ <- createRcvConn store "4" rcvQueue
    let anotherRcvQueue =
          ReceiveQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              rcvId = "4567",
              rcvPrivateKey = "abcd",
              sndId = Just "4567",
              sndKey = Nothing,
              decryptKey = "dcba",
              verifyKey = Nothing,
              status = New,
              ackMode = AckMode On
            }
    addRcvQueue store "4" anotherRcvQueue
      `shouldReturn` Left (SEBadConnType CReceive)
    let sndQueue =
          SendQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              sndId = "3456",
              sndPrivateKey = "abcd",
              encryptKey = "dcba",
              signKey = "edcb",
              status = New,
              ackMode = AckMode On
            }
    _ <- addSndQueue store "4" sndQueue
    addRcvQueue store "4" anotherRcvQueue
      `shouldReturn` Left (SEBadConnType CDuplex)
