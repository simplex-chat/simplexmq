{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module AgentTests.SQLiteTests (storeTests) where

import Control.Monad.Except (ExceptT, runExceptT)
import qualified Crypto.PubKey.RSA as R
import Data.Text.Encoding (encodeUtf8)
import Data.Time
import Data.Word (Word32)
import qualified Database.SQLite.Simple as DB
import Database.SQLite.Simple.QQ (sql)
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Agent.Transmission
import qualified Simplex.Messaging.Crypto as C
import System.Random (Random (randomIO))
import Test.Hspec
import UnliftIO.Directory (removeFile)

testDB :: String
testDB = "smp-agent.test.db"

withStore :: SpecWith SQLiteStore -> Spec
withStore = before createStore . after removeStore
  where
    createStore :: IO SQLiteStore
    createStore = do
      -- Randomize DB file name to avoid SQLite IO errors supposedly caused by asynchronous
      -- IO operations on multiple similarly named files; error seems to be environment specific
      r <- randomIO :: IO Word32
      newSQLiteStore $ testDB <> show r

    removeStore :: SQLiteStore -> IO ()
    removeStore store = do
      DB.close $ dbConn store
      removeFile $ dbFilename store

returnsResult :: (Eq a, Eq e, Show a, Show e) => ExceptT e IO a -> a -> Expectation
action `returnsResult` r = runExceptT action `shouldReturn` Right r

throwsError :: (Eq a, Eq e, Show a, Show e) => ExceptT e IO a -> e -> Expectation
action `throwsError` e = runExceptT action `shouldReturn` Left e

-- TODO add null port tests
storeTests :: Spec
storeTests = withStore do
  describe "foreign keys enabled" testForeignKeysEnabled
  describe "store methods" do
    describe "createRcvConn" testCreateRcvConn
    describe "createSndConn" testCreateSndConn
    describe "getRcvQueue" testGetRcvQueue
    describe "deleteConn" do
      describe "RcvConnection" testDeleteRcvConn
      describe "SndConnection" testDeleteSndConn
      describe "DuplexConnection" testDeleteDuplexConn
    describe "upgradeRcvConnToDuplex" testUpgradeRcvConnToDuplex
    describe "upgradeSndConnToDuplex" testUpgradeSndConnToDuplex
    describe "set queue status" do
      describe "setRcvQueueStatus" testSetRcvQueueStatus
      describe "setSndQueueStatus" testSetSndQueueStatus
      describe "DuplexConnection" testSetQueueStatusDuplex
      xdescribe "RcvQueue doesn't exist" testSetRcvQueueStatusNoQueue
      xdescribe "SndQueue doesn't exist" testSetSndQueueStatusNoQueue
    describe "createRcvMsg" do
      describe "RcvQueue exists" testCreateRcvMsg
      describe "RcvQueue doesn't exist" testCreateRcvMsgNoQueue
    describe "createSndMsg" do
      describe "SndQueue exists" testCreateSndMsg
      describe "SndQueue doesn't exist" testCreateSndMsgNoQueue

testForeignKeysEnabled :: SpecWith SQLiteStore
testForeignKeysEnabled = do
  it "should throw error if foreign keys are enabled" $ \store -> do
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
    { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
      rcvId = "1234",
      connAlias = "conn1",
      rcvPrivateKey = C.PrivateKey 1 2 3,
      sndId = Just "2345",
      sndKey = Nothing,
      decryptKey = C.PrivateKey 1 2 3,
      verifyKey = Nothing,
      status = New
    }

sndQueue1 :: SndQueue
sndQueue1 =
  SndQueue
    { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
      sndId = "3456",
      connAlias = "conn1",
      sndPrivateKey = C.PrivateKey 1 2 3,
      encryptKey = C.PublicKey $ R.PublicKey 1 2 3,
      signKey = C.PrivateKey 1 2 3,
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

testGetRcvQueue :: SpecWith SQLiteStore
testGetRcvQueue = do
  it "should get RcvQueue" $ \store -> do
    let smpServer = SMPServer "smp.simplex.im" (Just "5223") (Just "1234")
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
      `throwsError` SEBadConn

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
      `throwsError` SEBadConn

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
      `throwsError` SEBadConn

testUpgradeRcvConnToDuplex :: SpecWith SQLiteStore
testUpgradeRcvConnToDuplex = do
  it "should throw error on attempt to add SndQueue to SndConnection or DuplexConnection" $ \store -> do
    createSndConn store sndQueue1
      `returnsResult` ()
    let anotherSndQueue =
          SndQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              sndId = "2345",
              connAlias = "conn1",
              sndPrivateKey = C.PrivateKey 1 2 3,
              encryptKey = C.PublicKey $ R.PublicKey 1 2 3,
              signKey = C.PrivateKey 1 2 3,
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
            { server = SMPServer "smp.simplex.im" (Just "5223") (Just "1234"),
              rcvId = "3456",
              connAlias = "conn1",
              rcvPrivateKey = C.PrivateKey 1 2 3,
              sndId = Just "4567",
              sndKey = Nothing,
              decryptKey = C.PrivateKey 1 2 3,
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
  it "should throw error on attempt to update status of nonexistent RcvQueue" $ \store -> do
    setRcvQueueStatus store rcvQueue1 Confirmed
      `throwsError` SEInternal

testSetSndQueueStatusNoQueue :: SpecWith SQLiteStore
testSetSndQueueStatusNoQueue = do
  it "should throw error on attempt to update status of nonexistent SndQueue" $ \store -> do
    setSndQueueStatus store sndQueue1 Confirmed
      `throwsError` SEInternal

testCreateRcvMsg :: SpecWith SQLiteStore
testCreateRcvMsg = do
  it "should create a RcvMsg and return InternalId" $ \store -> do
    createRcvConn store rcvQueue1
      `returnsResult` ()
    -- TODO getMsg to check message
    let ts = UTCTime (fromGregorian 2021 02 24) (secondsToDiffTime 0)
    createRcvMsg store "conn1" (encodeUtf8 "Hello world!") ts 1 ts "1" ts
      `returnsResult` (1 :: InternalId)

testCreateRcvMsgNoQueue :: SpecWith SQLiteStore
testCreateRcvMsgNoQueue = do
  it "should throw error on attempt to create a RcvMsg w/t a RcvQueue" $ \store -> do
    let ts = UTCTime (fromGregorian 2021 02 24) (secondsToDiffTime 0)
    createRcvMsg store "conn1" (encodeUtf8 "Hello world!") ts 1 ts "1" ts
      `throwsError` SEBadConn
    createSndConn store sndQueue1
      `returnsResult` ()
    createRcvMsg store "conn1" (encodeUtf8 "Hello world!") ts 1 ts "1" ts
      `throwsError` SEBadConnType CSnd

testCreateSndMsg :: SpecWith SQLiteStore
testCreateSndMsg = do
  it "should create a SndMsg" $ \store -> do
    createSndConn store sndQueue1
      `returnsResult` ()
    -- TODO getMsg to check message
    let ts = UTCTime (fromGregorian 2021 02 24) (secondsToDiffTime 0)
    createSndMsg store "conn1" (encodeUtf8 "Hello world!") ts
      `returnsResult` (1 :: InternalId)

testCreateSndMsgNoQueue :: SpecWith SQLiteStore
testCreateSndMsgNoQueue = do
  it "should throw error on attempt to create a SndMsg w/t a SndQueue" $ \store -> do
    let ts = UTCTime (fromGregorian 2021 02 24) (secondsToDiffTime 0)
    createSndMsg store "conn1" (encodeUtf8 "Hello world!") ts
      `throwsError` SEBadConn
    createRcvConn store rcvQueue1
      `returnsResult` ()
    createSndMsg store "conn1" (encodeUtf8 "Hello world!") ts
      `throwsError` SEBadConnType CRcv
