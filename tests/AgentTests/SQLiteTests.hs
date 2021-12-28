{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}

module AgentTests.SQLiteTests (storeTests) where

import Control.Concurrent.Async (concurrently_)
import Control.Concurrent.STM
import Control.Monad (replicateM_)
import Control.Monad.Except (ExceptT, runExceptT)
import Crypto.Random (drgNew)
import Data.ByteString.Char8 (ByteString)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time
import Data.Word (Word32)
import qualified Database.SQLite.Simple as DB
import Database.SQLite.Simple.QQ (sql)
import SMPClient (testKeyHash)
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import qualified Simplex.Messaging.Crypto as C
import System.Random
import Test.Hspec
import UnliftIO.Directory (removeFile)

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
      s2 <- connectSQLiteStore (dbFilePath s1) 4
      pure (s1, s2)

createStore :: IO SQLiteStore
createStore = do
  -- Randomize DB file name to avoid SQLite IO errors supposedly caused by asynchronous
  -- IO operations on multiple similarly named files; error seems to be environment specific
  r <- randomIO :: IO Word32
  createSQLiteStore (testDB <> show r) 4 Migrations.app

removeStore :: SQLiteStore -> IO ()
removeStore store = do
  close store
  removeFile $ dbFilePath store
  where
    close :: SQLiteStore -> IO ()
    close st = mapM_ DB.close =<< atomically (flushTBQueue $ dbConnPool st)

returnsResult :: (Eq a, Eq e, Show a, Show e) => ExceptT e IO a -> a -> Expectation
action `returnsResult` r = runExceptT action `shouldReturn` Right r

throwsError :: (Eq a, Eq e, Show a, Show e) => ExceptT e IO a -> e -> Expectation
action `throwsError` e = runExceptT action `shouldReturn` Left e

-- TODO add null port tests
storeTests :: Spec
storeTests = do
  withStore2 $ do
    describe "stress test" testConcurrentWrites
  withStore $ do
    describe "store setup" $ do
      testCompiledThreadsafe
      testForeignKeysEnabled
    describe "store methods" $ do
      describe "Queue and Connection management" $ do
        describe "createRcvConn" $ do
          testCreateRcvConn
          testCreateRcvConnRandomId
          testCreateRcvConnDuplicate
        describe "createSndConn" $ do
          testCreateSndConn
          testCreateSndConnRandomID
          testCreateSndConnDuplicate
        describe "getAllConnIds" testGetAllConnIds
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
            testSetRcvQueueStatusNoQueue
          describe "setSndQueueStatus" $ do
            testSetSndQueueStatus
            testSetSndQueueStatusNoQueue
          testSetQueueStatusDuplex
      describe "Msg management" $ do
        describe "create Msg" $ do
          testCreateRcvMsg
          testCreateSndMsg
          testCreateRcvAndSndMsgs

testConcurrentWrites :: SpecWith (SQLiteStore, SQLiteStore)
testConcurrentWrites =
  it "should complete multiple concurrent write transactions w/t sqlite busy errors" $ \(s1, s2) -> do
    g <- newTVarIO =<< drgNew
    _ <- runExceptT $ createRcvConn s1 g cData1 rcvQueue1 SCMInvitation
    let ConnData {connId} = cData1
    concurrently_ (runTest s1 connId) (runTest s2 connId)
  where
    runTest :: SQLiteStore -> ConnId -> IO (Either StoreError ())
    runTest store connId = runExceptT . replicateM_ 100 $ do
      (internalId, internalRcvId, _, _) <- updateRcvIds store connId
      let rcvMsgData = mkRcvMsgData internalId internalRcvId 0 "0" "hash_dummy"
      createRcvMsg store connId rcvMsgData

testCompiledThreadsafe :: SpecWith SQLiteStore
testCompiledThreadsafe =
  it "compiled sqlite library should be threadsafe" . withStoreConnection $ \db -> do
    compileOptions <- DB.query_ db "pragma COMPILE_OPTIONS;" :: IO [[T.Text]]
    compileOptions `shouldNotContain` [["THREADSAFE=0"]]

withStoreConnection :: (DB.Connection -> IO a) -> SQLiteStore -> IO a
withStoreConnection = flip withConnection

