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
  before (newSQLiteStore testDB)
    . after (\store -> DB.close (conn store) >> removeFile testDB)

storeTests :: Spec
storeTests = withStore do
  describe "store methods" do
    describe "createRcvConn" testCreateRcvConn
    describe "createSndConn" testCreateSndConn
    describe "addSndQueue" testAddSndQueue
    describe "addRcvQueue" testAddRcvQueue
    describe "deleteConnReceive" testDeleteConnReceive
    describe "deleteConnSend" testDeleteConnSend
    describe "deleteConnDuplex" testDeleteConnDuplex

testCreateRcvConn :: SpecWith SQLiteStore
testCreateRcvConn = do
  it "should create receive connection and add send queue" $ \store -> do
    let rcvQueue =
          ReceiveQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              rcvId = "1234",
              rcvPrivateKey = "abcd",
              sndId = Just "2345",
              sndKey = Nothing,
              decryptKey = "dcba",
              verifyKey = Nothing,
              status = New,
              ackMode = AckMode On
            }
    createRcvConn store "conn1" rcvQueue
      `shouldReturn` Right (ReceiveConnection "conn1" rcvQueue)
    getConn store "conn1"
      `shouldReturn` Right (SomeConn SCReceive $ ReceiveConnection "conn1" rcvQueue)
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
    addSndQueue store "conn1" sndQueue
      `shouldReturn` Right ()
    getConn store "conn1"
      `shouldReturn` Right (SomeConn SCDuplex $ DuplexConnection "conn1" rcvQueue sndQueue)

testCreateSndConn :: SpecWith SQLiteStore
testCreateSndConn = do
  it "should create send connection and add receive queue" $ \store -> do
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
    createSndConn store "conn1" sndQueue
      `shouldReturn` Right (SendConnection "conn1" sndQueue)
    getConn store "conn1"
      `shouldReturn` Right (SomeConn SCSend $ SendConnection "conn1" sndQueue)
    let rcvQueue =
          ReceiveQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              rcvId = "2345",
              rcvPrivateKey = "abcd",
              sndId = Just "3456",
              sndKey = Nothing,
              decryptKey = "dcba",
              verifyKey = Nothing,
              status = New,
              ackMode = AckMode On
            }
    addRcvQueue store "conn1" rcvQueue
      `shouldReturn` Right ()
    getConn store "conn1"
      `shouldReturn` Right (SomeConn SCDuplex $ DuplexConnection "conn1" rcvQueue sndQueue)

testAddSndQueue :: SpecWith SQLiteStore
testAddSndQueue = do
  it "should return error on attempts to add send queue to SendConnection or DuplexConnection" $ \store -> do
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
    _ <- createSndConn store "conn1" sndQueue
    let anotherSndQueue =
          SendQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              sndId = "2345",
              sndPrivateKey = "abcd",
              encryptKey = "dcba",
              signKey = "edcb",
              status = New,
              ackMode = AckMode On
            }
    addSndQueue store "conn1" anotherSndQueue
      `shouldReturn` Left (SEBadConnType CSend)
    let rcvQueue =
          ReceiveQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              rcvId = "3456",
              rcvPrivateKey = "abcd",
              sndId = Just "4567",
              sndKey = Nothing,
              decryptKey = "dcba",
              verifyKey = Nothing,
              status = New,
              ackMode = AckMode On
            }
    _ <- addRcvQueue store "conn1" rcvQueue
    addSndQueue store "conn1" anotherSndQueue
      `shouldReturn` Left (SEBadConnType CDuplex)

testAddRcvQueue :: SpecWith SQLiteStore
testAddRcvQueue = do
  it "should return error on attempts to add receive queue to ReceiveConnection or DuplexConnection" $ \store -> do
    let rcvQueue =
          ReceiveQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              rcvId = "1234",
              rcvPrivateKey = "abcd",
              sndId = Just "2345",
              sndKey = Nothing,
              decryptKey = "dcba",
              verifyKey = Nothing,
              status = New,
              ackMode = AckMode On
            }
    _ <- createRcvConn store "conn1" rcvQueue
    let anotherRcvQueue =
          ReceiveQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              rcvId = "3456",
              rcvPrivateKey = "abcd",
              sndId = Just "4567",
              sndKey = Nothing,
              decryptKey = "dcba",
              verifyKey = Nothing,
              status = New,
              ackMode = AckMode On
            }
    addRcvQueue store "conn1" anotherRcvQueue
      `shouldReturn` Left (SEBadConnType CReceive)
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
    _ <- addSndQueue store "conn1" sndQueue
    addRcvQueue store "conn1" anotherRcvQueue
      `shouldReturn` Left (SEBadConnType CDuplex)

testDeleteConnReceive :: SpecWith SQLiteStore
testDeleteConnReceive = do
  it "should create receive connection and delete it" $ \store -> do
    let rcvQueue =
          ReceiveQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              rcvId = "1234",
              rcvPrivateKey = "abcd",
              sndId = Just "2345",
              sndKey = Nothing,
              decryptKey = "dcba",
              verifyKey = Nothing,
              status = New,
              ackMode = AckMode On
            }
    _ <- createRcvConn store "conn1" rcvQueue
    getConn store "conn1"
      `shouldReturn` Right (SomeConn SCReceive $ ReceiveConnection "conn1" rcvQueue)
    deleteConn store "conn1"
      `shouldReturn` Right ()
    getConn store "conn1"
      `shouldReturn` Left SEInternal

testDeleteConnSend :: SpecWith SQLiteStore
testDeleteConnSend = do
  it "should create send connection and delete it" $ \store -> do
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
    _ <- createSndConn store "conn1" sndQueue
    getConn store "conn1"
      `shouldReturn` Right (SomeConn SCSend $ SendConnection "conn1" sndQueue)
    deleteConn store "conn1"
      `shouldReturn` Right ()
    getConn store "conn1"
      `shouldReturn` Left SEInternal

testDeleteConnDuplex :: SpecWith SQLiteStore
testDeleteConnDuplex = do
  it "should create duplex connection and delete it" $ \store -> do
    let rcvQueue =
          ReceiveQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              rcvId = "1234",
              rcvPrivateKey = "abcd",
              sndId = Just "2345",
              sndKey = Nothing,
              decryptKey = "dcba",
              verifyKey = Nothing,
              status = New,
              ackMode = AckMode On
            }
    _ <- createRcvConn store "conn1" rcvQueue
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
    _ <- addSndQueue store "conn1" sndQueue
    getConn store "conn1"
      `shouldReturn` Right (SomeConn SCDuplex $ DuplexConnection "conn1" rcvQueue sndQueue)
    deleteConn store "conn1"
      `shouldReturn` Right ()
    getConn store "conn1"
      `shouldReturn` Left SEInternal
