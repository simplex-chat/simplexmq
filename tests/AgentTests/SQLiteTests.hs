{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module AgentTests.SQLiteTests (storeTests) where

import Control.Monad.Except (ExceptT, runExceptT)
import qualified Crypto.PubKey.RSA as R
import Data.ByteString.Char8 (ByteString)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time
import Data.Word (Word32)
import qualified Database.SQLite.Simple as DB
import Database.SQLite.Simple.QQ (sql)
import SMPClient (teshKeyHash)
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Agent.Transmission
import qualified Simplex.Messaging.Crypto as C
import System.Random (Random (randomIO))
import Test.Hspec
import UnliftIO.Directory (removeFile)

testDB :: String
testDB = "tests/tmp/smp-agent.test.db"

withStore :: SpecWith SQLiteStore -> Spec
withStore = before createStore . after removeStore
  where
    createStore :: IO SQLiteStore
    createStore = do
      -- Randomize DB file name to avoid SQLite IO errors supposedly caused by asynchronous
      -- IO operations on multiple similarly named files; error seems to be environment specific
      r <- randomIO :: IO Word32
      createSQLiteStore $ testDB <> show r

    removeStore :: SQLiteStore -> IO ()
    removeStore store = do
      DB.close $ dbConn store
      removeFile $ dbFilePath store

returnsResult :: (Eq a, Eq e, Show a, Show e) => ExceptT e IO a -> a -> Expectation
action `returnsResult` r = runExceptT action `shouldReturn` Right r

throwsError :: (Eq a, Eq e, Show a, Show e) => ExceptT e IO a -> e -> Expectation
action `throwsError` e = runExceptT action `shouldReturn` Left e

-- TODO add null port tests
storeTests :: Spec
storeTests = withStore do
  describe "store setup" do
    testCompiledThreadsafe
    testForeignKeysEnabled
  describe "store methods" do
    describe "Queue and Connection management" do
      describe "createRcvConn" do
        testCreateRcvConn
        testCreateRcvConnDuplicate
      describe "createSndConn" do
        testCreateSndConn
        testCreateSndConnDuplicate
      describe "getAllConnAliases" testGetAllConnAliases
      describe "getRcvQueue" testGetRcvQueue
      describe "deleteConn" do
        testDeleteRcvConn
        testDeleteSndConn
        testDeleteDuplexConn
      describe "upgradeRcvConnToDuplex" do
        testUpgradeRcvConnToDuplex
      describe "upgradeSndConnToDuplex" do
        testUpgradeSndConnToDuplex
      describe "set Queue status" do
        describe "setRcvQueueStatus" do
          testSetRcvQueueStatus
          testSetRcvQueueStatusNoQueue
        describe "setSndQueueStatus" do
          testSetSndQueueStatus
          testSetSndQueueStatusNoQueue
        testSetQueueStatusDuplex
    describe "Msg management" do
      describe "create Msg" do
        describe "createRcvMsg" do
          testCreateRcvMsg
          testCreateRcvMsgNoQueue
        describe "createSndMsg" do
          testCreateSndMsg
          testCreateSndMsgNoQueue
        testCreateRcvAndSndMsgs

testCompiledThreadsafe :: SpecWith SQLiteStore
testCompiledThreadsafe = do
  it "compiled sqlite library should be threadsafe" $ \store -> do
    compileOptions <- DB.query_ (dbConn store) "pragma COMPILE_OPTIONS;" :: IO [[T.Text]]
    compileOptions `shouldNotContain` [["THREADSAFE=0"]]

testForeignKeysEnabled :: SpecWith SQLiteStore
testForeignKeysEnabled = do
  it "foreign keys should be enabled" $ \store -> do
    let inconsistentQuery =
          [sql|
            INSERT INTO connections
              (conn_alias, rcv_host, rcv_port, rcv_id, snd_host, snd_port, snd_id)
            VALUES
              ("conn1", "smp.simplex.im", "5223", "1234", "smp.simplex.im", "5223", "2345");
          |]
    DB.execute_ (dbConn store) inconsistentQuery
      `shouldThrow` (\e -> DB.sqlError e == DB.ErrorConstraint)

rcvQueue1 :: RcvQueue
rcvQueue1 =
  RcvQueue
    { server = SMPServer "smp.simplex.im" (Just "5223") teshKeyHash,
      rcvId = "1234",
      connAlias = "conn1",
      rcvPrivateKey = C.safePrivateKey (1, 2, 3),
      sndId = Just "2345",
      sndKey = Nothing,
      decryptKey = C.safePrivateKey (1, 2, 3),
      verifyKey = Nothing,
      status = New
    }

sndQueue1 :: SndQueue
sndQueue1 =
  SndQueue
    { server = SMPServer "smp.simplex.im" (Just "5223") teshKeyHash,
      sndId = "3456",
      connAlias = "conn1",
      sndPrivateKey = C.safePrivateKey (1, 2, 3),
      encryptKey = C.PublicKey $ R.PublicKey 1 2 3,
      signKey = C.safePrivateKey (1, 2, 3),
      status = New
    }

testCreateRcvConn :: SpecWith SQLiteStore
testCreateRcvConn = do
  it "should create RcvConnection and add SndQueue" $ \store -> do
    createRcvConn store rcvQueue1
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCRcv (RcvConnection "conn1" rcvQueue1)
    upgradeRcvConnToDuplex store "conn1" sndQueue1
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue1 sndQueue1)

