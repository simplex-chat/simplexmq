{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-unrecognised-pragmas #-}

module Simplex.Messaging.Notifications.Server.Prometheus where

import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime (..), diffUTCTime)
import Data.Time.Clock.System (systemEpochDay)
import Data.Time.Format.ISO8601 (iso8601Show)
import Network.Socket (ServiceName)
import Simplex.Messaging.Notifications.Server.Stats
import Simplex.Messaging.Server.Stats (PeriodStatCounts (..))
import Simplex.Messaging.Transport (simplexMQVersion)

data NtfServerMetrics = NtfServerMetrics
  { statsData :: NtfServerStatsData,
    activeTokensCounts :: PeriodStatCounts,
    activeSubsCounts :: PeriodStatCounts,
    tokenCount :: Int,
    subCount :: Int,
    ntfCount :: Int,
    exeArgs :: Text
  }

data NtfRealTimeMetrics = NtfRealTimeMetrics
  { threadsCount :: Int,
    srvSubscribers :: NtfSMPWorkerMetrics, -- smpSubscribers
    srvClients :: NtfSMPWorkerMetrics, -- smpClients
    srvSubWorkers :: NtfSMPWorkerMetrics, -- smpSubWorkers
    ntfActiveSubs :: NtfSMPSubMetrics, -- srvSubs
    ntfPendingSubs :: NtfSMPSubMetrics, -- pendingSrvSubs
    sessionCount :: Int, -- smpSessions
    pushQLength :: Int -- lengthTBQueue pushQ
  }

data NtfSMPWorkerMetrics = NtfSMPWorkerMetrics {ownServers :: [Text], otherServers :: Int}

data NtfSMPSubMetrics = NtfSMPSubMetrics {ownSrvSubs :: M.Map Text Int, ownSrvSubCount :: Int, otherServers :: Int, otherSrvSubCount :: Int}

