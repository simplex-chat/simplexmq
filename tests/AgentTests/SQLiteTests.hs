{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module AgentTests.SQLiteTests where

import Control.Monad.Except
import Data.Word (Word32)
import qualified Database.SQLite.Simple as DB
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Agent.Store.SQLite.Util (SQLiteStore, conn, dbFilename)
import Simplex.Messaging.Agent.Store.Types
import Simplex.Messaging.Agent.Transmission
import System.Random
import Test.Hspec
import UnliftIO.Directory

testDB :: String
testDB = "smp-agent.test.db"

withStore :: SpecWith SQLiteStore -> Spec
withStore = before createStore . after removeStore
  where
    createStore :: IO SQLiteStore
    createStore = do
      -- Randomize DB file name to avoid SQLite IO errors supposedly caused by asynchronous
      -- IO operations on multiple similarly named files; error specific to some environments
      r <- randomIO :: IO Word32
      newSQLiteStore $ testDB <> show r

    removeStore :: SQLiteStore -> IO ()
    removeStore store = do
      DB.close $ conn store
      removeFile $ dbFilename store

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
    describe "Update queue status" do
      describe "Receive queue" testupdateRcvQueueStatus
      describe "Send queue" testupdateSndQueueStatus
      describe "Duplex connection" testUpdateQueueStatusConnDuplex
      xdescribe "Nonexistent send queue" testUpdateNonexistentSendQueueStatus
      xdescribe "Nonexistent receive queue" testUpdateNonexistentReceiveQueueStatus
    describe "createMsg" do
      describe "A_MSG in RCV direction" testCreateMsgRcv
      describe "A_MSG in SND direction" testCreateMsgSnd
      describe "HELLO message" testCreateMsgHello
      describe "REPLY message" testCreateMsgReply
      describe "Bad queue direction - SND" testCreateMsgBadDirectionSnd
      describe "Bad queue direction - RCV" testCreateMsgBadDirectionRcv
    describe "getRcvQueue" testGetRcvQueue

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
  it "should throw error on attempts to add send queue to SendConnection or DuplexConnection" $ \store -> do
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
  it "should throw error on attempts to add receive queue to ReceiveConnection or DuplexConnection" $ \store -> do
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

testupdateRcvQueueStatus :: SpecWith SQLiteStore
testupdateRcvQueueStatus = do
  it "should update status of receive queue" $ \store -> do
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
    updateRcvQueueStatus store rcvQueue Confirmed
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCReceive (ReceiveConnection "conn1" rcvQueue {status = Confirmed})

testupdateSndQueueStatus :: SpecWith SQLiteStore
testupdateSndQueueStatus = do
  it "should update status of send queue" $ \store -> do
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
    updateSndQueueStatus store sndQueue Confirmed
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCSend (SendConnection "conn1" sndQueue {status = Confirmed})

testUpdateQueueStatusConnDuplex :: SpecWith SQLiteStore
testUpdateQueueStatusConnDuplex = do
  it "should update statuses of receive and send queues in duplex connection" $ \store -> do
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
    updateRcvQueueStatus store rcvQueue Secured
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue {status = Secured} sndQueue)
    updateSndQueueStatus store sndQueue Confirmed
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue {status = Secured} sndQueue {status = Confirmed})

testUpdateNonexistentSendQueueStatus :: SpecWith SQLiteStore
testUpdateNonexistentSendQueueStatus = do
  it "should throw error on attempt to update status of nonexistent send queue" $ \store -> do
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
    updateSndQueueStatus store sndQueue Confirmed
      `throwsError` SEInternal

testUpdateNonexistentReceiveQueueStatus :: SpecWith SQLiteStore
testUpdateNonexistentReceiveQueueStatus = do
  it "should throw error on attempt to update status of nonexistent receive queue" $ \store -> do
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
    updateRcvQueueStatus store rcvQueue Confirmed
      `throwsError` SEInternal

testCreateMsgRcv :: SpecWith SQLiteStore
testCreateMsgRcv = do
  it "should create a message in RCV direction" $ \store -> do
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
    let msg = A_MSG "hello"
    let msgId = 1
    -- TODO getMsg to check message
    createMsg store "conn1" RCV msgId msg
      `returnsResult` ()

testCreateMsgSnd :: SpecWith SQLiteStore
testCreateMsgSnd = do
  it "should create a message in SND direction" $ \store -> do
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
    let msg = A_MSG "hi"
    let msgId = 1
    -- TODO getMsg to check message
    createMsg store "conn1" SND msgId msg
      `returnsResult` ()

testCreateMsgHello :: SpecWith SQLiteStore
testCreateMsgHello = do
  it "should create a HELLO message" $ \store -> do
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
    let verificationKey = "abcd"
    let am = AckMode On
    let msg = HELLO verificationKey am
    let msgId = 1
    -- TODO getMsg to check message
    createMsg store "conn1" RCV msgId msg
      `returnsResult` ()

testCreateMsgReply :: SpecWith SQLiteStore
testCreateMsgReply = do
  it "should create a REPLY message" $ \store -> do
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
    let smpServer = SMPServer "smp.simplex.im" (Just "5223") (Just "1234")
    let senderId = "sender1"
    let encryptionKey = "abcd"
    let msg = REPLY $ SMPQueueInfo smpServer senderId encryptionKey
    let msgId = 1
    -- TODO getMsg to check message
    createMsg store "conn1" RCV msgId msg
      `returnsResult` ()

testCreateMsgBadDirectionSnd :: SpecWith SQLiteStore
testCreateMsgBadDirectionSnd = do
  it "should throw error on attempt to create a message in ineligible SND direction" $ \store -> do
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
    let msg = A_MSG "hello"
    let msgId = 1
    createMsg store "conn1" SND msgId msg
      `throwsError` SEBadQueueDirection

testCreateMsgBadDirectionRcv :: SpecWith SQLiteStore
testCreateMsgBadDirectionRcv = do
  it "should throw error on attempt to create a message in ineligible RCV direction" $ \store -> do
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
    let msg = A_MSG "hello"
    let msgId = 1
    createMsg store "conn1" RCV msgId msg
      `throwsError` SEBadQueueDirection

testGetRcvQueue :: SpecWith SQLiteStore
testGetRcvQueue = do
  it "should get receive queue and conn alias" $ \store -> do
    let smpServer = SMPServer "smp.simplex.im" (Just "5223") (Just "1234")
    let cAlias = "conn1"
    let recipientId = "1234"
    let rcvQueue =
          ReceiveQueue
            { server = smpServer,
              rcvId = recipientId,
              rcvPrivateKey = "abcd",
              sndId = Just "2345",
              sndKey = Nothing,
              decryptKey = "dcba",
              verifyKey = Nothing,
              status = New,
              ackMode = AckMode On
            }
    createRcvConn store cAlias rcvQueue
      `returnsResult` ()
    getRcvQueue store smpServer recipientId
      `returnsResult` (cAlias, rcvQueue)