testForeignKeysEnabled :: SpecWith SQLiteStore
testForeignKeysEnabled =
  it "foreign keys should be enabled" . withStoreConnection $ \db -> do
    let inconsistentQuery =
          [sql|
            INSERT INTO connections
              (conn_alias, rcv_host, rcv_port, rcv_id, snd_host, snd_port, snd_id)
            VALUES
              ("conn1", "smp.simplex.im", "5223", "1234", "smp.simplex.im", "5223", "2345");
          |]
    DB.execute_ db inconsistentQuery
      `shouldThrow` (\e -> DB.sqlError e == DB.ErrorConstraint)

cData1 :: ConnData
cData1 = ConnData {connId = "conn1"}

testPrivateSignKey :: C.APrivateSignKey
testPrivateSignKey = C.APrivateSignKey C.SEd25519 "MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe"

testPubDhKey :: C.PublicKeyX25519
testPubDhKey = "MCowBQYDK2VuAyEAjiswwI3O/NlS8Fk3HJUW870EY2bAwmttMBsvRB9eV3o="

testPrivDhKey :: C.PrivateKeyX25519
testPrivDhKey = "MC4CAQAwBQYDK2VuBCIEINCzbVFaCiYHoYncxNY8tSIfn0pXcIAhLBfFc0m+gOpk"

testDhSecret :: C.DhSecretX25519
testDhSecret = "01234567890123456789012345678901"

rcvQueue1 :: RcvQueue
rcvQueue1 =
  RcvQueue
    { server = SMPServer "smp.simplex.im" (Just "5223") testKeyHash,
      rcvId = "1234",
      rcvPrivateKey = testPrivateSignKey,
      rcvDhSecret = testDhSecret,
      e2ePrivKey = testPrivDhKey,
      e2eShared = Nothing,
      sndId = Just "2345",
      status = New
    }

sndQueue1 :: SndQueue
sndQueue1 =
  SndQueue
    { server = SMPServer "smp.simplex.im" (Just "5223") testKeyHash,
      sndId = "3456",
      sndPrivateKey = testPrivateSignKey,
      e2ePubKey = testPubDhKey,
      e2eDhSecret = testDhSecret,
      status = New
    }

testCreateRcvConn :: SpecWith SQLiteStore
testCreateRcvConn =
  it "should create RcvConnection and add SndQueue" $ \store -> do
    g <- newTVarIO =<< drgNew
    createRcvConn store g cData1 rcvQueue1 SCMInvitation
      `returnsResult` "conn1"
    getConn store "conn1"
      `returnsResult` SomeConn SCRcv (RcvConnection cData1 rcvQueue1)
    upgradeRcvConnToDuplex store "conn1" sndQueue1
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection cData1 rcvQueue1 sndQueue1)

testCreateRcvConnRandomId :: SpecWith SQLiteStore
testCreateRcvConnRandomId =
  it "should create RcvConnection and add SndQueue with random ID" $ \store -> do
    g <- newTVarIO =<< drgNew
    Right connId <- runExceptT $ createRcvConn store g cData1 {connId = ""} rcvQueue1 SCMInvitation
    getConn store connId
      `returnsResult` SomeConn SCRcv (RcvConnection cData1 {connId} rcvQueue1)
    upgradeRcvConnToDuplex store connId sndQueue1
      `returnsResult` ()
    getConn store connId
      `returnsResult` SomeConn SCDuplex (DuplexConnection cData1 {connId} rcvQueue1 sndQueue1)

testCreateRcvConnDuplicate :: SpecWith SQLiteStore
testCreateRcvConnDuplicate =
  it "should throw error on attempt to create duplicate RcvConnection" $ \store -> do
    g <- newTVarIO =<< drgNew
    _ <- runExceptT $ createRcvConn store g cData1 rcvQueue1 SCMInvitation
    createRcvConn store g cData1 rcvQueue1 SCMInvitation
      `throwsError` SEConnDuplicate

testCreateSndConn :: SpecWith SQLiteStore
testCreateSndConn =
  it "should create SndConnection and add RcvQueue" $ \store -> do
    g <- newTVarIO =<< drgNew
    createSndConn store g cData1 sndQueue1
      `returnsResult` "conn1"
    getConn store "conn1"
      `returnsResult` SomeConn SCSnd (SndConnection cData1 sndQueue1)
    upgradeSndConnToDuplex store "conn1" rcvQueue1
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection cData1 rcvQueue1 sndQueue1)