{-# FOURMOLU_DISABLE\n#-}
ntfPrometheusMetrics :: NtfServerMetrics -> NtfRealTimeMetrics -> UTCTime -> Text
ntfPrometheusMetrics sm rtm ts =
  time <> tokens <> subscriptions <> notifications <> info
  where
    NtfServerMetrics {statsData, activeTokensCounts = psTkns, activeSubsCounts = psSubs, tokenCount, subCount, ntfCount, exeArgs} = sm
    NtfRealTimeMetrics
      { threadsCount,
        srvSubscribers,
        srvClients,
        srvSubWorkers,
        ntfActiveSubs,
        ntfPendingSubs,
        sessionCount,
        pushQLength
      } = rtm
    NtfServerStatsData
      { _fromTime,
        _tknCreated,
        _tknVerified,
        _tknDeleted,
        _tknReplaced,
        _subCreated,
        _subDeleted,
        _ntfReceived,
        _ntfDelivered,
        _ntfFailed,
        _ntfCronDelivered,
        _ntfCronFailed,
        _ntfVrfQueued,
        _ntfVrfDelivered,
        _ntfVrfFailed,
        _ntfVrfInvalidTkn
      } = statsData
    time =
      "# Recorded at: " <> T.pack (iso8601Show ts) <> "\n\
      \# Stats from: " <> T.pack (iso8601Show _fromTime) <> "\n\
      \\n"
    tokens =
      "# Tokens\n\
      \# ------\n\
      \\n\
      \# HELP simplex_ntf_tokens_created Created tokens\n\
      \# TYPE simplex_ntf_tokens_created gauge\n\
      \simplex_ntf_tokens_created " <> mshow _tknCreated <> "\n# tknCreated\n\
      \\n\
      \# HELP simplex_ntf_tokens_verified Verified tokens\n\
      \# TYPE simplex_ntf_tokens_verified gauge\n\
      \simplex_ntf_tokens_verified " <> mshow _tknVerified <> "\n# tknVerified\n\
      \\n\
      \# HELP simplex_ntf_tokens_deleted Deleted tokens\n\
      \# TYPE simplex_ntf_tokens_deleted gauge\n\
      \simplex_ntf_tokens_deleted " <> mshow _tknDeleted <> "\n# tknDeleted\n\
      \\n\
      \# HELP simplex_ntf_tokens_replaced Deleted tokens\n\
      \# TYPE simplex_ntf_tokens_replaced gauge\n\
      \simplex_ntf_tokens_replaced " <> mshow _tknReplaced <> "\n# tknReplaced\n\
      \\n\
      \# HELP simplex_ntf_tokens_count_daily Daily active tokens\n\
      \# TYPE simplex_ntf_tokens_count_daily gauge\n\
      \simplex_ntf_tokens_count_daily " <> mstr (dayCount psTkns) <> "\n# dayCountTkn\n\
      \\n\
      \# HELP simplex_ntf_tokens_count_weekly Weekly active tokens\n\
      \# TYPE simplex_ntf_tokens_count_weekly gauge\n\
      \simplex_ntf_tokens_count_weekly " <> mstr (weekCount psTkns) <> "\n# weekCountTkn\n\
      \\n\
      \# HELP simplex_ntf_tokens_count_monthly Monthly active tokens\n\
      \# TYPE simplex_ntf_tokens_count_monthly gauge\n\
      \simplex_ntf_tokens_count_monthly " <> mstr (monthCount psTkns) <> "\n# monthCountTkn\n\
      \\n"
    subscriptions =
      "# Subscriptions\n\
      \# -------------\n\
      \\n\
      \# HELP simplex_ntf_subscription_created Created subscriptions\n\
      \# TYPE simplex_ntf_subscription_created gauge\n\
      \simplex_ntf_subscription_created " <> mshow _subCreated <> "\n# subCreated\n\
      \\n\
      \# HELP simplex_ntf_subscription_deleted Deleted subscriptions\n\
      \# TYPE simplex_ntf_subscription_deleted gauge\n\
      \simplex_ntf_subscription_deleted " <> mshow _subDeleted <> "\n# subDeleted\n\
      \\n\
      \# HELP simplex_ntf_subscription_count_daily Daily subscriptions count\n\
      \# TYPE simplex_ntf_subscription_count_daily gauge\n\
      \simplex_ntf_subscription_count_daily " <> mstr (dayCount psSubs) <> "\n# dayCountSub\n\
      \\n\
      \# HELP simplex_ntf_subscription_count_weekly Weekly subscriptions count\n\
      \# TYPE simplex_ntf_subscription_count_weekly gauge\n\
      \simplex_ntf_subscription_count_weekly " <> mstr (weekCount psSubs) <> "\n# weekCountSub\n\
      \\n\
      \# HELP simplex_ntf_subscription_count_monthly Monthly subscriptions count\n\
      \# TYPE simplex_ntf_subscription_count_monthly gauge\n\
      \simplex_ntf_subscription_count_monthly " <> mstr (monthCount psSubs) <> "\n# monthCountSub\n\
      \\n"
    notifications =
      "# Notifications\n\
      \# -------------\n\
      \\n\
      \# HELP simplex_ntf_notifications_received Received notifications\n\
      \# TYPE simplex_ntf_notifications_received gauge\n\
      \simplex_ntf_notifications_received " <> mshow _ntfReceived <> "\n# ntfReceived\n\
      \\n\
      \# HELP simplex_ntf_notifications_delivered Delivered notifications\n\
      \# TYPE simplex_ntf_notifications_delivered gauge\n\
      \simplex_ntf_notifications_delivered " <> mshow _ntfDelivered <> "\n# ntfDelivered\n\
      \\n\
      \# HELP simplex_ntf_notifications_failed Failed notifications\n\
      \# TYPE simplex_ntf_notifications_failed gauge\n\
      \simplex_ntf_notifications_failed " <> mshow _ntfFailed <> "\n# ntfFailed\n\
      \\n\
      \# HELP simplex_ntf_notifications_periodic_delivered Delivered periodic notifications\n\
      \# TYPE simplex_ntf_notifications_periodic_delivered 123 gauge\n\
      \simplex_ntf_notifications_periodic_delivered " <> mshow _ntfCronDelivered <> "\n# ntfCronDelivered\n\
      \\n\
      \# HELP simplex_ntf_notifications_periodic_failed Failed periodic notifications\n\
      \# TYPE simplex_ntf_notifications_periodic_failed gauge\n\
      \simplex_ntf_notifications_periodic_failed " <> mshow _ntfCronFailed <> "\n# ntfCronFailed\n\
      \\n\
      \# HELP simplex_ntf_tokens_verification_queued Count of verification tokens queued\n\
      \# TYPE simplex_ntf_tokens_verification_queued gauge\n\
      \simplex_ntf_tokens_verification_queued " <> mshow _ntfVrfQueued <> "\n# ntfVrfQueued\n\
      \\n\
      \# HELP simplex_ntf_tokens_verification_delivered Delivered verification tokens\n\
      \# TYPE simplex_ntf_tokens_verification_delivered gauge\n\
      \simplex_ntf_tokens_verification_delivered " <> mshow _ntfVrfDelivered <> "\n# ntfVrfDelivered\n\
      \\n\
      \# HELP simplex_ntf_tokens_verification_failed Failed verification tokens\n\
      \# TYPE simplex_ntf_tokens_verification_failed gauge\n\
      \simplex_ntf_tokens_verification_failed " <> mshow _ntfVrfFailed <> "\n# ntfVrfFailed\n\
      \\n\
      \# HELP simplex_ntf_tokens_verification_invalid Invalid verification tokens\n\
      \# TYPE simplex_ntf_tokens_verification_invalid gauge\n\
      \simplex_ntf_tokens_verification_delivered " <> mshow _ntfVrfInvalidTkn <> "\n# ntfVrfInvalidTkn\n\
      \\n"
    info =
      "# Info\n\
      \# ----\n\
      \\n\
      \# HELP simplex_ntf_info A metric with constant '1' value, labeled by server info\n\
      \# TYPE simplex_ntf_info gauge\n\
      \simplex_ntf_info{version=\"" <> T.pack simplexMQVersion <> "\",exe_args=\"" <> exeArgs <> "\"} 1\n\
      \\n"

      -- \# HELP simplex_ntf_notifications_queued Count of Notification count queued\n\
      -- \# TYPE simplex_ntf_notifications_queued gauge\n\
      -- \simplex_ntf_notifications_queued " <> mshow ? <> "\n# Push notifications queue length\n\
      -- \\n\

    mstr a = T.pack a <> " " <> tsEpoch
    mshow :: Show a => a -> Text
    mshow = mstr . show
    tsEpoch = T.pack $ show @Int64 $ floor @Double $ realToFrac (ts `diffUTCTime` epoch) * 1000
    epoch = UTCTime systemEpochDay 0
{-# FOURMOLU_ENABLE\n#-}
