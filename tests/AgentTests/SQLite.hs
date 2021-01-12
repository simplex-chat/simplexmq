{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module AgentTests.SQLite where

import Control.Monad.Except
import qualified Database.SQLite.Simple as DB
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Agent.Store.Types
import Simplex.Messaging.Agent.Transmission
import Test.Hspec
import UnliftIO.Directory

testDB :: String
testDB = "smp-agent.test.db"

withStore :: SpecWith SQLiteStore -> Spec
withStore =
  before (newSQLiteStore testDB)
    . after (\store -> DB.close (conn store) >> removeFile testDB)

returnsResult :: (Eq a, Eq e, Show a, Show e) => ExceptT e IO a -> a -> Expectation
action `returnsResult` r = runExceptT action `shouldReturn` Right r

throwsError :: (Eq a, Eq e, Show a, Show e) => ExceptT e IO a -> e -> Expectation
action `throwsError` e = runExceptT action `shouldReturn` Left e

storeTests :: Spec
storeTests = withStore do
  describe "store methods" do
    describe "createRcvConn" testCreateRcvConn
    describe "createSndConn" testCreateSndConn
    describe "addSndQueue" testAddSndQueue
    describe "addRcvQueue" testAddRcvQueue
    describe "deleteConn" do
      describe "Receive connection" testDeleteConnReceive
      describe "Send connection" testDeleteConnSend
      describe "Duplex connection" testDeleteConnDuplex
    describe "updateQueueStatus" do
      describe "updateQueueStatusCorrect" testUpdateQueueStatus
      describe "updateQueueStatusBadDirectionSnd" testUpdateQueueStatusBadDirectionSnd
      describe "updateQueueStatusBadDirectionRcv" testUpdateQueueStatusBadDirectionRcv

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
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCReceive (ReceiveConnection "conn1" rcvQueue)
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
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue sndQueue)

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
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCSend (SendConnection "conn1" sndQueue)
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
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue sndQueue)

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
    createSndConn store "conn1" sndQueue
      `returnsResult` ()
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
      `throwsError` SEBadConnType CSend
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
    addRcvQueue store "conn1" rcvQueue
      `returnsResult` ()
    addSndQueue store "conn1" anotherSndQueue
      `throwsError` SEBadConnType CDuplex

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
    createRcvConn store "conn1" rcvQueue
      `returnsResult` ()
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
      `throwsError` SEBadConnType CReceive
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
    addSndQueue store "conn1" sndQueue
      `returnsResult` ()
    addRcvQueue store "conn1" anotherRcvQueue
      `throwsError` SEBadConnType CDuplex

testDeleteConnReceive :: SpecWith SQLiteStore
testDeleteConnReceive = do
  it "should create receive connection and delete it" $ \store -> do
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
    createRcvConn store "conn1" rcvQueue
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCReceive (ReceiveConnection "conn1" rcvQueue)
    deleteConn store "conn1"
      `returnsResult` ()
    getConn store "conn1"
      `throwsError` SEInternal

testDeleteConnSend :: SpecWith SQLiteStore
testDeleteConnSend = do
  it "should create send connection and delete it" $ \store -> do
    let sndQueue =
          SendQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              sndId = "2345",
              sndPrivateKey = "abcd",
              encryptKey = "dcba",
              signKey = "edcb",
              status = New,
              ackMode = AckMode On
            }
    createSndConn store "conn1" sndQueue
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCSend (SendConnection "conn1" sndQueue)
    deleteConn store "conn1"
      `returnsResult` ()
    getConn store "conn1"
      `throwsError` SEInternal

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
    createRcvConn store "conn1" rcvQueue
      `returnsResult` ()
    let sndQueue =
          SendQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              sndId = "4567",
              sndPrivateKey = "abcd",
              encryptKey = "dcba",
              signKey = "edcb",
              status = New,
              ackMode = AckMode On
            }
    addSndQueue store "conn1" sndQueue
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue sndQueue)
    deleteConn store "conn1"
      `returnsResult` ()
    getConn store "conn1"
      `throwsError` SEInternal

testUpdateQueueStatus :: SpecWith SQLiteStore
testUpdateQueueStatus = do
  it "should update receive and send queues' statuses" $ \store -> do
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
      `returnsResult` ()
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
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue sndQueue)
    updateQueueStatus store "conn1" RCV Secured
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue {status = Secured} sndQueue)
    updateQueueStatus store "conn1" SND Confirmed
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue {status = Secured} sndQueue {status = Confirmed})

testUpdateQueueStatusBadDirectionSnd :: SpecWith SQLiteStore
testUpdateQueueStatusBadDirectionSnd = do
  it "should return error on attempt to update status of send queue in receive connection" $ \store -> do
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
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCReceive (ReceiveConnection "conn1" rcvQueue)
    updateQueueStatus store "conn1" SND Confirmed
      `throwsError` SEBadConn
    getConn store "conn1"
      `returnsResult` SomeConn SCReceive (ReceiveConnection "conn1" rcvQueue)

testUpdateQueueStatusBadDirectionRcv :: SpecWith SQLiteStore
testUpdateQueueStatusBadDirectionRcv = do
  it "should return error on attempt to update status of receive queue in send connection" $ \store -> do
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
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCSend (SendConnection "conn1" sndQueue)
    updateQueueStatus store "conn1" RCV Confirmed
      `throwsError` SEBadConn
    getConn store "conn1"
      `returnsResult` SomeConn SCSend (SendConnection "conn1" sndQueue)