testCreateSndConnRandomID :: SpecWith SQLiteStore
testCreateSndConnRandomID =
  it "should create SndConnection and add RcvQueue with random ID" $ \store -> do
    g <- newTVarIO =<< drgNew
    Right connId <- runExceptT $ createSndConn store g cData1 {connId = ""} sndQueue1
    getConn store connId
      `returnsResult` SomeConn SCSnd (SndConnection cData1 {connId} sndQueue1)
    upgradeSndConnToDuplex store connId rcvQueue1
      `returnsResult` ()
    getConn store connId
      `returnsResult` SomeConn SCDuplex (DuplexConnection cData1 {connId} rcvQueue1 sndQueue1)

testCreateSndConnDuplicate :: SpecWith SQLiteStore
testCreateSndConnDuplicate =
  it "should throw error on attempt to create duplicate SndConnection" $ \store -> do
    g <- newTVarIO =<< drgNew
    _ <- runExceptT $ createSndConn store g cData1 sndQueue1
    createSndConn store g cData1 sndQueue1
      `throwsError` SEConnDuplicate

testGetAllConnIds :: SpecWith SQLiteStore
testGetAllConnIds =
  it "should get all conn aliases" $ \store -> do
    g <- newTVarIO =<< drgNew
    _ <- runExceptT $ createRcvConn store g cData1 rcvQueue1 SCMInvitation
    _ <- runExceptT $ createSndConn store g cData1 {connId = "conn2"} sndQueue1
    getAllConnIds store
      `returnsResult` ["conn1" :: ConnId, "conn2" :: ConnId]

testGetRcvConn :: SpecWith SQLiteStore
testGetRcvConn =
  it "should get connection using rcv queue id and server" $ \store -> do
    let smpServer = SMPServer "smp.simplex.im" (Just "5223") testKeyHash
    let recipientId = "1234"
    g <- newTVarIO =<< drgNew
    _ <- runExceptT $ createRcvConn store g cData1 rcvQueue1 SCMInvitation
    getRcvConn store smpServer recipientId
      `returnsResult` SomeConn SCRcv (RcvConnection cData1 rcvQueue1)

testDeleteRcvConn :: SpecWith SQLiteStore
testDeleteRcvConn =
  it "should create RcvConnection and delete it" $ \store -> do
    g <- newTVarIO =<< drgNew
    _ <- runExceptT $ createRcvConn store g cData1 rcvQueue1 SCMInvitation
    getConn store "conn1"
      `returnsResult` SomeConn SCRcv (RcvConnection cData1 rcvQueue1)
    deleteConn store "conn1"
      `returnsResult` ()
    -- TODO check queues are deleted as well
    getConn store "conn1"
      `throwsError` SEConnNotFound

testDeleteSndConn :: SpecWith SQLiteStore
testDeleteSndConn =
  it "should create SndConnection and delete it" $ \store -> do
    g <- newTVarIO =<< drgNew
    _ <- runExceptT $ createSndConn store g cData1 sndQueue1
    getConn store "conn1"
      `returnsResult` SomeConn SCSnd (SndConnection cData1 sndQueue1)
    deleteConn store "conn1"
      `returnsResult` ()
    -- TODO check queues are deleted as well
    getConn store "conn1"
      `throwsError` SEConnNotFound

testDeleteDuplexConn :: SpecWith SQLiteStore
testDeleteDuplexConn =
  it "should create DuplexConnection and delete it" $ \store -> do
    g <- newTVarIO =<< drgNew
    _ <- runExceptT $ createRcvConn store g cData1 rcvQueue1 SCMInvitation
    _ <- runExceptT $ upgradeRcvConnToDuplex store "conn1" sndQueue1
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection cData1 rcvQueue1 sndQueue1)
    deleteConn store "conn1"
      `returnsResult` ()
    -- TODO check queues are deleted as well
    getConn store "conn1"
      `throwsError` SEConnNotFound

