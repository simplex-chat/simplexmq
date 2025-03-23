{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module CoreTests.TRcvQueuesTests where

import AgentTests.EqInstances ()
import qualified Data.ByteString.Char8 as B
import qualified Data.List.NonEmpty as L
import qualified Data.Map as M
import qualified Data.Set as S
import Data.String (IsString (..))
import Simplex.Messaging.Agent.Protocol (ConnId, QueueStatus (..), UserId)
import Simplex.Messaging.Agent.Store (DBQueueId (..), RcvQueue, StoredRcvQueue (..))
import qualified Simplex.Messaging.Agent.TRcvQueues as RQ
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (EntityId (..), RecipientId, SMPServer, pattern NoEntity, pattern VersionSMPC)
import Test.Hspec
import UnliftIO

tRcvQueuesTests :: Spec
tRcvQueuesTests = do
  describe "connection API" $ do
    it "hasConn" hasConnTest
    it "hasConn, batch add" hasConnTestBatch
    it "hasConn, batch idempotent" batchIdempotentTest
    it "deleteConn" deleteConnTest
  describe "session API" $ do
    it "getSessQueues" getSessQueuesTest
    it "getDelSessQueues" getDelSessQueuesTest
  describe "queue transfer" $ do
    it "getDelSessQueues-batchAddQueues preserves total length" removeSubsTest

instance IsString EntityId where fromString = EntityId . B.pack

checkDataInvariant :: RQ.Queue q => RQ.TRcvQueues q -> IO Bool
checkDataInvariant trq = atomically $ do
  conns <- readTVar $ RQ.getConnections trq
  qs <- readTVar $ RQ.getRcvQueues trq
  -- three invariant checks
  let inv1 = all (\cId -> (S.fromList . L.toList <$> M.lookup cId conns) == Just (M.keysSet (M.filter (\q -> RQ.connId' q == cId) qs))) (M.keys conns)
      inv2 = all (\(k, q) -> maybe False ((k `elem`) . L.toList) (M.lookup (RQ.connId' q) conns)) (M.assocs qs)
      inv3 = all (\(k, q) -> RQ.qKey q == k) (M.assocs qs)
  pure $ inv1 && inv2 && inv3

hasConnTest :: IO ()
hasConnTest = do
  trq <- RQ.empty
  atomically $ RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c1" "r1") trq
  checkDataInvariant trq `shouldReturn` True
  atomically $ RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c2" "r2") trq
  checkDataInvariant trq `shouldReturn` True
  atomically $ RQ.addQueue (dummyRQ 0 "smp://1234-w==@beta" "c3" "r3") trq
  checkDataInvariant trq `shouldReturn` True
  atomically (RQ.hasConn "c1" trq) `shouldReturn` True
  atomically (RQ.hasConn "c2" trq) `shouldReturn` True
  atomically (RQ.hasConn "c3" trq) `shouldReturn` True
  atomically (RQ.hasConn "nope" trq) `shouldReturn` False

hasConnTestBatch :: IO ()
hasConnTestBatch = do
  trq <- RQ.empty
  let qs = [dummyRQ 0 "smp://1234-w==@alpha" "c1" "r1", dummyRQ 0 "smp://1234-w==@alpha" "c2" "r2", dummyRQ 0 "smp://1234-w==@beta" "c3" "r3"]
  atomically $ RQ.batchAddQueues trq qs
  checkDataInvariant trq `shouldReturn` True
  atomically (RQ.hasConn "c1" trq) `shouldReturn` True
  atomically (RQ.hasConn "c2" trq) `shouldReturn` True
  atomically (RQ.hasConn "c3" trq) `shouldReturn` True
  atomically (RQ.hasConn "nope" trq) `shouldReturn` False

batchIdempotentTest :: IO ()
batchIdempotentTest = do
  trq <- RQ.empty
  let qs = [dummyRQ 0 "smp://1234-w==@alpha" "c1" "r1", dummyRQ 0 "smp://1234-w==@alpha" "c2" "r2", dummyRQ 0 "smp://1234-w==@beta" "c3" "r3"]
  atomically $ RQ.batchAddQueues trq qs
  checkDataInvariant trq `shouldReturn` True
  qs' <- readTVarIO $ RQ.getRcvQueues trq
  cs' <- readTVarIO $ RQ.getConnections trq
  atomically $ RQ.batchAddQueues trq qs
  checkDataInvariant trq `shouldReturn` True
  readTVarIO (RQ.getRcvQueues trq) `shouldReturn` qs'
  fmap L.nub <$> readTVarIO (RQ.getConnections trq) `shouldReturn` cs' -- connections get duplicated, but that doesn't appear to affect anybody

deleteConnTest :: IO ()
deleteConnTest = do
  trq <- RQ.empty
  atomically $ do
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c1" "r1") trq
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@alpha" "c2" "r2") trq
    RQ.addQueue (dummyRQ 0 "smp://1234-w==@beta" "c3" "r3") trq
  checkDataInvariant trq `shouldReturn` True
  atomically $ RQ.deleteConn "c1" trq
  checkDataInvariant trq `shouldReturn` True
  atomically $ RQ.deleteConn "nope" trq
  checkDataInvariant trq `shouldReturn` True
  M.keys <$> readTVarIO (RQ.getConnections trq) `shouldReturn` ["c2", "c3"]

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
  atomically (RQ.hasSessQueues tSess4 trq) `shouldReturn`True

getDelSessQueuesTest :: IO ()
getDelSessQueuesTest = do
  trq <- RQ.empty
  let qs =
        [ ("1", dummyRQ 0 "smp://1234-w==@alpha" "c1" "r1"),
          ("1", dummyRQ 0 "smp://1234-w==@alpha" "c2" "r2"),
          ("1", dummyRQ 0 "smp://1234-w==@beta" "c3" "r3"),
          ("1", dummyRQ 1 "smp://1234-w==@beta" "c4" "r4")
        ]
  atomically $ RQ.batchAddQueues trq qs
  checkDataInvariant trq `shouldReturn` True
  -- no user
  atomically (RQ.getDelSessQueues (2, "smp://1234-w==@alpha", Nothing) "1" trq) `shouldReturn` ([], [])
  checkDataInvariant trq `shouldReturn` True
  -- wrong user
  atomically (RQ.getDelSessQueues (1, "smp://1234-w==@alpha", Nothing) "1" trq) `shouldReturn` ([], [])
  checkDataInvariant trq `shouldReturn` True
  -- connections intact
  atomically (RQ.hasConn "c1" trq) `shouldReturn` True
  atomically (RQ.hasConn "c2" trq) `shouldReturn` True
  atomically (RQ.getDelSessQueues (0, "smp://1234-w==@alpha", Nothing) "1" trq) `shouldReturn` ([dummyRQ 0 "smp://1234-w==@alpha" "c2" "r2", dummyRQ 0 "smp://1234-w==@alpha" "c1" "r1"], ["c1", "c2"])
  checkDataInvariant trq `shouldReturn` True
  -- connections gone
  atomically (RQ.hasConn "c1" trq) `shouldReturn` False
  atomically (RQ.hasConn "c2" trq) `shouldReturn` False
  -- non-matched connections intact
  atomically (RQ.hasConn "c3" trq) `shouldReturn` True
  atomically (RQ.hasConn "c4" trq) `shouldReturn` True

removeSubsTest :: IO ()
removeSubsTest = do
  aq <- RQ.empty
  let qs =
        [ ("1", dummyRQ 0 "smp://1234-w==@alpha" "c1" "r1"),
          ("1", dummyRQ 0 "smp://1234-w==@alpha" "c2" "r2"),
          ("1", dummyRQ 0 "smp://1234-w==@beta" "c3" "r3"),
          ("1", dummyRQ 1 "smp://1234-w==@beta" "c4" "r4")
        ]
  atomically $ RQ.batchAddQueues aq qs

  pq <- RQ.empty
  atomically (totalSize aq pq) `shouldReturn` (4, 4)

  atomically $ RQ.getDelSessQueues (0, "smp://1234-w==@alpha", Nothing) "1" aq >>= RQ.batchAddQueues pq . map ("1",) . fst
  atomically (totalSize aq pq) `shouldReturn` (4, 4)

  atomically $ RQ.getDelSessQueues (0, "smp://1234-w==@beta", Just "non-existent") "1" aq >>= RQ.batchAddQueues pq . map ("1",) . fst
  atomically (totalSize aq pq) `shouldReturn` (4, 4)

  atomically $ RQ.getDelSessQueues (0, "smp://1234-w==@localhost", Nothing) "1" aq >>= RQ.batchAddQueues pq . map ("1",) . fst
  atomically (totalSize aq pq) `shouldReturn` (4, 4)

  atomically $ RQ.getDelSessQueues (0, "smp://1234-w==@beta", Just "c3") "1" aq >>= RQ.batchAddQueues pq . map ("1",) . fst
  atomically (totalSize aq pq) `shouldReturn` (4, 4)

totalSize :: RQ.TRcvQueues q -> RQ.TRcvQueues q -> STM (Int, Int)
totalSize a b = do
  qsizeA <- M.size <$> readTVar (RQ.getRcvQueues a)
  qsizeB <- M.size <$> readTVar (RQ.getRcvQueues b)
  csizeA <- M.size <$> readTVar (RQ.getConnections a)
  csizeB <- M.size <$> readTVar (RQ.getConnections b)
  pure (qsizeA + qsizeB, csizeA + csizeB)

dummyRQ :: UserId -> SMPServer -> ConnId -> RecipientId -> RcvQueue
dummyRQ userId server connId rcvId =
  RcvQueue
    { userId,
      connId,
      server,
      rcvId,
      rcvPrivateKey = C.APrivateAuthKey C.SEd25519 "MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe",
      rcvDhSecret = "01234567890123456789012345678901",
      e2ePrivKey = "MC4CAQAwBQYDK2VuBCIEINCzbVFaCiYHoYncxNY8tSIfn0pXcIAhLBfFc0m+gOpk",
      e2eDhSecret = Nothing,
      sndId = NoEntity,
      sndSecure = True,
      shortLink = Nothing,
      status = New,
      dbQueueId = DBQueueId 0,
      primary = True,
      dbReplaceQueueId = Nothing,
      rcvSwchStatus = Nothing,
      smpClientVersion = VersionSMPC 123,
      clientNtfCreds = Nothing,
      deleteErrors = 0
    }
