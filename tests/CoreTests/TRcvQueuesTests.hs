{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}

module CoreTests.TRcvQueuesTests where

import AgentTests.EqInstances ()
import qualified Data.List.NonEmpty as L
import qualified Data.Map as M
import qualified Data.Set as S
import Simplex.Messaging.Agent.Protocol (ConnId, QueueStatus (..), UserId)
import Simplex.Messaging.Agent.Store (DBQueueId (..), RcvQueue, StoredRcvQueue (..))
import qualified Simplex.Messaging.Agent.TRcvQueues as RQ
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (SMPServer, pattern VersionSMPC)
import Test.Hspec
import UnliftIO
import Simplex.Messaging.Util (atomically')

tRcvQueuesTests :: Spec
tRcvQueuesTests = do
  describe "connection API" $ do
    it "hasConn" hasConnTest
    it "hasConn, batch add" hasConnTestBatch
    it "deleteConn" deleteConnTest
  describe "session API" $ do
    it "getSessQueues" getSessQueuesTest
    it "getDelSessQueues" getDelSessQueuesTest

checkDataInvariant :: RQ.TRcvQueues -> IO Bool
checkDataInvariant trq = atomically' $ do
  conns <- readTVar $ RQ.getConnections trq
  qs <- readTVar $ RQ.getRcvQueues trq
  -- three invariant checks
  let inv1 = all (\cId -> (S.fromList . L.toList <$> M.lookup cId conns) == Just (M.keysSet (M.filter (\q -> connId q == cId) qs))) (M.keys conns)
      inv2 = all (\(k, q) -> maybe False ((k `elem`) . L.toList) (M.lookup (connId q) conns)) (M.assocs qs)
      inv3 = all (\(k, q) -> RQ.qKey q == k) (M.assocs qs)
  pure $ inv1 && inv2 && inv3

hasConnTest :: IO ()
hasConnTest = do
  trq <- atomically' RQ.empty
  atomically' $ RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c1") trq
  checkDataInvariant trq `shouldReturn` True
  atomically' $ RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c2") trq
  checkDataInvariant trq `shouldReturn` True
  atomically' $ RQ.addQueue (dummyRQ 0 "smp://1234-w==@beta" "c3") trq
  checkDataInvariant trq `shouldReturn` True
  atomically' (RQ.hasConn "c1" trq) `shouldReturn` True
  atomically' (RQ.hasConn "c2" trq) `shouldReturn` True
  atomically' (RQ.hasConn "c3" trq) `shouldReturn` True
  atomically' (RQ.hasConn "nope" trq) `shouldReturn` False

hasConnTestBatch :: IO ()
hasConnTestBatch = do
  trq <- atomically' RQ.empty
  let qs = [dummyRQ 0 "smp://1234-w==@alpha" "c1", dummyRQ 0 "smp://1234-w==@alpha" "c2", dummyRQ 0 "smp://1234-w==@beta" "c3"]
  atomically' $ RQ.batchAddQueues trq qs
  checkDataInvariant trq `shouldReturn` True
  atomically' (RQ.hasConn "c1" trq) `shouldReturn` True
  atomically' (RQ.hasConn "c2" trq) `shouldReturn` True
  atomically' (RQ.hasConn "c3" trq) `shouldReturn` True
  atomically' (RQ.hasConn "nope" trq) `shouldReturn` False

deleteConnTest :: IO ()
deleteConnTest = do
  trq <- atomically' RQ.empty
  atomically' $ do
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c1") trq
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c2") trq
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@beta" "c3") trq
  checkDataInvariant trq `shouldReturn` True
  atomically' $ RQ.deleteConn "c1" trq
  checkDataInvariant trq `shouldReturn` True
  atomically' $ RQ.deleteConn "nope" trq
  checkDataInvariant trq `shouldReturn` True
  M.keys <$> readTVarIO (RQ.getConnections trq) `shouldReturn` ["c2", "c3"]

getSessQueuesTest :: IO ()
getSessQueuesTest = do
  trq <- atomically' RQ.empty
  atomically' $ RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c1") trq
  checkDataInvariant trq `shouldReturn` True
  atomically' $ RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c2") trq
  checkDataInvariant trq `shouldReturn` True
  atomically' $ RQ.addQueue (dummyRQ 0 "smp://1234-w==@beta" "c3") trq
  checkDataInvariant trq `shouldReturn` True
  atomically' $ RQ.addQueue (dummyRQ 1 "smp://1234-w==@beta" "c4") trq
  checkDataInvariant trq `shouldReturn` True
  atomically' (RQ.getSessQueues (0, "smp://1234-w==@alpha", Just "c1") trq) `shouldReturn` [dummyRQ 0 "smp://1234-w==@alpha" "c1"]
  atomically' (RQ.getSessQueues (1, "smp://1234-w==@alpha", Just "c1") trq) `shouldReturn` []
  atomically' (RQ.getSessQueues (0, "smp://1234-w==@alpha", Just "nope") trq) `shouldReturn` []
  atomically' (RQ.getSessQueues (0, "smp://1234-w==@alpha", Nothing) trq) `shouldReturn` [dummyRQ 0 "smp://1234-w==@alpha" "c2", dummyRQ 0 "smp://1234-w==@alpha" "c1"]

getDelSessQueuesTest :: IO ()
getDelSessQueuesTest = do
  trq <- atomically' RQ.empty
  let qs =
        [ dummyRQ 0 "smp://1234-w==@alpha" "c1",
          dummyRQ 0 "smp://1234-w==@alpha" "c2",
          dummyRQ 0 "smp://1234-w==@beta" "c3",
          dummyRQ 1 "smp://1234-w==@beta" "c4"
        ]
  atomically' $ RQ.batchAddQueues trq qs
  checkDataInvariant trq `shouldReturn` True
  -- no user
  atomically' (RQ.getDelSessQueues (2, "smp://1234-w==@alpha", Nothing) trq) `shouldReturn` ([], [])
  checkDataInvariant trq `shouldReturn` True
  -- wrong user
  atomically' (RQ.getDelSessQueues (1, "smp://1234-w==@alpha", Nothing) trq) `shouldReturn` ([], [])
  checkDataInvariant trq `shouldReturn` True
  -- connections intact
  atomically' (RQ.hasConn "c1" trq) `shouldReturn` True
  atomically' (RQ.hasConn "c2" trq) `shouldReturn` True
  atomically' (RQ.getDelSessQueues (0, "smp://1234-w==@alpha", Nothing) trq) `shouldReturn` ([dummyRQ 0 "smp://1234-w==@alpha" "c2", dummyRQ 0 "smp://1234-w==@alpha" "c1"], ["c1", "c2"])
  checkDataInvariant trq `shouldReturn` True
  -- connections gone
  atomically' (RQ.hasConn "c1" trq) `shouldReturn` False
  atomically' (RQ.hasConn "c2" trq) `shouldReturn` False
  -- non-matched connections intact
  atomically' (RQ.hasConn "c3" trq) `shouldReturn` True
  atomically' (RQ.hasConn "c4" trq) `shouldReturn` True

dummyRQ :: UserId -> SMPServer -> ConnId -> RcvQueue
dummyRQ userId server connId =
  RcvQueue
    { userId,
      connId,
      server,
      rcvId = "",
      rcvPrivateKey = C.APrivateAuthKey C.SEd25519 "MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe",
      rcvDhSecret = "01234567890123456789012345678901",
      e2ePrivKey = "MC4CAQAwBQYDK2VuBCIEINCzbVFaCiYHoYncxNY8tSIfn0pXcIAhLBfFc0m+gOpk",
      e2eDhSecret = Nothing,
      sndId = "",
      status = New,
      dbQueueId = DBQueueId 0,
      primary = True,
      dbReplaceQueueId = Nothing,
      rcvSwchStatus = Nothing,
      smpClientVersion = VersionSMPC 123,
      clientNtfCreds = Nothing,
      deleteErrors = 0
    }
