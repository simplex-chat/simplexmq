{-# LANGUAGE CPP #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module CoreTests.ServerStatsTests where

import qualified Data.ByteString.Char8 as B
import Data.Hashable (hash)
import Data.IORef
import Data.IntSet (IntSet)
import qualified Data.IntSet as IS
import Data.Maybe (isNothing)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..))
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (EntityId (..))
import Simplex.Messaging.Server.Stats
import Simplex.Messaging.Server.StatsStore
import System.Directory (doesFileExist)
import Test.Hspec hiding (fit, it)
import Util
#if defined(dbServerPostgres)
import Control.Exception (bracket)
import Control.Monad (void)
import CoreTests.MsgStoreTests (testPostgresStoreConfig)
import qualified Database.PostgreSQL.Simple as DB
import Data.String (fromString)
import Simplex.Messaging.Agent.Store.Postgres.Common (DBStore, withTransaction)
import Simplex.Messaging.Server.MsgStore.Postgres (PostgresMsgStore)
import Simplex.Messaging.Server.MsgStore.Types (MsgStoreClass (..))
import Simplex.Messaging.Server.QueueStore.Postgres (PostgresQueueStore (..))
#endif

serverStatsTests :: Spec
serverStatsTests = do
  describe "pending period stats" $ do
    it "should not track pending hashes when disabled" testNoPending
    it "should track hashes added since the last take" testPendingAdded
    it "should reset pending hashes with period sets" testPendingReset
    it "should merge restored pending hashes" testMergePending
  describe "stats file" $ do
    it "should save and load stats" testFileSaveLoad
    it "should return no stats without file" testFileMissing
    it "should log and continue when file cannot be written" testFileSaveError
    it "should fail on invalid file" testFileParseError
#if defined(dbServerPostgres)
  describe "stats database" $ do
    it "should save and load stats with period sets" testDBSaveLoad
    it "should save added hashes and delete reset sets" testDBResetAndAdded
    it "should keep pending hashes when save fails" testDBSaveFailure
    it "should import stats file when database has no stats" testDBImportFile
    it "should ignore stats file when database has stats" testDBIgnoreFile
#endif

q1, q2, q3, q4, q5 :: EntityId
q1 = EntityId "queue1"
q2 = EntityId "queue2"
q3 = EntityId "queue3"
q4 = EntityId "queue4"
q5 = EntityId "queue5"

hashes :: [EntityId] -> IntSet
hashes = IS.fromList . map (hash . unEntityId)

utcDay :: Integer -> Int -> Int -> UTCTime
utcDay y m d = UTCTime (fromGregorian y m d) 3600

-- 2026-06-10 is Wednesday, 2026-06-08 is Monday, 2026-06-01 is Monday and the 1st
wednesday, monday, monday1st :: UTCTime
wednesday = utcDay 2026 6 10
monday = utcDay 2026 6 8
monday1st = utcDay 2026 6 1

noPending :: PendingHashes
noPending = PendingHashes {pendingReset = False, pendingAdded = IS.empty}

resetPending :: PendingHashes
resetPending = PendingHashes {pendingReset = True, pendingAdded = IS.empty}

added :: [EntityId] -> PendingHashes
added qs = PendingHashes {pendingReset = False, pendingAdded = hashes qs}

testNoPending :: IO ()
testNoPending = do
  ps <- newPeriodStats
  isNothing (pendingPeriods ps) `shouldBe` True
  updatePeriodStats ps q1
  readIORef (day ps) `shouldReturn` hashes [q1]
  ServerStats {activeQueues, activeQueuesNtf} <- newServerStats False wednesday
  isNothing (pendingPeriods activeQueues) `shouldBe` True
  isNothing (pendingPeriods activeQueuesNtf) `shouldBe` True

testPendingAdded :: IO ()
testPendingAdded = do
  ServerStats {activeQueues = ps} <- newServerStats True wednesday
  Just PendingPeriods {pendingDay, pendingWeek, pendingMonth} <- pure $ pendingPeriods ps
  mapM_ (updatePeriodStats ps) [q1, q2, q1]
  takePendingHashes pendingDay `shouldReturn` added [q1, q2]
  takePendingHashes pendingDay `shouldReturn` noPending
  updatePeriodStats ps q1
  takePendingHashes pendingDay `shouldReturn` noPending
  updatePeriodStats ps q3
  takePendingHashes pendingDay `shouldReturn` added [q3]
  takePendingHashes pendingWeek `shouldReturn` added [q1, q2, q3]
  takePendingHashes pendingMonth `shouldReturn` added [q1, q2, q3]
  readIORef (day ps) `shouldReturn` hashes [q1, q2, q3]

