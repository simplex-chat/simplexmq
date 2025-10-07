{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module CoreTests.TSessionSubs where

import AgentTests.EqInstances ()
import Control.Monad
import qualified Data.ByteString.Char8 as B
import Data.List (foldl')
import qualified Data.Map as M
import Data.String (IsString (..))
import Simplex.Messaging.Agent.Protocol (ConnId, QueueStatus (..), UserId)
import Simplex.Messaging.Agent.Store (RcvQueueSub (..))
import qualified Simplex.Messaging.Agent.TSessionSubs as SS
import Simplex.Messaging.Client (SMPTransportSession, TransportSessionMode (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (EntityId (..), RecipientId, SMPServer)
import Simplex.Messaging.Transport (SessionId)
import Test.Hspec hiding (fit, it)
import UnliftIO
import Util

tSessionSubsTests :: Spec
tSessionSubsTests = it "subscription lifecycle" $ testSessionSubs

instance IsString EntityId where fromString = EntityId . B.pack

dumpSessionSubs :: SS.TSessionSubs -> IO (M.Map SMPTransportSession (Maybe SessionId, (M.Map RecipientId RcvQueueSub, M.Map RecipientId RcvQueueSub)))
dumpSessionSubs =
  readTVarIO . SS.sessionSubs
    >=> mapM (\s -> (,) <$> readTVarIO (SS.subsSessId s) <*> SS.mapSubs id s)

srv1 :: SMPServer
srv1 = "smp://1234-w==@alpha"

srv2 :: SMPServer
srv2 = "smp://1234-w==@beta"

testSessionSubs :: IO ()
testSessionSubs = do
  ss <- SS.emptyIO
  ss' <- SS.emptyIO
  let q1 = dummyRQ 1 srv1 "c1" "r1"
      q2 = dummyRQ 1 srv1 "c2" "r2"
      q3 = dummyRQ 1 srv2 "c3" "r3"
      q4 = dummyRQ 1 srv2 "c4" "r4"
      tSess1 = (1, srv1, Nothing)
      tSess2 = (1, srv2, Nothing)
  atomically (SS.addPendingSub tSess1 q1 ss)
  atomically (SS.addPendingSub tSess1 q2 ss)
  atomically (SS.hasPendingSubs tSess1 ss) `shouldReturn` True
  atomically (SS.hasPendingSubs tSess2 ss) `shouldReturn` False
  atomically (SS.addPendingSub tSess2 q3 ss)
  atomically (SS.hasPendingSubs tSess2 ss) `shouldReturn` True
  atomically (SS.batchAddPendingSubs tSess1 [q1, q2] ss')
  atomically (SS.batchAddPendingSubs tSess2 [q3] ss')
  atomically (SS.getPendingSubs tSess1 ss) `shouldReturn` M.fromList [("r1", q1), ("r2", q2)]
  atomically (SS.getActiveSubs tSess1 ss) `shouldReturn` M.fromList []
  atomically (SS.getPendingSubs tSess2 ss) `shouldReturn` M.fromList [("r3", q3)]
  st <- dumpSessionSubs ss
  dumpSessionSubs ss' `shouldReturn` st
  countSubs ss `shouldReturn` (0, 3)
  atomically (SS.hasPendingSub tSess1 (rcvId q1) ss) `shouldReturn` True
  atomically (SS.hasActiveSub tSess1 (rcvId q1) ss) `shouldReturn` False
  atomically (SS.hasPendingSub tSess1 (rcvId q4) ss) `shouldReturn` False
  atomically (SS.hasActiveSub tSess1 (rcvId q4) ss) `shouldReturn` False
  -- setting active queue without setting session ID would keep it as pending
  atomically $ SS.addActiveSub tSess1 "123" q1 ss
  atomically (SS.hasPendingSub tSess1 (rcvId q1) ss) `shouldReturn` True
  atomically (SS.hasActiveSub tSess1 (rcvId q1) ss) `shouldReturn` False
  dumpSessionSubs ss `shouldReturn` st
  countSubs ss `shouldReturn` (0, 3)
  -- setting active queues
  atomically $ SS.setSessionId tSess1 "123" ss
  atomically $ SS.addActiveSub tSess1 "123" q1 ss
  atomically (SS.hasPendingSub tSess1 (rcvId q1) ss) `shouldReturn` False
  atomically (SS.hasActiveSub tSess1 (rcvId q1) ss) `shouldReturn` True
  atomically (SS.getActiveSubs tSess1 ss) `shouldReturn` M.fromList [("r1", q1)]
  atomically (SS.getPendingSubs tSess1 ss) `shouldReturn` M.fromList [("r2", q2)]
  countSubs ss `shouldReturn` (1, 2)
  atomically $ SS.setSessionId tSess2 "456" ss
  atomically $ SS.addActiveSub tSess2 "456" q4 ss
  atomically (SS.hasPendingSub tSess2 (rcvId q4) ss) `shouldReturn` False
  atomically (SS.hasActiveSub tSess2 (rcvId q4) ss) `shouldReturn` True
  atomically (SS.hasActiveSub tSess1 (rcvId q4) ss) `shouldReturn` False -- wrong transport session
  atomically (SS.getActiveSubs tSess2 ss) `shouldReturn` M.fromList [("r4", q4)]
  atomically (SS.getPendingSubs tSess2 ss) `shouldReturn` M.fromList [("r3", q3)]
  countSubs ss `shouldReturn` (2, 2)
  -- setting pending queues
  st' <- dumpSessionSubs ss
  atomically (SS.setSubsPending TSMUser tSess1 "abc" ss) `shouldReturn` M.empty -- wrong session
  dumpSessionSubs ss `shouldReturn` st'
  atomically (SS.setSubsPending TSMUser tSess1 "123" ss) `shouldReturn` M.fromList [("r1", q1)]
  atomically (SS.getActiveSubs tSess1 ss) `shouldReturn` M.fromList []
  atomically (SS.getPendingSubs tSess1 ss) `shouldReturn` M.fromList [("r1", q1), ("r2", q2)]
  countSubs ss `shouldReturn` (1, 3)
  -- delete subs
  atomically $ SS.deletePendingSub tSess1 (rcvId q1) ss
  atomically (SS.getPendingSubs tSess1 ss) `shouldReturn` M.fromList [("r2", q2)]
  countSubs ss `shouldReturn` (1, 2)
  atomically $ SS.deleteSub tSess1 (rcvId q2) ss
  atomically (SS.getPendingSubs tSess1 ss) `shouldReturn` M.fromList []
  countSubs ss `shouldReturn` (1, 1)
  atomically (SS.getActiveSubs tSess2 ss) `shouldReturn` M.fromList [("r4", q4)]
  atomically $ SS.deleteSub tSess2 (rcvId q4) ss
  atomically (SS.getActiveSubs tSess2 ss) `shouldReturn` M.fromList []
  countSubs ss `shouldReturn` (0, 1)
  countSubs ss' `shouldReturn` (0, 3)
  atomically $ SS.batchDeleteSubs tSess1 [q1, q2] ss'
  countSubs ss' `shouldReturn` (0, 1)

countSubs :: SS.TSessionSubs -> IO (Int, Int)
countSubs = fmap (foldl' (\(n1, n2) (_, (m1, m2)) -> (n1 + M.size m1, n2 + M.size m2)) (0, 0)) . dumpSessionSubs

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
