{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Server.StatsStore
  ( StatsStore (..),
    loadStats,
    saveStats,
#if defined(dbServerPostgres)
    PeriodSet (..),
    getDBStats,
#endif
  )
where

import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import qualified Data.ByteString.Char8 as B
import qualified Data.Text as T
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Server.Stats
import Simplex.Messaging.Util (ifM, tshow)
import System.Directory (doesFileExist, removeFile, renameFile)
import UnliftIO.Exception (tryAny)
#if defined(dbServerPostgres)
import Data.Bifunctor (bimap)
import Data.IORef (IORef)
import Data.Int (Int16, Int64)
import Data.IntSet (IntSet)
import qualified Data.IntSet as IS
import Data.List (find, intersperse)
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Database.PostgreSQL.Simple (Only (..), Query)
import qualified Database.PostgreSQL.Simple as DB
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.ToField (ToField (..))
import Simplex.Messaging.Agent.Store.Postgres.Common (DBStore, withTransaction)
import Simplex.Messaging.Util (toChunks, whenM)
#endif

data StatsStore
  = StatsFile FilePath
#if defined(dbServerPostgres)
  | StatsDB DBStore FilePath
#endif

loadStats :: StatsStore -> IO (Maybe ServerStatsData)
loadStats = \case
  StatsFile f -> ifM (doesFileExist f) (Just <$> readStatsFile f) (pure Nothing)
#if defined(dbServerPostgres)
  StatsDB st f ->
    getDBStats st >>= \case
      Just d -> do
        whenM (doesFileExist f) $ logWarn $ "server stats file " <> T.pack f <> " is ignored, stats are restored from the database"
        pure $ Just d
      Nothing -> ifM (doesFileExist f) (Just <$> importStatsFile st f) (pure Nothing)
#endif

saveStats :: StatsStore -> ServerStats -> IO ()
saveStats = \case
  StatsFile f -> saveStatsFile f
#if defined(dbServerPostgres)
  StatsDB st _ -> saveDBStats st
#endif

readStatsFile :: FilePath -> IO ServerStatsData
readStatsFile f = do
  logNote $ "restoring server stats from file " <> T.pack f
  strDecode <$> B.readFile f >>= \case
    Right d -> pure d
    Left e -> E.throwIO $ userError $ "error parsing server stats file " <> f <> ": " <> e

saveStatsFile :: FilePath -> ServerStats -> IO ()
saveStatsFile f ss = do
  d <- getServerStatsData ss
  tryAny (B.writeFile tmp (strEncode d) >> renameFile tmp f) >>= \case
    Right () -> pure ()
    Left e -> do
      logError $ "error saving server stats to file " <> T.pack f <> ": " <> tshow e
      void $ tryAny $ removeFile tmp
  where
    tmp = f <> ".tmp"

#if defined(dbServerPostgres)
data PeriodSet = PSMsgDay | PSMsgWeek | PSMsgMonth | PSNtfDay | PSNtfWeek | PSNtfMonth
  deriving (Bounded, Enum, Eq, Ord, Show)

-- stored in server_stats_queues.period_set, the values must not change
periodSetId :: PeriodSet -> Int16
periodSetId = \case
  PSMsgDay -> 1
  PSMsgWeek -> 2
  PSMsgMonth -> 3
  PSNtfDay -> 4
  PSNtfWeek -> 5
  PSNtfMonth -> 6

instance ToField PeriodSet where
  toField = toField . periodSetId

periodSetFromId :: Int16 -> Maybe PeriodSet
periodSetFromId i = find ((i ==) . periodSetId) [minBound .. maxBound]

periodSetHashes :: ServerStatsData -> PeriodSet -> IntSet
periodSetHashes ServerStatsData {_activeQueues = q, _activeQueuesNtf = n} = \case
  PSMsgDay -> _day q
  PSMsgWeek -> _week q
  PSMsgMonth -> _month q
  PSNtfDay -> _day n
  PSNtfWeek -> _week n
  PSNtfMonth -> _month n

periodSetPending :: ServerStats -> PeriodSet -> Maybe (IORef PendingHashes)
periodSetPending ServerStats {activeQueues, activeQueuesNtf} = \case
  PSMsgDay -> pendingDay <$> pendingPeriods activeQueues
  PSMsgWeek -> pendingWeek <$> pendingPeriods activeQueues
  PSMsgMonth -> pendingMonth <$> pendingPeriods activeQueues
  PSNtfDay -> pendingDay <$> pendingPeriods activeQueuesNtf
  PSNtfWeek -> pendingWeek <$> pendingPeriods activeQueuesNtf
  PSNtfMonth -> pendingMonth <$> pendingPeriods activeQueuesNtf

getDBStats :: DBStore -> IO (Maybe ServerStatsData)
getDBStats st =
  withTransaction st $ \db ->
    DB.query_ db selectStatsQuery >>= \case
      StatsRow d : _ -> Just . withPeriodSets d <$> DB.fold_ db "SELECT period_set, queue_hash FROM server_stats_queues" M.empty addHash
      [] -> pure Nothing
  where
    addHash sets (psId :: Int16, h :: Int64) = case periodSetFromId psId of
      Just ps -> pure $! M.alter (Just . maybe (IS.singleton h') (IS.insert h')) ps sets
      Nothing -> E.throwIO $ userError $ "unknown period_set " <> show psId
      where
        h' = fromIntegral h
    withPeriodSets d sets =
      d
        { _activeQueues = periodData PSMsgDay PSMsgWeek PSMsgMonth,
          _activeQueuesNtf = periodData PSNtfDay PSNtfWeek PSNtfMonth
        }
      where
        periodData dp wp mp = PeriodStatsData {_day = get dp, _week = get wp, _month = get mp}
        get p = M.findWithDefault IS.empty p sets

importStatsFile :: DBStore -> FilePath -> IO ServerStatsData
importStatsFile st f = do
  d <- readStatsFile f
  withTransaction st $ \db -> do
    void $ DB.execute_ db "DELETE FROM server_stats_queues"
    forM_ [minBound .. maxBound] $ \ps -> insertHashes db ps $ periodSetHashes d ps
    upsertStats db d
  renameFile f $ f <> ".bak"
  logNote "server stats imported to the database"
  pure d

saveDBStats :: DBStore -> ServerStats -> IO ()
saveDBStats st ss = do
  taken <- fmap catMaybes $ forM [minBound .. maxBound] $ \ps ->
    forM (periodSetPending ss ps) $ \ref -> (ps,ref,) <$> takePendingHashes ref
  d <- getServerStatsData ss
  tryAny (withTransaction st $ \db -> mapM_ (savePending db) taken >> upsertStats db d) >>= \case
    Right () -> pure ()
    Left e -> do
      logError $ "error saving server stats to the database: " <> tshow e
      forM_ taken $ \(_, ref, p) -> restorePendingHashes ref p
  where
    savePending db (ps, _, PendingHashes {pendingReset, pendingAdded}) = do
      when pendingReset $ void $ DB.execute db "DELETE FROM server_stats_queues WHERE period_set = ?" (Only ps)
      insertHashes db ps pendingAdded

insertHashes :: DB.Connection -> PeriodSet -> IntSet -> IO ()
insertHashes db ps hs =
  forM_ (toChunks hashInsertBatch $ IS.toList hs) $ \hs' ->
    void $
      DB.executeMany
        db
        "INSERT INTO server_stats_queues (period_set, queue_hash) VALUES (?, ?) ON CONFLICT DO NOTHING"
        (map (\h -> (ps, fromIntegral h :: Int64)) $ L.toList hs')

-- rows per INSERT statement, bounds the query size of the one-time file import
hashInsertBatch :: Int
hashInsertBatch = 10000

upsertStats :: DB.Connection -> ServerStatsData -> IO ()
upsertStats db d = do
  savedAt <- systemSeconds <$> getSystemTime
  void $ DB.execute db upsertStatsQuery $ savedAt : map (($ d) . snd) statsFields

selectStatsQuery :: Query
selectStatsQuery = "SELECT " <> commaSep (map fst statsFields) <> " FROM server_stats WHERE server_stats_id = 1"

upsertStatsQuery :: Query
upsertStatsQuery =
  "INSERT INTO server_stats (server_stats_id, saved_at, "
    <> commaSep cols
    <> ") VALUES (1, ?, "
    <> commaSep (map (const "?") cols)
    <> ") ON CONFLICT (server_stats_id) DO UPDATE SET "
    <> commaSep (map (\c -> c <> " = EXCLUDED." <> c) ("saved_at" : cols))
  where
    cols = map fst statsFields

commaSep :: [Query] -> Query
commaSep = mconcat . intersperse ", "

-- the order must match the FromRow StatsRow instance
statsFields :: [(Query, ServerStatsData -> Int64)]
statsFields =
  ("from_time", round . utcTimeToPOSIXSeconds . _fromTime)
    : map
      (fmap (fromIntegral .))
      ( [ ("q_created", _qCreated),
          ("q_secured", _qSecured),
          ("q_deleted_all", _qDeletedAll),
          ("q_deleted_new", _qDeletedNew),
          ("q_deleted_secured", _qDeletedSecured),
          ("q_deleted_all_b", _qDeletedAllB),
          ("q_blocked", _qBlocked),
          ("q_sub", _qSub),
          ("q_sub_all_b", _qSubAllB),
          ("q_sub_auth", _qSubAuth),
          ("q_sub_duplicate", _qSubDuplicate),
          ("q_sub_prohibited", _qSubProhibited),
          ("q_sub_end", _qSubEnd),
          ("q_sub_end_b", _qSubEndB),
          ("ntf_created", _ntfCreated),
          ("ntf_new_created", _ntfNewCreated),
          ("ntf_deleted", _ntfDeleted),
          ("ntf_deleted_b", _ntfDeletedB),
          ("ntf_sub", _ntfSub),
          ("ntf_sub_b", _ntfSubB),
          ("ntf_sub_auth", _ntfSubAuth),
          ("ntf_sub_duplicate", _ntfSubDuplicate),
          ("msg_sent", _msgSent),
          ("msg_sent_auth", _msgSentAuth),
          ("msg_sent_quota", _msgSentQuota),
          ("msg_sent_large", _msgSentLarge),
          ("msg_sent_block", _msgSentBlock),
          ("msg_recv", _msgRecv),
          ("msg_recv_get", _msgRecvGet),
          ("msg_get", _msgGet),
          ("msg_get_no_msg", _msgGetNoMsg),
          ("msg_get_auth", _msgGetAuth),
          ("msg_get_duplicate", _msgGetDuplicate),
          ("msg_get_prohibited", _msgGetProhibited),
          ("msg_expired", _msgExpired),
          ("msg_sent_ntf", _msgSentNtf),
          ("msg_recv_ntf", _msgRecvNtf),
          ("msg_ntfs", _msgNtfs),
          ("msg_ntfs_b", _msgNtfsB),
          ("msg_ntf_no_sub", _msgNtfNoSub),
          ("msg_ntf_lost", _msgNtfLost),
          ("msg_ntf_expired", _msgNtfExpired)
        ]
          <> proxyFields "p_relays" _pRelays
          <> proxyFields "p_relays_own" _pRelaysOwn
          <> proxyFields "p_msg_fwds" _pMsgFwds
          <> proxyFields "p_msg_fwds_own" _pMsgFwdsOwn
          <> [("p_msg_fwds_recv", _pMsgFwdsRecv)]
          <> serviceFields "rcv_services" _rcvServices
          <> serviceFields "ntf_services" _ntfServices
          <> map
            (fmap (. _rslvStats))
            [ ("rslv_reqs", _rslvReqs),
              ("rslv_succ", _rslvSucc),
              ("rslv_not_found", _rslvNotFound),
              ("rslv_resolver_errs", _rslvResolverErrs),
              ("rslv_disabled", _rslvDisabled)
            ]
      )
  where
    proxyFields pfx sel =
      map
        (bimap ((pfx <> "_") <>) (. sel))
        [ ("requests", _pRequests),
          ("successes", _pSuccesses),
          ("errors_connect", _pErrorsConnect),
          ("errors_compat", _pErrorsCompat),
          ("errors_other", _pErrorsOther)
        ]
    serviceFields pfx sel =
      map
        (bimap ((pfx <> "_") <>) (. sel))
        [ ("assoc_new", _srvAssocNew),
          ("assoc_duplicate", _srvAssocDuplicate),
          ("assoc_updated", _srvAssocUpdated),
          ("assoc_removed", _srvAssocRemoved),
          ("sub_count", _srvSubCount),
          ("sub_duplicate", _srvSubDuplicate),
          ("sub_queues", _srvSubQueues),
          ("sub_end", _srvSubEnd)
        ]

newtype StatsRow = StatsRow ServerStatsData

instance FromRow StatsRow where
  fromRow = do
    _fromTime <- posixSecondsToUTCTime . fromIntegral <$> field @Int64
    _qCreated <- field
    _qSecured <- field
    _qDeletedAll <- field
    _qDeletedNew <- field
    _qDeletedSecured <- field
    _qDeletedAllB <- field
    _qBlocked <- field
    _qSub <- field
    _qSubAllB <- field
    _qSubAuth <- field
    _qSubDuplicate <- field
    _qSubProhibited <- field
    _qSubEnd <- field
    _qSubEndB <- field
    _ntfCreated <- field
    _ntfNewCreated <- field
    _ntfDeleted <- field
    _ntfDeletedB <- field
    _ntfSub <- field
    _ntfSubB <- field
    _ntfSubAuth <- field
    _ntfSubDuplicate <- field
    _msgSent <- field
    _msgSentAuth <- field
    _msgSentQuota <- field
    _msgSentLarge <- field
    _msgSentBlock <- field
    _msgRecv <- field
    _msgRecvGet <- field
    _msgGet <- field
    _msgGetNoMsg <- field
    _msgGetAuth <- field
    _msgGetDuplicate <- field
    _msgGetProhibited <- field
    _msgExpired <- field
    _msgSentNtf <- field
    _msgRecvNtf <- field
    _msgNtfs <- field
    _msgNtfsB <- field
    _msgNtfNoSub <- field
    _msgNtfLost <- field
    _msgNtfExpired <- field
    _pRelays <- proxyStatsP
    _pRelaysOwn <- proxyStatsP
    _pMsgFwds <- proxyStatsP
    _pMsgFwdsOwn <- proxyStatsP
    _pMsgFwdsRecv <- field
    _rcvServices <- serviceStatsP
    _ntfServices <- serviceStatsP
    _rslvStats <- NameResolverStatsData <$> field <*> field <*> field <*> field <*> field
    pure $
      StatsRow
        ServerStatsData
          { _fromTime,
            _qCreated,
            _qSecured,
            _qDeletedAll,
            _qDeletedAllB,
            _qDeletedNew,
            _qDeletedSecured,
            _qBlocked,
            _qSub,
            _qSubAllB,
            _qSubAuth,
            _qSubDuplicate,
            _qSubProhibited,
            _qSubEnd,
            _qSubEndB,
            _ntfCreated,
            _ntfNewCreated,
            _ntfDeleted,
            _ntfDeletedB,
            _ntfSub,
            _ntfSubB,
            _ntfSubAuth,
            _ntfSubDuplicate,
            _msgSent,
            _msgSentAuth,
            _msgSentQuota,
            _msgSentLarge,
            _msgSentBlock,
            _msgRecv,
            _msgRecvAckTimes = emptyTimeBuckets,
            _msgRecvGet,
            _msgGet,
            _msgGetNoMsg,
            _msgGetAuth,
            _msgGetDuplicate,
            _msgGetProhibited,
            _msgExpired,
            _activeQueues = newPeriodStatsData,
            _msgSentNtf,
            _msgRecvNtf,
            _activeQueuesNtf = newPeriodStatsData,
            _msgNtfs,
            _msgNtfsB,
            _msgNtfNoSub,
            _msgNtfLost,
            _msgNtfExpired,
            _pRelays,
            _pRelaysOwn,
            _pMsgFwds,
            _pMsgFwdsOwn,
            _pMsgFwdsRecv,
            _ntfServices,
            _rcvServices,
            _rcvServicesSubMsg = 0,
            _rcvServicesSubDuplicate = 0,
            _authDelayExceeded = 0,
            _cmdSlotWaits = 0,
            _cmdSlotWaitMs = 0,
            _cmdSlotWaitMaxMs = 0,
            _cmdSlotWaitTimeouts = 0,
            _qCount = 0,
            _msgCount = 0,
            _ntfCount = 0,
            _rslvStats
          }
    where
      proxyStatsP = ProxyStatsData <$> field <*> field <*> field <*> field <*> field
      serviceStatsP = do
        _srvAssocNew <- field
        _srvAssocDuplicate <- field
        _srvAssocUpdated <- field
        _srvAssocRemoved <- field
        _srvSubCount <- field
        _srvSubDuplicate <- field
        _srvSubQueues <- field
        _srvSubEnd <- field
        pure newServiceStatsData {_srvAssocNew, _srvAssocDuplicate, _srvAssocUpdated, _srvAssocRemoved, _srvSubCount, _srvSubDuplicate, _srvSubQueues, _srvSubEnd}
#endif