testPendingReset :: IO ()
testPendingReset = do
  ps <- newPendingPeriodStats
  Just PendingPeriods {pendingDay, pendingWeek, pendingMonth} <- pure $ pendingPeriods ps
  updatePeriodStats ps q1
  PeriodStatCounts {dayCount, weekCount, monthCount} <- periodStatCounts ps wednesday
  (dayCount, weekCount, monthCount) `shouldBe` ("1", "", "")
  takePendingHashes pendingDay `shouldReturn` resetPending
  takePendingHashes pendingWeek `shouldReturn` added [q1]
  takePendingHashes pendingMonth `shouldReturn` added [q1]
  updatePeriodStats ps q2
  _ <- periodStatCounts ps monday
  takePendingHashes pendingDay `shouldReturn` resetPending
  takePendingHashes pendingWeek `shouldReturn` resetPending
  takePendingHashes pendingMonth `shouldReturn` added [q2]
  readIORef (month ps) `shouldReturn` hashes [q1, q2]
  updatePeriodStats ps q3
  _ <- periodStatCounts ps monday1st
  mapM takePendingHashes [pendingDay, pendingWeek, pendingMonth] `shouldReturn` [resetPending, resetPending, resetPending]
  mapM readIORef [day ps, week ps, month ps] `shouldReturn` [IS.empty, IS.empty, IS.empty]
  updatePeriodStats ps q4
  takePendingHashes pendingMonth `shouldReturn` added [q4]

testMergePending :: IO ()
testMergePending = do
  mergePendingHashes (added [q1]) (added [q2]) `shouldBe` added [q1, q2]
  mergePendingHashes resetPending (added [q2]) `shouldBe` PendingHashes {pendingReset = True, pendingAdded = hashes [q2]}
  ref <- newIORef $ added [q5]
  restorePendingHashes ref PendingHashes {pendingReset = True, pendingAdded = hashes [q3, q4]}
  readIORef ref `shouldReturn` PendingHashes {pendingReset = True, pendingAdded = hashes [q3, q4, q5]}

statsFile :: HasTestEnv => FilePath
statsFile = testPath "smp-server-stats.log"

-- every zero counter line of the file encoding gets a distinct value, so a column order mistake changes the result
distinctCounters :: ServerStatsData -> ServerStatsData
distinctCounters d = either error id $ strDecode $ B.unlines $ zipWith setValue [1 :: Int ..] $ B.lines $ strEncode d
  where
    setValue i l = case B.breakSubstring "=" l of
      (k, "=0") -> k <> "=" <> B.pack (show i)
      _ -> l

newDistinctStats :: Bool -> IO ServerStats
newDistinctStats trackPending = do
  ss <- newServerStats trackPending wednesday
  setServerStats ss . distinctCounters =<< getServerStatsData ss
  pure ss

testFileSaveLoad :: HasTestEnv => IO ()
testFileSaveLoad = do
  ss <- newDistinctStats False
  updatePeriodStats (activeQueues ss) q1
  updatePeriodStats (activeQueuesNtf ss) q2
  saveStats (StatsFile statsFile) ss
  doesFileExist (statsFile <> ".tmp") `shouldReturn` False
  expected <- getServerStatsData ss
  Just d <- loadStats (StatsFile statsFile)
  strEncode d `shouldBe` strEncode expected
  doesFileExist statsFile `shouldReturn` True

testFileMissing :: HasTestEnv => IO ()
testFileMissing = (isNothing <$> loadStats (StatsFile statsFile)) `shouldReturn` True

testFileSaveError :: HasTestEnv => IO ()
testFileSaveError = do
  let f = testPath "missing/smp-server-stats.log"
  saveStats (StatsFile f) =<< newServerStats False wednesday
  doesFileExist f `shouldReturn` False