testUpgradeRcvConnToDuplex :: SpecWith SQLiteStore
testUpgradeRcvConnToDuplex =
  it "should throw error on attempt to add SndQueue to SndConnection or DuplexConnection" $ \store -> do
    g <- newTVarIO =<< drgNew
    _ <- runExceptT $ createSndConn store g cData1 sndQueue1
    let anotherSndQueue =
          SndQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") testKeyHash,
              sndId = "2345",
              sndPrivateKey = testPrivateSignKey,
              e2ePubKey = testPubDhKey,
              e2eDhSecret = testDhSecret,
              status = New
            }
    upgradeRcvConnToDuplex store "conn1" anotherSndQueue
      `throwsError` SEBadConnType CSnd
    _ <- runExceptT $ upgradeSndConnToDuplex store "conn1" rcvQueue1
    upgradeRcvConnToDuplex store "conn1" anotherSndQueue
      `throwsError` SEBadConnType CDuplex

testUpgradeSndConnToDuplex :: SpecWith SQLiteStore
testUpgradeSndConnToDuplex =
  it "should throw error on attempt to add RcvQueue to RcvConnection or DuplexConnection" $ \store -> do
    g <- newTVarIO =<< drgNew
    _ <- runExceptT $ createRcvConn store g cData1 rcvQueue1 SCMInvitation
    let anotherRcvQueue =
          RcvQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") testKeyHash,
              rcvId = "3456",
              rcvPrivateKey = testPrivateSignKey,
              rcvDhSecret = testDhSecret,
              e2ePrivKey = testPrivDhKey,
              e2eShared = Nothing,
              sndId = Just "4567",
              status = New
            }
    upgradeSndConnToDuplex store "conn1" anotherRcvQueue
      `throwsError` SEBadConnType CRcv
    _ <- runExceptT $ upgradeRcvConnToDuplex store "conn1" sndQueue1
    upgradeSndConnToDuplex store "conn1" anotherRcvQueue
      `throwsError` SEBadConnType CDuplex

testSetRcvQueueStatus :: SpecWith SQLiteStore
testSetRcvQueueStatus =
  it "should update status of RcvQueue" $ \store -> do
    g <- newTVarIO =<< drgNew
    _ <- runExceptT $ createRcvConn store g cData1 rcvQueue1 SCMInvitation
    getConn store "conn1"
      `returnsResult` SomeConn SCRcv (RcvConnection cData1 rcvQueue1)
    setRcvQueueStatus store rcvQueue1 Confirmed
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCRcv (RcvConnection cData1 rcvQueue1 {status = Confirmed})

testSetSndQueueStatus :: SpecWith SQLiteStore
testSetSndQueueStatus =
  it "should update status of SndQueue" $ \store -> do
    g <- newTVarIO =<< drgNew
    _ <- runExceptT $ createSndConn store g cData1 sndQueue1
    getConn store "conn1"
      `returnsResult` SomeConn SCSnd (SndConnection cData1 sndQueue1)
    setSndQueueStatus store sndQueue1 Confirmed
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCSnd (SndConnection cData1 sndQueue1 {status = Confirmed})

testSetQueueStatusDuplex :: SpecWith SQLiteStore
testSetQueueStatusDuplex =
  it "should update statuses of RcvQueue and SndQueue in DuplexConnection" $ \store -> do
    g <- newTVarIO =<< drgNew
    _ <- runExceptT $ createRcvConn store g cData1 rcvQueue1 SCMInvitation
    _ <- runExceptT $ upgradeRcvConnToDuplex store "conn1" sndQueue1
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection cData1 rcvQueue1 sndQueue1)
    setRcvQueueStatus store rcvQueue1 Secured
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection cData1 rcvQueue1 {status = Secured} sndQueue1)
    setSndQueueStatus store sndQueue1 Confirmed
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection cData1 rcvQueue1 {status = Secured} sndQueue1 {status = Confirmed})

testSetRcvQueueStatusNoQueue :: SpecWith SQLiteStore
testSetRcvQueueStatusNoQueue =
  xit "should throw error on attempt to update status of non-existent RcvQueue" $ \store -> do
    setRcvQueueStatus store rcvQueue1 Confirmed
      `throwsError` SEConnNotFound

testSetSndQueueStatusNoQueue :: SpecWith SQLiteStore
testSetSndQueueStatusNoQueue =
  xit "should throw error on attempt to update status of non-existent SndQueue" $ \store -> do
    setSndQueueStatus store sndQueue1 Confirmed
      `throwsError` SEConnNotFound

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
            sender = (externalSndId, ts),
            broker = (brokerId, ts)
          },
      msgBody = hw,
      internalHash,
      externalPrevSndHash = "hash_from_sender"
    }