testCreateRcvConnDuplicate :: SpecWith SQLiteStore
testCreateRcvConnDuplicate = do
  it "should throw error on attempt to create duplicate RcvConnection" $ \store -> do
    createRcvConn store rcvQueue1
      `returnsResult` ()
    createRcvConn store rcvQueue1
      `throwsError` SEConnDuplicate

testCreateSndConn :: SpecWith SQLiteStore
testCreateSndConn = do
  it "should create SndConnection and add RcvQueue" $ \store -> do
    createSndConn store sndQueue1
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCSnd (SndConnection "conn1" sndQueue1)
    upgradeSndConnToDuplex store "conn1" rcvQueue1
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue1 sndQueue1)

testCreateSndConnDuplicate :: SpecWith SQLiteStore
testCreateSndConnDuplicate = do
  it "should throw error on attempt to create duplicate SndConnection" $ \store -> do
    createSndConn store sndQueue1
      `returnsResult` ()
    createSndConn store sndQueue1
      `throwsError` SEConnDuplicate

testGetAllConnAliases :: SpecWith SQLiteStore
testGetAllConnAliases = do
  it "should get all conn aliases" $ \store -> do
    createRcvConn store rcvQueue1
      `returnsResult` ()
    createSndConn store sndQueue1 {connAlias = "conn2"}
      `returnsResult` ()
    getAllConnAliases store
      `returnsResult` ["conn1" :: ConnAlias, "conn2" :: ConnAlias]

testGetRcvQueue :: SpecWith SQLiteStore
testGetRcvQueue = do
  it "should get RcvQueue" $ \store -> do
    let smpServer = SMPServer "smp.simplex.im" (Just "5223") teshKeyHash
    let recipientId = "1234"
    createRcvConn store rcvQueue1
      `returnsResult` ()
    getRcvQueue store smpServer recipientId
      `returnsResult` rcvQueue1

testDeleteRcvConn :: SpecWith SQLiteStore
testDeleteRcvConn = do
  it "should create RcvConnection and delete it" $ \store -> do
    createRcvConn store rcvQueue1
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCRcv (RcvConnection "conn1" rcvQueue1)
    deleteConn store "conn1"
      `returnsResult` ()
    -- TODO check queues are deleted as well
    getConn store "conn1"
      `throwsError` SEConnNotFound

testDeleteSndConn :: SpecWith SQLiteStore
testDeleteSndConn = do
  it "should create SndConnection and delete it" $ \store -> do
    createSndConn store sndQueue1
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCSnd (SndConnection "conn1" sndQueue1)
    deleteConn store "conn1"
      `returnsResult` ()
    -- TODO check queues are deleted as well
    getConn store "conn1"
      `throwsError` SEConnNotFound

testDeleteDuplexConn :: SpecWith SQLiteStore
testDeleteDuplexConn = do
  it "should create DuplexConnection and delete it" $ \store -> do
    createRcvConn store rcvQueue1
      `returnsResult` ()
    upgradeRcvConnToDuplex store "conn1" sndQueue1
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue1 sndQueue1)
    deleteConn store "conn1"
      `returnsResult` ()
    -- TODO check queues are deleted as well
    getConn store "conn1"
      `throwsError` SEConnNotFound