testFileParseError :: HasTestEnv => IO ()
testFileParseError = do
  B.writeFile statsFile "invalid"
  loadStats (StatsFile statsFile) `shouldThrow` anyIOException

#if defined(dbServerPostgres)
withStatsDB :: HasTestEnv => (DBStore -> IO a) -> IO a
withStatsDB action = bracket (newMsgStore testPostgresStoreConfig :: IO PostgresMsgStore) closeMsgStore $ action . dbStore . queueStore

testDBSaveLoad :: HasTestEnv => IO ()
testDBSaveLoad = withStatsDB $ \st -> do
  ss <- newDistinctStats True
  mapM_ (updatePeriodStats $ activeQueues ss) [q1, q2]
  updatePeriodStats (activeQueuesNtf ss) q3
  saveStats (StatsDB st statsFile) ss
  expected <- getServerStatsData ss
  Just d <- getDBStats st
  strEncode d `shouldBe` strEncode expected {_qCount = 0}
  _day (_activeQueues d) `shouldBe` hashes [q1, q2]
  _month (_activeQueuesNtf d) `shouldBe` hashes [q3]

testDBResetAndAdded :: HasTestEnv => IO ()
testDBResetAndAdded = withStatsDB $ \st -> do
  ss <- newServerStats True wednesday
  let msgQueues = activeQueues ss
  mapM_ (updatePeriodStats msgQueues) [q1, q2]
  updatePeriodStats (activeQueuesNtf ss) q3
  saveStats (StatsDB st statsFile) ss
  updatePeriodStats msgQueues q4
  _ <- periodStatCounts msgQueues wednesday
  updatePeriodStats msgQueues q5
  saveStats (StatsDB st statsFile) ss
  Just ServerStatsData {_activeQueues, _activeQueuesNtf} <- getDBStats st
  _day _activeQueues `shouldBe` hashes [q5]
  _week _activeQueues `shouldBe` hashes [q1, q2, q4, q5]
  _month _activeQueues `shouldBe` hashes [q1, q2, q4, q5]
  _day _activeQueuesNtf `shouldBe` hashes [q3]

testDBSaveFailure :: HasTestEnv => IO ()
testDBSaveFailure = withStatsDB $ \st -> do
  ss <- newServerStats True wednesday
  updatePeriodStats (activeQueues ss) q1
  saveStats (StatsDB st statsFile) ss
  updatePeriodStats (activeQueues ss) q2
  renameTable st "server_stats_queues" "server_stats_queues_moved"
  saveStats (StatsDB st statsFile) ss
  renameTable st "server_stats_queues_moved" "server_stats_queues"
  Just d <- getDBStats st
  _day (_activeQueues d) `shouldBe` hashes [q1]
  saveStats (StatsDB st statsFile) ss
  Just d' <- getDBStats st
  _day (_activeQueues d') `shouldBe` hashes [q1, q2]
  where
    renameTable st from to = withTransaction st $ \db -> void $ DB.execute_ db $ fromString $ "ALTER TABLE " <> from <> " RENAME TO " <> to

testDBImportFile :: HasTestEnv => IO ()
testDBImportFile = withStatsDB $ \st -> do
  ss <- newDistinctStats False
  updatePeriodStats (activeQueues ss) q1
  d <- getServerStatsData ss
  B.writeFile statsFile $ strEncode d
  Just imported <- loadStats (StatsDB st statsFile)
  strEncode imported `shouldBe` strEncode d
  doesFileExist statsFile `shouldReturn` False
  doesFileExist (statsFile <> ".bak") `shouldReturn` True
  Just saved <- getDBStats st
  strEncode saved `shouldBe` strEncode d {_qCount = 0}

testDBIgnoreFile :: HasTestEnv => IO ()
testDBIgnoreFile = withStatsDB $ \st -> do
  ss <- newServerStats True wednesday
  updatePeriodStats (activeQueues ss) q1
  saveStats (StatsDB st statsFile) ss
  saved <- getServerStatsData ss
  B.writeFile statsFile . strEncode =<< getServerStatsData =<< newDistinctStats False
  Just loaded <- loadStats (StatsDB st statsFile)
  strEncode loaded `shouldBe` strEncode saved {_qCount = 0}
  doesFileExist statsFile `shouldReturn` True
#endif
