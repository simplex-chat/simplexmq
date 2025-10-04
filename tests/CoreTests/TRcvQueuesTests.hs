{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module CoreTests.TRcvQueuesTests where

import AgentTests.EqInstances ()
import qualified Data.ByteString.Char8 as B
import qualified Data.Map as M
import qualified Data.Set as S
import Data.String (IsString (..))
import Simplex.Messaging.Agent.Protocol (ConnId, QueueStatus (..), UserId)
import Simplex.Messaging.Agent.Store (RcvQueueSub (..))
import qualified Simplex.Messaging.Agent.TRcvQueues as RQ
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (EntityId (..), RecipientId, SMPServer)
import Simplex.Messaging.Transport (SessionId)
import Test.Hspec hiding (fit, it)
import UnliftIO
import Util

tRcvQueuesTests :: Spec
tRcvQueuesTests = do
  describe "connection API" $ do
    it "hasConn" hasConnTest
    it "hasConn, batch add" hasConnTestBatch
    it "hasConn, batch idempotent" batchIdempotentTest
    it "deleteQueue" deleteQueueTest
  describe "session API" $ do
    it "getSessQueues" getSessQueuesTest
    it "getDelSessQueues" getDelSessQueuesTest
  describe "queue transfer" $ do
    it "getDelSessQueues-batchAddQueues preserves total length" removeSubsTest

instance IsString EntityId where fromString = EntityId . B.pack

checkDataInvariant' :: RQ.TRcvQueues (SessionId, RcvQueueSub) -> IO Bool
checkDataInvariant' = checkDataInvariant_ snd

checkDataInvariant :: RQ.TRcvQueues RcvQueueSub -> IO Bool
checkDataInvariant = checkDataInvariant_ id

checkDataInvariant_ :: (q -> RcvQueueSub) -> RQ.TRcvQueues q -> IO Bool
checkDataInvariant_ toRQ trq = atomically $ do
  qs <- readTVar $ RQ.getRcvQueues trq
  let inv3 = all (\(k, q) -> RQ.qKey (toRQ q) == k) (M.assocs qs)
  pure inv3

hasConnTest :: IO ()
hasConnTest = do
  trq <- RQ.empty
  let q1 = dummyRQ 0 "smp://1234-w==@alpha" "c1" "r1"
      q2 = dummyRQ 0 "smp://1234-w==@alpha" "c2" "r2"
      q3 = dummyRQ 0 "smp://1234-w==@beta" "c3" "r3"
  atomically $ RQ.addQueue q1 trq
  checkDataInvariant trq `shouldReturn` True
  atomically $ RQ.addQueue q2 trq
  checkDataInvariant trq `shouldReturn` True
  atomically $ RQ.addQueue q3 trq
  checkDataInvariant trq `shouldReturn` True
  atomically (RQ.hasQueue q1 trq) `shouldReturn` True
  atomically (RQ.hasQueue q2 trq) `shouldReturn` True
  atomically (RQ.hasQueue q3 trq) `shouldReturn` True
  atomically (RQ.hasQueue (dummyRQ 0 "smp://1234-w==@alpha" "c4" "nope") trq) `shouldReturn` False

hasConnTestBatch :: IO ()
hasConnTestBatch = do
  trq <- RQ.empty
  let q1 = dummyRQ 0 "smp://1234-w==@alpha" "c1" "r1"
      q2 = dummyRQ 0 "smp://1234-w==@alpha" "c2" "r2"
      q3 = dummyRQ 0 "smp://1234-w==@beta" "c3" "r3"
  let qs = [q1, q2, q3]
  atomically $ RQ.batchAddQueues qs trq
  checkDataInvariant trq `shouldReturn` True
  atomically (RQ.hasQueue q1 trq) `shouldReturn` True
  atomically (RQ.hasQueue q2 trq) `shouldReturn` True
  atomically (RQ.hasQueue q3 trq) `shouldReturn` True
  atomically (RQ.hasQueue (dummyRQ 0 "smp://1234-w==@alpha" "c4" "nope") trq) `shouldReturn` False

batchIdempotentTest :: IO ()
batchIdempotentTest = do
  trq <- RQ.empty
  let qs = [dummyRQ 0 "smp://1234-w==@alpha" "c1" "r1", dummyRQ 0 "smp://1234-w==@alpha" "c2" "r2", dummyRQ 0 "smp://1234-w==@beta" "c3" "r3"]
  atomically $ RQ.batchAddQueues qs trq
  checkDataInvariant trq `shouldReturn` True
  qs' <- readTVarIO $ RQ.getRcvQueues trq
  atomically $ RQ.batchAddQueues qs trq
  checkDataInvariant trq `shouldReturn` True
  readTVarIO (RQ.getRcvQueues trq) `shouldReturn` qs'

deleteQueueTest :: IO ()
deleteQueueTest = do
  trq <- RQ.empty
  let q1 = dummyRQ 0 "smp://1234-w==@alpha" "c1" "r1"
  atomically $ do
    RQ.addQueue q1 trq
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c2" "r2") trq
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@beta" "c3" "r3") trq
  checkDataInvariant trq `shouldReturn` True
  atomically $ RQ.deleteQueue q1 trq
  checkDataInvariant trq `shouldReturn` True
  atomically $ RQ.deleteQueue (dummyRQ 0 "smp://1234-w==@alpha" "c4" "nope") trq
  checkDataInvariant trq `shouldReturn` True

getSessQueuesTest :: IO ()
getSessQueuesTest = do
  trq <- RQ.empty
  atomically $ RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c1" "r1") trq
  checkDataInvariant trq `shouldReturn` True
  atomically $ RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c2" "r2") trq
  checkDataInvariant trq `shouldReturn` True
  atomically $ RQ.addQueue (dummyRQ 0 "smp://1234-w==@beta" "c3" "r3") trq
  checkDataInvariant trq `shouldReturn` True
  atomically $ RQ.addQueue (dummyRQ 1 "smp://1234-w==@beta" "c4" "r4") trq
  checkDataInvariant trq `shouldReturn` True
  let tSess1 = (0, "smp://1234-w==@alpha", Just "c1")
  RQ.getSessQueues tSess1 trq `shouldReturn` [dummyRQ 0 "smp://1234-w==@alpha" "c1" "r1"]
  atomically (RQ.hasSessQueues tSess1 trq) `shouldReturn` True
  let tSess2 = (1, "smp://1234-w==@alpha", Just "c1")
  RQ.getSessQueues tSess2 trq `shouldReturn` []
  atomically (RQ.hasSessQueues tSess2 trq) `shouldReturn` False
  let tSess3 = (0, "smp://1234-w==@alpha", Just "nope")
  RQ.getSessQueues tSess3 trq `shouldReturn` []
  atomically (RQ.hasSessQueues tSess3 trq) `shouldReturn` False
  let tSess4 = (0, "smp://1234-w==@alpha", Nothing)
  RQ.getSessQueues tSess4 trq `shouldReturn` [dummyRQ 0 "smp://1234-w==@alpha" "c2" "r2", dummyRQ 0 "smp://1234-w==@alpha" "c1" "r1"]
  atomically (RQ.hasSessQueues tSess4 trq) `shouldReturn` True

getDelSessQueuesTest :: IO ()
getDelSessQueuesTest = do
  trq <- RQ.empty
  let q1 = dummyRQ 0 "smp://1234-w==@alpha" "c1" "r1"
      q2 = dummyRQ 0 "smp://1234-w==@alpha" "c2" "r2"
      q3 = dummyRQ 0 "smp://1234-w==@beta" "c3" "r3"
      q4 = dummyRQ 1 "smp://1234-w==@beta" "c4" "r4"
      qs =
        [ ("1", q1),
          ("1", q2),
          ("1", q3),
          ("1", q4)
        ]
  mapM_ (\q -> atomically $ RQ.addSessQueue q trq) qs
  checkDataInvariant' trq `shouldReturn` True
  -- no user
  atomically (RQ.getDelSessQueues (2, "smp://1234-w==@alpha", Nothing) "1" trq) `shouldReturn` ([], [])
  checkDataInvariant' trq `shouldReturn` True
  -- wrong user
  atomically (RQ.getDelSessQueues (1, "smp://1234-w==@alpha", Nothing) "1" trq) `shouldReturn` ([], [])
  checkDataInvariant' trq `shouldReturn` True
  -- connections intact
  atomically (RQ.hasQueue q1 trq) `shouldReturn` True
  atomically (RQ.hasQueue q2 trq) `shouldReturn` True
  atomically (RQ.getDelSessQueues (0, "smp://1234-w==@alpha", Nothing) "1" trq) `shouldReturn` ([dummyRQ 0 "smp://1234-w==@alpha" "c2" "r2", dummyRQ 0 "smp://1234-w==@alpha" "c1" "r1"], ["c1", "c2"])
  checkDataInvariant' trq `shouldReturn` True
  -- connections gone
  atomically (RQ.hasQueue q1 trq) `shouldReturn` False
  atomically (RQ.hasQueue q2 trq) `shouldReturn` False
  -- non-matched connections intact
  atomically (RQ.hasQueue q3 trq) `shouldReturn` True
  atomically (RQ.hasQueue q4 trq) `shouldReturn` True
  RQ.getSessConns (0, "smp://1234-w==@alpha", Nothing) trq `shouldReturn` S.fromList []
  RQ.getSessConns (0, "smp://1234-w==@beta", Nothing) trq `shouldReturn` S.fromList ["c3"]
  RQ.getSessConns (1, "smp://1234-w==@beta", Nothing) trq `shouldReturn` S.fromList ["c4"]

removeSubsTest :: IO ()
removeSubsTest = do
  aq <- RQ.empty
  let qs =
        [ ("1", dummyRQ 0 "smp://1234-w==@alpha" "c1" "r1"),
          ("1", dummyRQ 0 "smp://1234-w==@alpha" "c2" "r2"),
          ("1", dummyRQ 0 "smp://1234-w==@beta" "c3" "r3"),
          ("1", dummyRQ 1 "smp://1234-w==@beta" "c4" "r4")
        ]
  mapM_ (\q -> atomically $ RQ.addSessQueue q aq) qs

  pq <- RQ.empty
  atomically (totalSize aq pq) `shouldReturn` 4

  atomically $ RQ.getDelSessQueues (0, "smp://1234-w==@alpha", Nothing) "1" aq >>= (`RQ.batchAddQueues` pq) . fst
  atomically (totalSize aq pq) `shouldReturn` 4

  atomically $ RQ.getDelSessQueues (0, "smp://1234-w==@beta", Just "non-existent") "1" aq >>= (`RQ.batchAddQueues` pq) . fst
  atomically (totalSize aq pq) `shouldReturn` 4

  atomically $ RQ.getDelSessQueues (0, "smp://1234-w==@localhost", Nothing) "1" aq >>= (`RQ.batchAddQueues` pq) . fst
  atomically (totalSize aq pq) `shouldReturn` 4

  atomically $ RQ.getDelSessQueues (0, "smp://1234-w==@beta", Just "c3") "1" aq >>= (`RQ.batchAddQueues` pq) . fst
  atomically (totalSize aq pq) `shouldReturn` 4

totalSize :: RQ.TRcvQueues q -> RQ.TRcvQueues q' -> STM Int
totalSize a b = do
  qsizeA <- M.size <$> readTVar (RQ.getRcvQueues a)
  qsizeB <- M.size <$> readTVar (RQ.getRcvQueues b)
  pure $ qsizeA + qsizeB

dummyRQ :: UserId -> SMPServer -> ConnId -> RecipientId -> RcvQueueSub
dummyRQ userId server connId rcvId =
  RcvQueueSub
    { userId,
      connId,
      server,
      rcvId,
      rcvPrivateKey = C.APrivateAuthKey C.SEd25519 "MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe",
      status = New,
      dbQueueId = 0,
      primary = True,
      dbReplaceQueueId = Nothing
    }
