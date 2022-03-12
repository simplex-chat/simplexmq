{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}

module AgentTests.PostgresTests (postgresStoreTests) where

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
import Database.PostgreSQL.Simple (ConnectInfo (..), defaultConnectInfo)
import qualified Database.PostgreSQL.Simple as DB
import SMPClient (testKeyHash)
import Simplex.Messaging.Agent.Client ()
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.Postgres
import qualified Simplex.Messaging.Agent.Store.Postgres.Migrations as Migrations
import qualified Simplex.Messaging.Crypto as C
import System.Random
import Test.Hspec
import UnliftIO.Directory (removeFile)

withStore :: SpecWith PostgresStore -> Spec
withStore = before createStore

createStore :: IO PostgresStore
createStore = do
  let dbConnInfo = defaultConnectInfo {connectDatabase = "agent_poc_1"}
  createPostgresStore dbConnInfo 1 Migrations.app

returnsResult :: (Eq a, Eq e, Show a, Show e) => ExceptT e IO a -> a -> Expectation
action `returnsResult` r = runExceptT action `shouldReturn` Right r

throwsError :: (Eq a, Eq e, Show a, Show e) => ExceptT e IO a -> e -> Expectation
action `throwsError` e = runExceptT action `shouldReturn` Left e

-- TODO add null port tests
postgresStoreTests :: Spec
postgresStoreTests = do
  -- withStore2 $ do
  --   describe "stress test" testConcurrentWrites
  withStore $ do
    -- describe "store setup" $ do
    --   testCompiledThreadsafe
    --   testForeignKeysEnabled
    describe "store methods" $ do
      describe "Queue and Connection management" $ do
        -- describe "createRcvConn" $ do
        --   testCreateRcvConn
        --   testCreateRcvConnRandomId
        --   testCreateRcvConnDuplicate
        fdescribe "createSndConn" $ do
          testCreateSndConn

--     testCreateSndConnRandomID
--     testCreateSndConnDuplicate
--   describe "getRcvConn" testGetRcvConn
--   describe "deleteConn" $ do
--     testDeleteRcvConn
--     testDeleteSndConn
--     testDeleteDuplexConn
--   describe "upgradeRcvConnToDuplex" $ do
--     testUpgradeRcvConnToDuplex
--   describe "upgradeSndConnToDuplex" $ do
--     testUpgradeSndConnToDuplex
--   describe "set Queue status" $ do
--     describe "setRcvQueueStatus" $ do
--       testSetRcvQueueStatus
--     describe "setSndQueueStatus" $ do
--       testSetSndQueueStatus
--     testSetQueueStatusDuplex
-- describe "Msg management" $ do
--   describe "create Msg" $ do
--     testCreateRcvMsg
--     testCreateSndMsg
--     testCreateRcvAndSndMsgs

cData1 :: ConnData
cData1 = ConnData {connId = "conn1"}

testPrivateSignKey :: C.APrivateSignKey
testPrivateSignKey = C.APrivateSignKey C.SEd25519 "MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe"

testPrivDhKey :: C.PrivateKeyX25519
testPrivDhKey = "MC4CAQAwBQYDK2VuBCIEINCzbVFaCiYHoYncxNY8tSIfn0pXcIAhLBfFc0m+gOpk"

testDhSecret :: C.DhSecretX25519
testDhSecret = "01234567890123456789012345678901"

rcvQueue1 :: RcvQueue
rcvQueue1 =
  RcvQueue
    { server = SMPServer "smp.simplex.im" "5223" testKeyHash,
      rcvId = "1234",
      rcvPrivateKey = testPrivateSignKey,
      rcvDhSecret = testDhSecret,
      e2ePrivKey = testPrivDhKey,
      e2eDhSecret = Nothing,
      sndId = Just "2345",
      status = New
    }

sndQueue1 :: SndQueue
sndQueue1 =
  SndQueue
    { server = SMPServer "smp.simplex.im" "5223" testKeyHash,
      sndId = "3456",
      sndPrivateKey = testPrivateSignKey,
      e2eDhSecret = testDhSecret,
      status = New
    }

testCreateSndConn :: SpecWith PostgresStore
testCreateSndConn =
  it "should create SndConnection and add RcvQueue" $ \store -> do
    g <- newTVarIO =<< drgNew
    createSndConn store g cData1 sndQueue1
      `returnsResult` "conn1"
    getConn store "conn1"
      `returnsResult` SomeConn SCSnd (SndConnection cData1 sndQueue1)

-- upgradeSndConnToDuplex store "conn1" rcvQueue1
--   `returnsResult` ()
-- getConn store "conn1"
--   `returnsResult` SomeConn SCDuplex (DuplexConnection cData1 rcvQueue1 sndQueue1)
