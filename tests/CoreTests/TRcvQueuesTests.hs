{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module CoreTests.TRcvQueuesTests where

import Data.Foldable (toList)
import Simplex.Messaging.Agent.Protocol (ConnId, QueueStatus (..), UserId)
import Simplex.Messaging.Agent.Store (DBQueueId (..), RcvQueue, StoredRcvQueue (..))
import qualified Simplex.Messaging.Agent.TRcvQueues as RQ
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (SMPServer)
import Test.Hspec
import UnliftIO

tRcvQueuesTests :: Spec
tRcvQueuesTests = do
  describe "connection API" $ do
    it "hasConn" hasConnTest
    it "deleteConn" deleteConnTest
  describe "session API" $ do
    it "getSessQueues" getSessQueuesTest
    it "getDelSessQueues" getDelSessQueuesTest

hasConnTest :: IO ()
hasConnTest = do
  trq <- atomically RQ.empty
  atomically $ do
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c1") trq
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c2") trq
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@beta" "c3") trq
  atomically (RQ.hasConn "c1" trq) `shouldReturn` True
  atomically (RQ.hasConn "c2" trq) `shouldReturn` True
  atomically (RQ.hasConn "c3" trq) `shouldReturn` True
  atomically (RQ.hasConn "nope" trq) `shouldReturn` False

deleteConnTest :: IO ()
deleteConnTest = do
  trq <- atomically RQ.empty
  atomically $ do
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c1") trq
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c2") trq
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@beta" "c3") trq
    RQ.deleteConn "c1" trq
    RQ.deleteConn "nope" trq
  atomically (toList <$> RQ.getConns trq) `shouldReturn` ["c2", "c3"]

getSessQueuesTest :: IO ()
getSessQueuesTest = do
  trq <- atomically RQ.empty
  atomically $ do
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c1") trq
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c2") trq
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@beta" "c3") trq
    RQ.addQueue (dummyRQ 1 "smp://1234-w==@beta" "c4") trq
  atomically (RQ.getSessQueues (0, "smp://1234-w==@alpha", Just "c1") trq) `shouldReturn` [dummyRQ 0 "smp://1234-w==@alpha" "c1"]
  atomically (RQ.getSessQueues (1, "smp://1234-w==@alpha", Just "c1") trq) `shouldReturn` []
  atomically (RQ.getSessQueues (0, "smp://1234-w==@alpha", Just "nope") trq) `shouldReturn` []
  atomically (RQ.getSessQueues (0, "smp://1234-w==@alpha", Nothing) trq) `shouldReturn` [dummyRQ 0 "smp://1234-w==@alpha" "c2", dummyRQ 0 "smp://1234-w==@alpha" "c1"]

getDelSessQueuesTest :: IO ()
getDelSessQueuesTest = do
  trq <- atomically RQ.empty
  atomically $ do
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c1") trq
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c2") trq
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@beta" "c3") trq
    RQ.addQueue (dummyRQ 1 "smp://1234-w==@beta" "c4") trq
  -- no user
  atomically (RQ.getDelSessQueues (2, "smp://1234-w==@alpha", Nothing) trq) `shouldReturn` []
  -- wrong user
  atomically (RQ.getDelSessQueues (1, "smp://1234-w==@alpha", Nothing) trq) `shouldReturn` []
  -- connections intact
  atomically (RQ.hasConn "c1" trq) `shouldReturn` True
  atomically (RQ.hasConn "c2" trq) `shouldReturn` True
  atomically (RQ.getDelSessQueues (0, "smp://1234-w==@alpha", Nothing) trq) `shouldReturn` [dummyRQ 0 "smp://1234-w==@alpha" "c2", dummyRQ 0 "smp://1234-w==@alpha" "c1"]
  -- connections gone
  atomically (RQ.hasConn "c1" trq) `shouldReturn` False
  atomically (RQ.hasConn "c2" trq) `shouldReturn` False
  -- non-matched connections intact
  atomically (RQ.hasConn "c3" trq) `shouldReturn` True
  atomically (RQ.hasConn "c4" trq) `shouldReturn` True

dummyRQ :: UserId -> SMPServer -> ConnId -> RcvQueue
dummyRQ userId server connId =
  RcvQueue
    { userId,
      connId,
      server,
      rcvId = "",
      rcvPrivateKey = C.APrivateSignKey C.SEd25519 "MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe",
      rcvDhSecret = "01234567890123456789012345678901",
      e2ePrivKey = "MC4CAQAwBQYDK2VuBCIEINCzbVFaCiYHoYncxNY8tSIfn0pXcIAhLBfFc0m+gOpk",
      e2eDhSecret = Nothing,
      sndId = "",
      status = New,
      dbQueueId = DBQueueId 0,
      primary = True,
      dbReplaceQueueId = Nothing,
      rcvSwchStatus = Nothing,
      smpClientVersion = 123,
      clientNtfCreds = Nothing,
      deleteErrors = 0
    }