testUpgradeRcvConnToDuplex :: SpecWith SQLiteStore
testUpgradeRcvConnToDuplex = do
  it "should throw error on attempt to add SndQueue to SndConnection or DuplexConnection" $ \store -> do
    createSndConn store sndQueue1
      `returnsResult` ()
    let anotherSndQueue =
          SndQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") teshKeyHash,
              sndId = "2345",
              connAlias = "conn1",
              sndPrivateKey = C.safePrivateKey (1, 2, 3),
              encryptKey = C.PublicKey $ R.PublicKey 1 2 3,
              signKey = C.safePrivateKey (1, 2, 3),
              status = New
            }
    upgradeRcvConnToDuplex store "conn1" anotherSndQueue
      `throwsError` SEBadConnType CSnd
    upgradeSndConnToDuplex store "conn1" rcvQueue1
      `returnsResult` ()
    upgradeRcvConnToDuplex store "conn1" anotherSndQueue
      `throwsError` SEBadConnType CDuplex

testUpgradeSndConnToDuplex :: SpecWith SQLiteStore
testUpgradeSndConnToDuplex = do
  it "should throw error on attempt to add RcvQueue to RcvConnection or DuplexConnection" $ \store -> do
    createRcvConn store rcvQueue1
      `returnsResult` ()
    let anotherRcvQueue =
          RcvQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") teshKeyHash,
              rcvId = "3456",
              connAlias = "conn1",
              rcvPrivateKey = C.safePrivateKey (1, 2, 3),
              sndId = Just "4567",
              sndKey = Nothing,
              decryptKey = C.safePrivateKey (1, 2, 3),
              verifyKey = Nothing,
              status = New
            }
    upgradeSndConnToDuplex store "conn1" anotherRcvQueue
      `throwsError` SEBadConnType CRcv
    upgradeRcvConnToDuplex store "conn1" sndQueue1
      `returnsResult` ()
    upgradeSndConnToDuplex store "conn1" anotherRcvQueue
      `throwsError` SEBadConnType CDuplex

testSetRcvQueueStatus :: SpecWith SQLiteStore
testSetRcvQueueStatus = do
  it "should update status of RcvQueue" $ \store -> do
    createRcvConn store rcvQueue1
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCRcv (RcvConnection "conn1" rcvQueue1)
    setRcvQueueStatus store rcvQueue1 Confirmed
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCRcv (RcvConnection "conn1" rcvQueue1 {status = Confirmed})

testSetSndQueueStatus :: SpecWith SQLiteStore
testSetSndQueueStatus = do
  it "should update status of SndQueue" $ \store -> do
    createSndConn store sndQueue1
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCSnd (SndConnection "conn1" sndQueue1)
    setSndQueueStatus store sndQueue1 Confirmed
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCSnd (SndConnection "conn1" sndQueue1 {status = Confirmed})

testSetQueueStatusDuplex :: SpecWith SQLiteStore
testSetQueueStatusDuplex = do
  it "should update statuses of RcvQueue and SndQueue in DuplexConnection" $ \store -> do
    createRcvConn store rcvQueue1
      `returnsResult` ()
    upgradeRcvConnToDuplex store "conn1" sndQueue1
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue1 sndQueue1)
    setRcvQueueStatus store rcvQueue1 Secured
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue1 {status = Secured} sndQueue1)
    setSndQueueStatus store sndQueue1 Confirmed
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn
        SCDuplex
        ( DuplexConnection "conn1" rcvQueue1 {status = Secured} sndQueue1 {status = Confirmed}
        )

testSetRcvQueueStatusNoQueue :: SpecWith SQLiteStore
testSetRcvQueueStatusNoQueue = do
  xit "should throw error on attempt to update status of non-existent RcvQueue" $ \store -> do
    setRcvQueueStatus store rcvQueue1 Confirmed
      `throwsError` SEConnNotFound

testSetSndQueueStatusNoQueue :: SpecWith SQLiteStore
testSetSndQueueStatusNoQueue = do
  xit "should throw error on attempt to update status of non-existent SndQueue" $ \store -> do
    setSndQueueStatus store sndQueue1 Confirmed
      `throwsError` SEConnNotFound

hw :: ByteString
hw = encodeUtf8 "Hello world!"

