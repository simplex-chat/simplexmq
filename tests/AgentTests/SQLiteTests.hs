{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module AgentTests.SQLiteTests (storeTests) where

import AgentTests.EqInstances ()
import Control.Concurrent.Async (concurrently_)
import Control.Concurrent.STM
import Control.Exception (SomeException)
import Control.Monad (replicateM_)
import Control.Monad.Trans.Except
import Crypto.Random (ChaChaDRG)
import Data.ByteArray (ScrubbedBytes)
import Data.ByteString.Char8 (ByteString)
import Data.List (isInfixOf)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time
import Data.Word (Word32)
import Database.SQLite.Simple (Only (..))
import qualified Database.SQLite.Simple as SQL
import Database.SQLite.Simple.QQ (sql)
import SMPClient (testKeyHash)
import Simplex.FileTransfer.Client (XFTPChunkSpec (..))
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Protocol
import Simplex.FileTransfer.Types
import Simplex.Messaging.Agent.Client ()
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Agent.Store.SQLite.Common (withTransaction')
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet (InitialKeys (..), pattern PQSupportOn)
import qualified Simplex.Messaging.Crypto.Ratchet as CR
import Simplex.Messaging.Crypto.File (CryptoFile (..))
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Protocol (SubscriptionMode (..), pattern VersionSMPC)
import qualified Simplex.Messaging.Protocol as SMP
import System.Random
import Test.Hspec
import UnliftIO.Directory (removeFile)
import Simplex.Messaging.Util (atomically')

testDB :: String
testDB = "tests/tmp/smp-agent.test.db"

withStore :: SpecWith SQLiteStore -> Spec
withStore = before createStore . after removeStore

withStore2 :: SpecWith (SQLiteStore, SQLiteStore) -> Spec
withStore2 = before connect2 . after (removeStore . fst)
  where
    connect2 :: IO (SQLiteStore, SQLiteStore)
    connect2 = do
      s1 <- createStore
      s2 <- connectSQLiteStore (dbFilePath s1) "" False
      pure (s1, s2)

createStore :: IO SQLiteStore
createStore = createEncryptedStore "" False

createEncryptedStore :: ScrubbedBytes -> Bool -> IO SQLiteStore
createEncryptedStore key keepKey = do
  -- Randomize DB file name to avoid SQLite IO errors supposedly caused by asynchronous
  -- IO operations on multiple similarly named files; error seems to be environment specific
  r <- randomIO :: IO Word32
  Right st <- createSQLiteStore (testDB <> show r) key keepKey Migrations.app MCError
  withTransaction' st (`SQL.execute_` "INSERT INTO users (user_id) VALUES (1);")
  pure st

removeStore :: SQLiteStore -> IO ()
removeStore db = do
  close db
  removeFile $ dbFilePath db
  where
    close :: SQLiteStore -> IO ()
    close st = mapM_ DB.close =<< atomically' (tryTakeTMVar $ dbConnection st)

storeTests :: Spec
storeTests = do
  withStore2 $ do
    describe "stress test" testConcurrentWrites
  withStore $ do
    describe "db setup" $ do
      testCompiledThreadsafe
      testForeignKeysEnabled
    describe "db methods" $ do
      describe "Queue and Connection management" $ do
        describe "create Rcv connection" $ do
          testCreateRcvConn
          testCreateRcvConnRandomId
          testCreateRcvConnDuplicate
        describe "createSndConn" $ do
          testCreateSndConn
          testCreateSndConnRandomID
          testCreateSndConnDuplicate
        describe "getRcvConn" testGetRcvConn
        describe "deleteConn" $ do
          testDeleteRcvConn
          testDeleteSndConn
          testDeleteDuplexConn
        describe "upgradeRcvConnToDuplex" $ do
          testUpgradeRcvConnToDuplex
        describe "upgradeSndConnToDuplex" $ do
          testUpgradeSndConnToDuplex
        describe "set Queue status" $ do
          describe "setRcvQueueStatus" $ do
            testSetRcvQueueStatus
          describe "setSndQueueStatus" $ do
            testSetSndQueueStatus
          testSetQueueStatusDuplex
      describe "Msg management" $ do
        describe "create Msg" $ do
          testCreateRcvMsg
          testCreateSndMsg
          testCreateRcvAndSndMsgs
      describe "Work items" $ do
        it "should getPendingQueueMsg" testGetPendingQueueMsg
        it "should getPendingServerCommand" testGetPendingServerCommand
        it "should getNextRcvChunkToDownload" testGetNextRcvChunkToDownload
        it "should getNextRcvFileToDecrypt" testGetNextRcvFileToDecrypt
        it "should getNextSndFileToPrepare" testGetNextSndFileToPrepare
        it "should getNextSndChunkToUpload" testGetNextSndChunkToUpload
        it "should getNextDeletedSndChunkReplica" testGetNextDeletedSndChunkReplica
        it "should markNtfSubActionNtfFailed_" testMarkNtfSubActionNtfFailed
        it "should markNtfSubActionSMPFailed_" testMarkNtfSubActionSMPFailed
  describe "open/close store" $ do
    it "should close and re-open" testCloseReopenStore
    it "should close and re-open encrypted store" testCloseReopenEncryptedStore
    it "should close and re-open encrypted store (keep key)" testReopenEncryptedStoreKeepKey

testConcurrentWrites :: SpecWith (SQLiteStore, SQLiteStore)
testConcurrentWrites =
  it "should complete multiple concurrent write transactions w/t sqlite busy errors" $ \(s1, s2) -> do
    g <- C.newRandom
    Right (_, rq) <- withTransaction s1 $ \db ->
      createRcvConn db g cData1 rcvQueue1 SCMInvitation
    let ConnData {connId} = cData1
    concurrently_ (runTest s1 connId rq) (runTest s2 connId rq)
  where
    runTest :: SQLiteStore -> ConnId -> RcvQueue -> IO ()
    runTest st connId rq = replicateM_ 100 . withTransaction st $ \db -> do
      (internalId, internalRcvId, _, _) <- updateRcvIds db connId
      let rcvMsgData = mkRcvMsgData internalId internalRcvId 0 "0" "hash_dummy"
      createRcvMsg db connId rq rcvMsgData

testCompiledThreadsafe :: SpecWith SQLiteStore
testCompiledThreadsafe =
  it "compiled sqlite library should be threadsafe" . withStoreTransaction $ \db -> do
    compileOptions <- DB.query_ db "pragma COMPILE_OPTIONS;" :: IO [[T.Text]]
    compileOptions `shouldNotContain` [["THREADSAFE=0"]]

withStoreTransaction :: (DB.Connection -> IO a) -> SQLiteStore -> IO a
withStoreTransaction = flip withTransaction

testForeignKeysEnabled :: SpecWith SQLiteStore
testForeignKeysEnabled =
  it "foreign keys should be enabled" . withStoreTransaction $ \db -> do
    let inconsistentQuery =
          [sql|
            INSERT INTO snd_queues
              ( host, port, snd_id, conn_id, snd_private_key, e2e_dh_secret, status)
            VALUES
              ('smp.simplex.im', '5223', '1234', '2345', x'', x'', 'new');
          |]
    DB.execute_ db inconsistentQuery
      `shouldThrow` (\e -> SQL.sqlError e == SQL.ErrorConstraint)

cData1 :: ConnData
cData1 =
  ConnData
    { userId = 1,
      connId = "conn1",
      connAgentVersion = VersionSMPA 1,
      enableNtfs = True,
      lastExternalSndId = 0,
      deleted = False,
      ratchetSyncState = RSOk,
      pqSupport = CR.PQSupportOn
    }

testPrivateAuthKey :: C.APrivateAuthKey
testPrivateAuthKey = C.APrivateAuthKey C.SEd25519 "MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe"

testPrivDhKey :: C.PrivateKeyX25519
testPrivDhKey = "MC4CAQAwBQYDK2VuBCIEINCzbVFaCiYHoYncxNY8tSIfn0pXcIAhLBfFc0m+gOpk"

testDhSecret :: C.DhSecretX25519
testDhSecret = "01234567890123456789012345678901"

smpServer1 :: SMPServer
smpServer1 = SMPServer "smp.simplex.im" "5223" testKeyHash

rcvQueue1 :: NewRcvQueue
rcvQueue1 =
  RcvQueue
    { userId = 1,
      connId = "conn1",
      server = smpServer1,
      rcvId = "1234",
      rcvPrivateKey = testPrivateAuthKey,
      rcvDhSecret = testDhSecret,
      e2ePrivKey = testPrivDhKey,
      e2eDhSecret = Nothing,
      sndId = "2345",
      status = New,
      dbQueueId = DBNewQueue,
      primary = True,
      dbReplaceQueueId = Nothing,
      rcvSwchStatus = Nothing,
      smpClientVersion = VersionSMPC 1,
      clientNtfCreds = Nothing,
      deleteErrors = 0
    }

sndQueue1 :: NewSndQueue
sndQueue1 =
  SndQueue
    { userId = 1,
      connId = "conn1",
      server = smpServer1,
      sndId = "3456",
      sndPublicKey = Nothing,
      sndPrivateKey = testPrivateAuthKey,
      e2ePubKey = Nothing,
      e2eDhSecret = testDhSecret,
      status = New,
      dbQueueId = DBNewQueue,
      primary = True,
      dbReplaceQueueId = Nothing,
      sndSwchStatus = Nothing,
      smpClientVersion = VersionSMPC 1
    }

createRcvConn :: DB.Connection -> TVar ChaChaDRG -> ConnData -> NewRcvQueue -> SConnectionMode c -> IO (Either StoreError (ConnId, RcvQueue))
createRcvConn db g cData rq cMode = runExceptT $ do
  connId <- ExceptT $ createNewConn db g cData cMode
  rq' <- ExceptT $ updateNewConnRcv db connId rq
  pure (connId, rq')

testCreateRcvConn :: SpecWith SQLiteStore
testCreateRcvConn =
  it "should create RcvConnection and add SndQueue" . withStoreTransaction $ \db -> do
    g <- C.newRandom
    Right (connId, rq@RcvQueue {dbQueueId}) <- createRcvConn db g cData1 rcvQueue1 SCMInvitation
    connId `shouldBe` "conn1"
    dbQueueId `shouldBe` DBQueueId 1
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCRcv (RcvConnection cData1 rq))
    Right sq@SndQueue {dbQueueId = dbQueueId'} <- upgradeRcvConnToDuplex db "conn1" sndQueue1
    dbQueueId' `shouldBe` DBQueueId 1
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCDuplex (DuplexConnection cData1 [rq] [sq]))

testCreateRcvConnRandomId :: SpecWith SQLiteStore
testCreateRcvConnRandomId =
  it "should create RcvConnection and add SndQueue with random ID" . withStoreTransaction $ \db -> do
    g <- C.newRandom
    Right (connId, rq) <- createRcvConn db g cData1 {connId = ""} rcvQueue1 SCMInvitation
    getConn db connId
      `shouldReturn` Right (SomeConn SCRcv (RcvConnection cData1 {connId} rq))
    Right sq@SndQueue {dbQueueId = dbQueueId'} <- upgradeRcvConnToDuplex db connId sndQueue1
    dbQueueId' `shouldBe` DBQueueId 1
    getConn db connId
      `shouldReturn` Right (SomeConn SCDuplex (DuplexConnection cData1 {connId} [rq] [sq]))

testCreateRcvConnDuplicate :: SpecWith SQLiteStore
testCreateRcvConnDuplicate =
  it "should throw error on attempt to create duplicate RcvConnection" . withStoreTransaction $ \db -> do
    g <- C.newRandom
    _ <- createRcvConn db g cData1 rcvQueue1 SCMInvitation
    createRcvConn db g cData1 rcvQueue1 SCMInvitation
      `shouldReturn` Left SEConnDuplicate

testCreateSndConn :: SpecWith SQLiteStore
testCreateSndConn =
  it "should create SndConnection and add RcvQueue" . withStoreTransaction $ \db -> do
    g <- C.newRandom
    Right (connId, sq@SndQueue {dbQueueId}) <- createSndConn db g cData1 sndQueue1
    connId `shouldBe` "conn1"
    dbQueueId `shouldBe` DBQueueId 1
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCSnd (SndConnection cData1 sq))
    Right rq@RcvQueue {dbQueueId = dbQueueId'} <- upgradeSndConnToDuplex db "conn1" rcvQueue1
    dbQueueId' `shouldBe` DBQueueId 1
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCDuplex (DuplexConnection cData1 [rq] [sq]))

testCreateSndConnRandomID :: SpecWith SQLiteStore
testCreateSndConnRandomID =
  it "should create SndConnection and add RcvQueue with random ID" . withStoreTransaction $ \db -> do
    g <- C.newRandom
    Right (connId, sq) <- createSndConn db g cData1 {connId = ""} sndQueue1
    getConn db connId
      `shouldReturn` Right (SomeConn SCSnd (SndConnection cData1 {connId} sq))
    Right (rq@RcvQueue {dbQueueId = dbQueueId'}) <- upgradeSndConnToDuplex db connId rcvQueue1
    dbQueueId' `shouldBe` DBQueueId 1
    getConn db connId
      `shouldReturn` Right (SomeConn SCDuplex (DuplexConnection cData1 {connId} [rq] [sq]))

testCreateSndConnDuplicate :: SpecWith SQLiteStore
testCreateSndConnDuplicate =
  it "should throw error on attempt to create duplicate SndConnection" . withStoreTransaction $ \db -> do
    g <- C.newRandom
    _ <- createSndConn db g cData1 sndQueue1
    createSndConn db g cData1 sndQueue1
      `shouldReturn` Left SEConnDuplicate

testGetRcvConn :: SpecWith SQLiteStore
testGetRcvConn =
  it "should get connection using rcv queue id and server" . withStoreTransaction $ \db -> do
    let smpServer = SMPServer "smp.simplex.im" "5223" testKeyHash
    let recipientId = "1234"
    g <- C.newRandom
    Right (_, rq) <- createRcvConn db g cData1 rcvQueue1 SCMInvitation
    getRcvConn db smpServer recipientId
      `shouldReturn` Right (rq, SomeConn SCRcv (RcvConnection cData1 rq))

testDeleteRcvConn :: SpecWith SQLiteStore
testDeleteRcvConn =
  it "should create RcvConnection and delete it" . withStoreTransaction $ \db -> do
    g <- C.newRandom
    Right (_, rq) <- createRcvConn db g cData1 rcvQueue1 SCMInvitation
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCRcv (RcvConnection cData1 rq))
    deleteConn db Nothing "conn1"
      `shouldReturn` Just "conn1"
    getConn db "conn1"
      `shouldReturn` Left SEConnNotFound

testDeleteSndConn :: SpecWith SQLiteStore
testDeleteSndConn =
  it "should create SndConnection and delete it" . withStoreTransaction $ \db -> do
    g <- C.newRandom
    Right (_, sq) <- createSndConn db g cData1 sndQueue1
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCSnd (SndConnection cData1 sq))
    deleteConn db Nothing "conn1"
      `shouldReturn` Just "conn1"
    getConn db "conn1"
      `shouldReturn` Left SEConnNotFound

testDeleteDuplexConn :: SpecWith SQLiteStore
testDeleteDuplexConn =
  it "should create DuplexConnection and delete it" . withStoreTransaction $ \db -> do
    g <- C.newRandom
    Right (_, rq) <- createRcvConn db g cData1 rcvQueue1 SCMInvitation
    Right sq <- upgradeRcvConnToDuplex db "conn1" sndQueue1
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCDuplex (DuplexConnection cData1 [rq] [sq]))
    deleteConn db Nothing "conn1"
      `shouldReturn` Just "conn1"
    getConn db "conn1"
      `shouldReturn` Left SEConnNotFound

testUpgradeRcvConnToDuplex :: SpecWith SQLiteStore
testUpgradeRcvConnToDuplex =
  it "should throw error on attempt to add SndQueue to SndConnection or DuplexConnection" . withStoreTransaction $ \db -> do
    g <- C.newRandom
    _ <- createSndConn db g cData1 sndQueue1
    let anotherSndQueue =
          SndQueue
            { userId = 1,
              connId = "conn1",
              server = SMPServer "smp.simplex.im" "5223" testKeyHash,
              sndId = "2345",
              sndPublicKey = Nothing,
              sndPrivateKey = testPrivateAuthKey,
              e2ePubKey = Nothing,
              e2eDhSecret = testDhSecret,
              status = New,
              dbQueueId = DBNewQueue,
              sndSwchStatus = Nothing,
              primary = True,
              dbReplaceQueueId = Nothing,
              smpClientVersion = VersionSMPC 1
            }
    upgradeRcvConnToDuplex db "conn1" anotherSndQueue
      `shouldReturn` Left (SEBadConnType CSnd)
    _ <- upgradeSndConnToDuplex db "conn1" rcvQueue1
    upgradeRcvConnToDuplex db "conn1" anotherSndQueue
      `shouldReturn` Left (SEBadConnType CDuplex)

testUpgradeSndConnToDuplex :: SpecWith SQLiteStore
testUpgradeSndConnToDuplex =
  it "should throw error on attempt to add RcvQueue to RcvConnection or DuplexConnection" . withStoreTransaction $ \db -> do
    g <- C.newRandom
    _ <- createRcvConn db g cData1 rcvQueue1 SCMInvitation
    let anotherRcvQueue =
          RcvQueue
            { userId = 1,
              connId = "conn1",
              server = SMPServer "smp.simplex.im" "5223" testKeyHash,
              rcvId = "3456",
              rcvPrivateKey = testPrivateAuthKey,
              rcvDhSecret = testDhSecret,
              e2ePrivKey = testPrivDhKey,
              e2eDhSecret = Nothing,
              sndId = "4567",
              status = New,
              dbQueueId = DBNewQueue,
              rcvSwchStatus = Nothing,
              primary = True,
              dbReplaceQueueId = Nothing,
              smpClientVersion = VersionSMPC 1,
              clientNtfCreds = Nothing,
              deleteErrors = 0
            }
    upgradeSndConnToDuplex db "conn1" anotherRcvQueue
      `shouldReturn` Left (SEBadConnType CRcv)
    _ <- upgradeRcvConnToDuplex db "conn1" sndQueue1
    upgradeSndConnToDuplex db "conn1" anotherRcvQueue
      `shouldReturn` Left (SEBadConnType CDuplex)

testSetRcvQueueStatus :: SpecWith SQLiteStore
testSetRcvQueueStatus =
  it "should update status of RcvQueue" . withStoreTransaction $ \db -> do
    g <- C.newRandom
    Right (_, rq) <- createRcvConn db g cData1 rcvQueue1 SCMInvitation
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCRcv (RcvConnection cData1 rq))
    setRcvQueueStatus db rq Confirmed
      `shouldReturn` ()
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCRcv (RcvConnection cData1 rq {status = Confirmed}))