testCreateRcvMsg' :: SQLiteStore -> PrevExternalSndId -> PrevRcvMsgHash -> ConnId -> RcvMsgData -> Expectation
testCreateRcvMsg' st expectedPrevSndId expectedPrevHash connId rcvMsgData@RcvMsgData {..} = do
  let MsgMeta {recipient = (internalId, _)} = msgMeta
  updateRcvIds st connId
    `returnsResult` (InternalId internalId, internalRcvId, expectedPrevSndId, expectedPrevHash)
  createRcvMsg st connId rcvMsgData
    `returnsResult` ()

testCreateRcvMsg :: SpecWith SQLiteStore
testCreateRcvMsg =
  it "should reserve internal ids and create a RcvMsg" $ \st -> do
    g <- newTVarIO =<< drgNew
    let ConnData {connId} = cData1
    _ <- runExceptT $ createRcvConn st g cData1 rcvQueue1 SCMInvitation
    -- TODO getMsg to check message
    testCreateRcvMsg' st 0 "" connId $ mkRcvMsgData (InternalId 1) (InternalRcvId 1) 1 "1" "hash_dummy"
    testCreateRcvMsg' st 1 "hash_dummy" connId $ mkRcvMsgData (InternalId 2) (InternalRcvId 2) 2 "2" "new_hash_dummy"

mkSndMsgData :: InternalId -> InternalSndId -> MsgHash -> SndMsgData
mkSndMsgData internalId internalSndId internalHash =
  SndMsgData
    { internalId,
      internalSndId,
      internalTs = ts,
      msgBody = hw,
      internalHash,
      previousMsgHash = internalHash
    }

testCreateSndMsg' :: SQLiteStore -> PrevSndMsgHash -> ConnId -> SndMsgData -> Expectation
testCreateSndMsg' store expectedPrevHash connId sndMsgData@SndMsgData {..} = do
  updateSndIds store connId
    `returnsResult` (internalId, internalSndId, expectedPrevHash)
  createSndMsg store connId sndMsgData
    `returnsResult` ()

testCreateSndMsg :: SpecWith SQLiteStore
testCreateSndMsg =
  it "should create a SndMsg and return InternalId and PrevSndMsgHash" $ \store -> do
    g <- newTVarIO =<< drgNew
    let ConnData {connId} = cData1
    _ <- runExceptT $ createSndConn store g cData1 sndQueue1
    -- TODO getMsg to check message
    testCreateSndMsg' store "" connId $ mkSndMsgData (InternalId 1) (InternalSndId 1) "hash_dummy"
    testCreateSndMsg' store "hash_dummy" connId $ mkSndMsgData (InternalId 2) (InternalSndId 2) "new_hash_dummy"

testCreateRcvAndSndMsgs :: SpecWith SQLiteStore
testCreateRcvAndSndMsgs =
  it "should create multiple RcvMsg and SndMsg, correctly ordering internal Ids and returning previous state" $ \store -> do
    g <- newTVarIO =<< drgNew
    let ConnData {connId} = cData1
    _ <- runExceptT $ createRcvConn store g cData1 rcvQueue1 SCMInvitation
    _ <- runExceptT $ upgradeRcvConnToDuplex store "conn1" sndQueue1
    testCreateRcvMsg' store 0 "" connId $ mkRcvMsgData (InternalId 1) (InternalRcvId 1) 1 "1" "rcv_hash_1"
    testCreateRcvMsg' store 1 "rcv_hash_1" connId $ mkRcvMsgData (InternalId 2) (InternalRcvId 2) 2 "2" "rcv_hash_2"
    testCreateSndMsg' store "" connId $ mkSndMsgData (InternalId 3) (InternalSndId 1) "snd_hash_1"
    testCreateRcvMsg' store 2 "rcv_hash_2" connId $ mkRcvMsgData (InternalId 4) (InternalRcvId 3) 3 "3" "rcv_hash_3"
    testCreateSndMsg' store "snd_hash_1" connId $ mkSndMsgData (InternalId 5) (InternalSndId 2) "snd_hash_2"
    testCreateSndMsg' store "snd_hash_2" connId $ mkSndMsgData (InternalId 6) (InternalSndId 3) "snd_hash_3"