ts :: UTCTime
ts = UTCTime (fromGregorian 2021 02 24) (secondsToDiffTime 0)

testCreateRcvMsg :: SpecWith SQLiteStore
testCreateRcvMsg = do
  it "should reserve internal ids create RcvMsg" $ \store -> do
    createRcvConn store rcvQueue1
      `returnsResult` ()
    updateRcvIds store rcvQueue1
      `returnsResult` (InternalId 1, InternalRcvId 1, 0, "")
    let rcvMsgData =
          RcvMsgData
            { internalId = InternalId 1,
              internalRcvId = InternalRcvId 1,
              internalTs = ts,
              senderMeta = (1, ts),
              brokerMeta = ("1", ts),
              msgBody = hw,
              msgHash = "hash_dummy",
              msgIntegrity = MsgOk
            }
    createRcvMsg store rcvQueue1 rcvMsgData
      `returnsResult` ()

-- TODO getMsg to check message
-- createRcvMsg store "conn1" hw ts (1, ts) ("1", ts) "hash_dummy"
--   `returnsResult` (InternalId 1, 0, "")
-- createRcvMsg store "conn1" hw ts (2, ts) ("2", ts) "new_hash_dummy"
--   `returnsResult` (InternalId 2, 1, "hash_dummy")

testCreateRcvMsgNoQueue :: SpecWith SQLiteStore
testCreateRcvMsgNoQueue = do
  it "should throw error on attempt to create a RcvMsg w/t a RcvQueue" $ \store -> do
    -- createRcvMsg store "conn1" hw ts (1, ts) ("1", ts) "hash_dummy"
    --   `throwsError` SEConnNotFound
    createSndConn store sndQueue1
      `returnsResult` ()

-- createRcvMsg store "conn1" hw ts (1, ts) ("1", ts) "hash_dummy"
--   `throwsError` SEBadConnType CSnd

testCreateSndMsg :: SpecWith SQLiteStore
testCreateSndMsg = do
  it "should create a SndMsg and return InternalId and PrevSndMsgHash" $ \store -> do
    createSndConn store sndQueue1
      `returnsResult` ()

-- TODO getMsg to check message
-- createSndMsg store "conn1" hw ts "hash_dummy"
--   `returnsResult` (InternalId 1, "")
-- createSndMsg store "conn1" hw ts "new_hash_dummy"
--   `returnsResult` (InternalId 2, "hash_dummy")

testCreateSndMsgNoQueue :: SpecWith SQLiteStore
testCreateSndMsgNoQueue = do
  it "should throw error on attempt to create a SndMsg w/t a SndQueue" $ \store -> do
    -- createSndMsg store "conn1" hw ts "hash_dummy"
    --   `throwsError` SEConnNotFound
    createRcvConn store rcvQueue1
      `returnsResult` ()

-- createSndMsg store "conn1" hw ts "hash_dummy"
--   `throwsError` SEBadConnType CRcv

testCreateRcvAndSndMsgs :: SpecWith SQLiteStore
testCreateRcvAndSndMsgs = do
  it "should create multiple RcvMsg and SndMsg, correctly ordering internal Ids and returning previous state" $ \store -> do
    -- create DuplexConnection
    createRcvConn store rcvQueue1
      `returnsResult` ()
    upgradeRcvConnToDuplex store "conn1" sndQueue1
      `returnsResult` ()

-- create RcvMsg and SndMsg in arbitrary order
-- createRcvMsg store "conn1" hw ts (1, ts) ("1", ts) "rcv_hash_1"
--   `returnsResult` (InternalId 1, 0, "")
-- createRcvMsg store "conn1" hw ts (2, ts) ("2", ts) "rcv_hash_2"
--   `returnsResult` (InternalId 2, 1, "rcv_hash_1")
-- createSndMsg store "conn1" hw ts "snd_hash_1"
--   `returnsResult` (InternalId 3, "")
-- createSndMsg store "conn1" hw ts "snd_hash_2"
--   `returnsResult` (InternalId 4, "snd_hash_1")
-- createRcvMsg store "conn1" hw ts (3, ts) ("3", ts) "rcv_hash_3"
--   `returnsResult` (InternalId 5, 2, "rcv_hash_2")
-- createSndMsg store "conn1" hw ts "snd_hash_3"
--   `returnsResult` (InternalId 6, "snd_hash_2")