testSetSndQueueStatus :: SpecWith SQLiteStore
testSetSndQueueStatus =
  it "should update status of SndQueue" . withStoreTransaction $ \db -> do
    g <- C.newRandom
    Right (_, sq) <- createSndConn db g cData1 sndQueue1
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCSnd (SndConnection cData1 sq))
    setSndQueueStatus db sq Confirmed
      `shouldReturn` ()
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCSnd (SndConnection cData1 sq {status = Confirmed}))

testSetQueueStatusDuplex :: SpecWith SQLiteStore
testSetQueueStatusDuplex =
  it "should update statuses of RcvQueue and SndQueue in DuplexConnection" . withStoreTransaction $ \db -> do
    g <- C.newRandom
    Right (_, rq) <- createRcvConn db g cData1 rcvQueue1 SCMInvitation
    Right sq <- upgradeRcvConnToDuplex db "conn1" sndQueue1
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCDuplex (DuplexConnection cData1 [rq] [sq]))
    setRcvQueueStatus db rq Secured
      `shouldReturn` ()
    let rq' = (rq :: RcvQueue) {status = Secured}
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCDuplex (DuplexConnection cData1 [rq'] [sq]))
    setSndQueueStatus db sq Confirmed
      `shouldReturn` ()
    let sq' = (sq :: SndQueue) {status = Confirmed}
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCDuplex (DuplexConnection cData1 [rq'] [sq']))

hw :: ByteString
hw = encodeUtf8 "Hello world!"

ts :: UTCTime
ts = UTCTime (fromGregorian 2021 02 24) (secondsToDiffTime 0)

mkRcvMsgData :: InternalId -> InternalRcvId -> ExternalSndId -> BrokerId -> MsgHash -> RcvMsgData
mkRcvMsgData internalId internalRcvId externalSndId brokerId internalHash =
  RcvMsgData
    { internalRcvId,
      msgMeta =
        MsgMeta
          { integrity = MsgOk,
            recipient = (unId internalId, ts),
            sndMsgId = externalSndId,
            broker = (brokerId, ts),
            pqEncryption = CR.PQEncOn
          },
      msgType = AM_A_MSG_,
      msgFlags = SMP.noMsgFlags,
      msgBody = hw,
      internalHash,
      externalPrevSndHash = "hash_from_sender",
      encryptedMsgHash = "encrypted_msg_hash"
    }

testCreateRcvMsg_ :: DB.Connection -> PrevExternalSndId -> PrevRcvMsgHash -> ConnId -> RcvQueue -> RcvMsgData -> Expectation
testCreateRcvMsg_ db expectedPrevSndId expectedPrevHash connId rq rcvMsgData@RcvMsgData {..} = do
  let MsgMeta {recipient = (internalId, _)} = msgMeta
  updateRcvIds db connId
    `shouldReturn` (InternalId internalId, internalRcvId, expectedPrevSndId, expectedPrevHash)
  createRcvMsg db connId rq rcvMsgData
    `shouldReturn` ()

testCreateRcvMsg :: SpecWith SQLiteStore
testCreateRcvMsg =
  it "should reserve internal ids and create a RcvMsg" $ \st -> do
    g <- C.newRandom
    let ConnData {connId} = cData1
    Right (_, rq) <- withTransaction st $ \db -> do
      createRcvConn db g cData1 rcvQueue1 SCMInvitation
    withTransaction st $ \db -> do
      testCreateRcvMsg_ db 0 "" connId rq $ mkRcvMsgData (InternalId 1) (InternalRcvId 1) 1 "1" "hash_dummy"
      testCreateRcvMsg_ db 1 "hash_dummy" connId rq $ mkRcvMsgData (InternalId 2) (InternalRcvId 2) 2 "2" "new_hash_dummy"

mkSndMsgData :: InternalId -> InternalSndId -> MsgHash -> SndMsgData
mkSndMsgData internalId internalSndId internalHash =
  SndMsgData
    { internalId,
      internalSndId,
      internalTs = ts,
      msgType = AM_A_MSG_,
      msgFlags = SMP.noMsgFlags,
      msgBody = hw,
      pqEncryption = CR.PQEncOn,
      internalHash,
      prevMsgHash = internalHash
    }

testCreateSndMsg_ :: DB.Connection -> PrevSndMsgHash -> ConnId -> SndQueue -> SndMsgData -> Expectation
testCreateSndMsg_ db expectedPrevHash connId sq sndMsgData@SndMsgData {..} = do
  updateSndIds db connId
    `shouldReturn` (internalId, internalSndId, expectedPrevHash)
  createSndMsg db connId sndMsgData
    `shouldReturn` ()
  createSndMsgDelivery db connId sq internalId
    `shouldReturn` ()

testCreateSndMsg :: SpecWith SQLiteStore
testCreateSndMsg =
  it "should create a SndMsg and return InternalId and PrevSndMsgHash" $ \st -> do
    g <- C.newRandom
    let ConnData {connId} = cData1
    Right (_, sq) <- withTransaction st $ \db -> do
      createSndConn db g cData1 sndQueue1
    withTransaction st $ \db -> do
      testCreateSndMsg_ db "" connId sq $ mkSndMsgData (InternalId 1) (InternalSndId 1) "hash_dummy"
      testCreateSndMsg_ db "hash_dummy" connId sq $ mkSndMsgData (InternalId 2) (InternalSndId 2) "new_hash_dummy"

testCreateRcvAndSndMsgs :: SpecWith SQLiteStore
testCreateRcvAndSndMsgs =
  it "should create multiple RcvMsg and SndMsg, correctly ordering internal Ids and returning previous state" $ \st -> do
    let ConnData {connId} = cData1
    Right (_, rq) <- withTransaction st $ \db -> do
      g <- C.newRandom
      createRcvConn db g cData1 rcvQueue1 SCMInvitation
    withTransaction st $ \db -> do
      Right sq <- upgradeRcvConnToDuplex db "conn1" sndQueue1
      testCreateRcvMsg_ db 0 "" connId rq $ mkRcvMsgData (InternalId 1) (InternalRcvId 1) 1 "1" "rcv_hash_1"
      testCreateRcvMsg_ db 1 "rcv_hash_1" connId rq $ mkRcvMsgData (InternalId 2) (InternalRcvId 2) 2 "2" "rcv_hash_2"
      testCreateSndMsg_ db "" connId sq $ mkSndMsgData (InternalId 3) (InternalSndId 1) "snd_hash_1"
      testCreateRcvMsg_ db 2 "rcv_hash_2" connId rq $ mkRcvMsgData (InternalId 4) (InternalRcvId 3) 3 "3" "rcv_hash_3"
      testCreateSndMsg_ db "snd_hash_1" connId sq $ mkSndMsgData (InternalId 5) (InternalSndId 2) "snd_hash_2"
      testCreateSndMsg_ db "snd_hash_2" connId sq $ mkSndMsgData (InternalId 6) (InternalSndId 3) "snd_hash_3"

testCloseReopenStore :: IO ()
testCloseReopenStore = do
  st <- createStore
  hasMigrations st
  closeSQLiteStore st
  closeSQLiteStore st
  errorGettingMigrations st
  openSQLiteStore st "" False
  openSQLiteStore st "" False
  hasMigrations st
  closeSQLiteStore st
  errorGettingMigrations st
  reopenSQLiteStore st
  hasMigrations st

testCloseReopenEncryptedStore :: IO ()
testCloseReopenEncryptedStore = do
  let key = "test_key"
  st <- createEncryptedStore key False
  hasMigrations st
  closeSQLiteStore st
  closeSQLiteStore st
  errorGettingMigrations st
  reopenSQLiteStore st `shouldThrow` \(e :: SomeException) -> "reopenSQLiteStore: no key" `isInfixOf` show e
  openSQLiteStore st key True
  openSQLiteStore st key True
  hasMigrations st
  closeSQLiteStore st
  errorGettingMigrations st
  reopenSQLiteStore st
  hasMigrations st

testReopenEncryptedStoreKeepKey :: IO ()
testReopenEncryptedStoreKeepKey = do
  let key = "test_key"
  st <- createEncryptedStore key True
  hasMigrations st
  closeSQLiteStore st
  errorGettingMigrations st
  reopenSQLiteStore st
  hasMigrations st

getMigrations :: SQLiteStore -> IO Bool
getMigrations st = not . null <$> withTransaction st (Migrations.getCurrent . DB.conn)

hasMigrations :: SQLiteStore -> Expectation
hasMigrations st = getMigrations st `shouldReturn` True

errorGettingMigrations :: SQLiteStore -> Expectation
errorGettingMigrations st = getMigrations st `shouldThrow` \(e :: SomeException) -> "ErrorMisuse" `isInfixOf` show e

testGetPendingQueueMsg :: SQLiteStore -> Expectation
testGetPendingQueueMsg st = do
  g <- C.newRandom
  withTransaction st $ \db -> do
    Right (connId, sq) <- createSndConn db g cData1 {connId = ""} sndQueue1
    Right Nothing <- getPendingQueueMsg db connId sq
    testCreateSndMsg_ db "" connId sq $ mkSndMsgData (InternalId 1) (InternalSndId 1) "hash_dummy"
    DB.execute db "UPDATE messages SET msg_type = cast('bad' as blob) WHERE conn_id = ? AND internal_id = ?" (connId, 1 :: Int)
    testCreateSndMsg_ db "hash_dummy" connId sq $ mkSndMsgData (InternalId 2) (InternalSndId 2) "new_hash_dummy"

    Left e <- getPendingQueueMsg db connId sq
    show e `shouldContain` "bad AgentMessageType"
    DB.query_ db "SELECT conn_id, internal_id FROM snd_message_deliveries WHERE failed = 1" `shouldReturn` [(connId, 1 :: Int)]

    Right (Just (Nothing, PendingMsgData {msgId})) <- getPendingQueueMsg db connId sq
    msgId `shouldBe` InternalId 2

testGetPendingServerCommand :: SQLiteStore -> Expectation
testGetPendingServerCommand st = do
  g <- C.newRandom
  withTransaction st $ \db -> do
    Right Nothing <- getPendingServerCommand db Nothing
    Right connId <- createNewConn db g cData1 {connId = ""} SCMInvitation
    Right () <- createCommand db "1" connId Nothing command
    corruptCmd db "1" connId
    Right () <- createCommand db "2" connId Nothing command

    Left e <- getPendingServerCommand db Nothing
    show e `shouldContain` "bad AgentCmdType"
    DB.query_ db "SELECT conn_id, corr_id FROM commands WHERE failed = 1" `shouldReturn` [(connId, "1" :: ByteString)]

    Right (Just PendingCommand {corrId}) <- getPendingServerCommand db Nothing
    corrId `shouldBe` "2"

    Right _ <- updateNewConnRcv db connId rcvQueue1
    Right Nothing <- getPendingServerCommand db $ Just smpServer1
    Right () <- createCommand db "3" connId (Just smpServer1) command
    corruptCmd db "3" connId
    Right () <- createCommand db "4" connId (Just smpServer1) command

    Left e' <- getPendingServerCommand db (Just smpServer1)
    show e' `shouldContain` "bad AgentCmdType"
    DB.query_ db "SELECT conn_id, corr_id FROM commands WHERE failed = 1" `shouldReturn` [(connId, "1" :: ByteString), (connId, "3" :: ByteString)]

    Right (Just PendingCommand {corrId = corrId'}) <- getPendingServerCommand db (Just smpServer1)
    corrId' `shouldBe` "4"
  where
    command = AClientCommand $ APC SAEConn $ NEW True (ACM SCMInvitation) (IKNoPQ PQSupportOn) SMSubscribe
    corruptCmd :: DB.Connection -> ByteString -> ConnId -> IO ()
    corruptCmd db corrId connId = DB.execute db "UPDATE commands SET command = cast('bad' as blob) WHERE conn_id = ? AND corr_id = ?" (connId, corrId)

xftpServer1 :: SMP.XFTPServer
xftpServer1 = SMP.ProtocolServer SMP.SPXFTP "xftp.simplex.im" "5223" testKeyHash

rcvFileDescr1 :: FileDescription 'FRecipient
rcvFileDescr1 =
  FileDescription
    { party = SFRecipient,
      size = FileSize $ mb 26,
      digest = FileDigest "abc",
      key = testFileSbKey,
      nonce = testFileCbNonce,
      chunkSize = defaultChunkSize,
      chunks =
        [ FileChunk
            { chunkNo = 1,
              digest = chunkDigest,
              chunkSize = defaultChunkSize,
              replicas = [FileChunkReplica {server = xftpServer1, replicaId, replicaKey = testFileReplicaKey}]
            }
        ],
      redirect = Nothing
    }
  where
    defaultChunkSize = FileSize $ mb 8
    replicaId = ChunkReplicaId "abc"
    chunkDigest = FileDigest "ghi"

testFileSbKey :: C.SbKey
testFileSbKey = either error id $ strDecode "00n8p1tJq5E-SGnHcYTOrS4A9I07gTA_WFD6MTFFFOY="

testFileCbNonce :: C.CbNonce
testFileCbNonce = either error id $ strDecode "dPSF-wrQpDiK_K6sYv0BDBZ9S4dg-jmu"

testFileReplicaKey :: C.APrivateAuthKey
testFileReplicaKey = C.APrivateAuthKey C.SEd25519 "MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe"

testGetNextRcvChunkToDownload :: SQLiteStore -> Expectation
testGetNextRcvChunkToDownload st = do
  g <- C.newRandom
  withTransaction st $ \db -> do
    Right Nothing <- getNextRcvChunkToDownload db xftpServer1 86400

    Right _ <- createRcvFile db g 1 rcvFileDescr1 "filepath" "filepath" (CryptoFile "filepath" Nothing)
    DB.execute_ db "UPDATE rcv_file_chunk_replicas SET replica_key = cast('bad' as blob) WHERE rcv_file_chunk_replica_id = 1"
    Right fId2 <- createRcvFile db g 1 rcvFileDescr1 "filepath" "filepath" (CryptoFile "filepath" Nothing)

    Left e <- getNextRcvChunkToDownload db xftpServer1 86400
    show e `shouldContain` "ConversionFailed"
    DB.query_ db "SELECT rcv_file_id FROM rcv_files WHERE failed = 1" `shouldReturn` [Only (1 :: Int)]

    Right (Just RcvFileChunk {rcvFileEntityId}) <- getNextRcvChunkToDownload db xftpServer1 86400
    rcvFileEntityId `shouldBe` fId2

testGetNextRcvFileToDecrypt :: SQLiteStore -> Expectation
testGetNextRcvFileToDecrypt st = do
  g <- C.newRandom
  withTransaction st $ \db -> do
    Right Nothing <- getNextRcvFileToDecrypt db 86400

    Right _ <- createRcvFile db g 1 rcvFileDescr1 "filepath" "filepath" (CryptoFile "filepath" Nothing)
    DB.execute_ db "UPDATE rcv_files SET status = 'received' WHERE rcv_file_id = 1"
    DB.execute_ db "UPDATE rcv_file_chunk_replicas SET replica_key = cast('bad' as blob) WHERE rcv_file_chunk_replica_id = 1"
    Right fId2 <- createRcvFile db g 1 rcvFileDescr1 "filepath" "filepath" (CryptoFile "filepath" Nothing)
    DB.execute_ db "UPDATE rcv_files SET status = 'received' WHERE rcv_file_id = 2"

    Left e <- getNextRcvFileToDecrypt db 86400
    show e `shouldContain` "ConversionFailed"
    DB.query_ db "SELECT rcv_file_id FROM rcv_files WHERE failed = 1" `shouldReturn` [Only (1 :: Int)]

    Right (Just RcvFile {rcvFileEntityId}) <- getNextRcvFileToDecrypt db 86400
    rcvFileEntityId `shouldBe` fId2

testGetNextSndFileToPrepare :: SQLiteStore -> Expectation
testGetNextSndFileToPrepare st = do
  g <- C.newRandom
  withTransaction st $ \db -> do
    Right Nothing <- getNextSndFileToPrepare db 86400

    Right _ <- createSndFile db g 1 (CryptoFile "filepath" Nothing) 1 "filepath" testFileSbKey testFileCbNonce Nothing
    DB.execute_ db "UPDATE snd_files SET status = 'new', num_recipients = 'bad' WHERE snd_file_id = 1"
    Right fId2 <- createSndFile db g 1 (CryptoFile "filepath" Nothing) 1 "filepath" testFileSbKey testFileCbNonce Nothing
    DB.execute_ db "UPDATE snd_files SET status = 'new' WHERE snd_file_id = 2"

    Left e <- getNextSndFileToPrepare db 86400
    show e `shouldContain` "ConversionFailed"
    DB.query_ db "SELECT snd_file_id FROM snd_files WHERE failed = 1" `shouldReturn` [Only (1 :: Int)]

    Right (Just SndFile {sndFileEntityId}) <- getNextSndFileToPrepare db 86400
    sndFileEntityId `shouldBe` fId2

newSndChunkReplica1 :: NewSndChunkReplica
newSndChunkReplica1 =
  NewSndChunkReplica
    { server = xftpServer1,
      replicaId = ChunkReplicaId "abc",
      replicaKey = testFileReplicaKey,
      rcvIdsKeys = [(ChunkReplicaId "abc", testFileReplicaKey)]
    }

testGetNextSndChunkToUpload :: SQLiteStore -> Expectation
testGetNextSndChunkToUpload st = do
  g <- C.newRandom
  withTransaction st $ \db -> do
    Right Nothing <- getNextSndChunkToUpload db xftpServer1 86400

    -- create file 1
    Right _ <- createSndFile db g 1 (CryptoFile "filepath" Nothing) 1 "filepath" testFileSbKey testFileCbNonce Nothing
    updateSndFileEncrypted db 1 (FileDigest "abc") [(XFTPChunkSpec "filepath" 1 1, FileDigest "ghi")]
    createSndFileReplica_ db 1 newSndChunkReplica1
    DB.execute_ db "UPDATE snd_files SET num_recipients = 'bad' WHERE snd_file_id = 1"
    -- create file 2
    Right fId2 <- createSndFile db g 1 (CryptoFile "filepath" Nothing) 1 "filepath" testFileSbKey testFileCbNonce Nothing
    updateSndFileEncrypted db 2 (FileDigest "abc") [(XFTPChunkSpec "filepath" 1 1, FileDigest "ghi")]
    createSndFileReplica_ db 2 newSndChunkReplica1

    Left e <- getNextSndChunkToUpload db xftpServer1 86400
    show e `shouldContain` "ConversionFailed"
    DB.query_ db "SELECT snd_file_id FROM snd_files WHERE failed = 1" `shouldReturn` [Only (1 :: Int)]

    Right (Just SndFileChunk {sndFileEntityId}) <- getNextSndChunkToUpload db xftpServer1 86400
    sndFileEntityId `shouldBe` fId2

testGetNextDeletedSndChunkReplica :: SQLiteStore -> Expectation
testGetNextDeletedSndChunkReplica st = do
  withTransaction st $ \db -> do
    Right Nothing <- getNextDeletedSndChunkReplica db xftpServer1 86400

    createDeletedSndChunkReplica db 1 (FileChunkReplica xftpServer1 (ChunkReplicaId "abc") testFileReplicaKey) (FileDigest "ghi")
    DB.execute_ db "UPDATE deleted_snd_chunk_replicas SET delay = 'bad' WHERE deleted_snd_chunk_replica_id = 1"
    createDeletedSndChunkReplica db 1 (FileChunkReplica xftpServer1 (ChunkReplicaId "abc") testFileReplicaKey) (FileDigest "ghi")

    Left e <- getNextDeletedSndChunkReplica db xftpServer1 86400
    show e `shouldContain` "ConversionFailed"
    DB.query_ db "SELECT deleted_snd_chunk_replica_id FROM deleted_snd_chunk_replicas WHERE failed = 1" `shouldReturn` [Only (1 :: Int)]

    Right (Just DeletedSndChunkReplica {deletedSndChunkReplicaId}) <- getNextDeletedSndChunkReplica db xftpServer1 86400
    deletedSndChunkReplicaId `shouldBe` 2

testMarkNtfSubActionNtfFailed :: SQLiteStore -> Expectation
testMarkNtfSubActionNtfFailed st = do
  withTransaction st $ \db -> do
    markNtfSubActionNtfFailed_ db "abc"

testMarkNtfSubActionSMPFailed :: SQLiteStore -> Expectation
testMarkNtfSubActionSMPFailed st = do
  withTransaction st $ \db -> do
    markNtfSubActionSMPFailed_ db "abc"
