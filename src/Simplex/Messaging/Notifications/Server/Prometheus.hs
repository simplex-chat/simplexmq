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
import Numeric.Natural (Natural)
import Simplex.Messaging.Notifications.Server.Stats
import Simplex.Messaging.Server.Stats (PeriodStatCounts (..))
import Simplex.Messaging.Transport (simplexMQVersion)
import Simplex.Messaging.Util (tshow)

data NtfServerMetrics = NtfServerMetrics
  { statsData :: NtfServerStatsData,
    activeTokensCounts :: PeriodStatCounts,
    activeSubsCounts :: PeriodStatCounts,
    tokenCount :: Int64,
    approxSubCount :: Int64,
    lastNtfCount :: Int64,
    rtsOptions :: Text
  }

rtsOptionsEnv :: Text
rtsOptionsEnv = "NTF_RTS_OPTIONS"

data NtfRealTimeMetrics = NtfRealTimeMetrics
  { threadsCount :: Int,
    srvSubscribers :: NtfSMPWorkerMetrics,
    srvClients :: NtfSMPWorkerMetrics,
    srvSubWorkers :: NtfSMPWorkerMetrics,
    ntfActiveServiceSubs :: NtfSMPSubMetrics,
    ntfActiveQueueSubs :: NtfSMPSubMetrics,
    ntfPendingServiceSubs :: NtfSMPSubMetrics,
    ntfPendingQueueSubs :: NtfSMPSubMetrics,
    smpSessionCount :: Int,
    apnsPushQLength :: Natural
  }

data NtfSMPWorkerMetrics = NtfSMPWorkerMetrics {ownServers :: [Text], otherServers :: Int}

data NtfSMPSubMetrics = NtfSMPSubMetrics {ownSrvSubs :: M.Map Text Int, otherServers :: Int, otherSrvSubCount :: Int}

{-# FOURMOLU_DISABLE\n#-}
ntfPrometheusMetrics :: NtfServerMetrics -> NtfRealTimeMetrics -> UTCTime -> Text
ntfPrometheusMetrics sm rtm ts =
  time <> tokens <> subscriptions <> notifications <> info
  where
    NtfServerMetrics {statsData, activeTokensCounts = psTkns, activeSubsCounts = psSubs, tokenCount, approxSubCount, lastNtfCount, rtsOptions} = sm
    NtfRealTimeMetrics
      { threadsCount,
        srvSubscribers,
        srvClients,
        srvSubWorkers,
        ntfActiveServiceSubs,
        ntfActiveQueueSubs,
        ntfPendingServiceSubs,
        ntfPendingQueueSubs,
        smpSessionCount,
        apnsPushQLength
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
        _ntfReceivedOwn,
        _ntfDeliveredOwn,
        _ntfFailedOwn,
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
      \# TYPE simplex_ntf_tokens_created counter\n\
      \simplex_ntf_tokens_created " <> mshow _tknCreated <> "\n# tknCreated\n\
      \\n\
      \# HELP simplex_ntf_tokens_verified Verified tokens\n\
      \# TYPE simplex_ntf_tokens_verified counter\n\
      \simplex_ntf_tokens_verified " <> mshow _tknVerified <> "\n# tknVerified\n\
      \\n\
      \# HELP simplex_ntf_tokens_deleted Deleted tokens\n\
      \# TYPE simplex_ntf_tokens_deleted counter\n\
      \simplex_ntf_tokens_deleted " <> mshow _tknDeleted <> "\n# tknDeleted\n\
      \\n\
      \# HELP simplex_ntf_tokens_replaced Deleted tokens\n\
      \# TYPE simplex_ntf_tokens_replaced counter\n\
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
      \\n\
      \# HELP simplex_ntf_tokens_total Total number of tokens stored.\n\
      \# TYPE simplex_ntf_tokens_total gauge\n\
      \simplex_ntf_tokens_total " <> mshow tokenCount <> "\n# tokenCount\n\
      \\n"
    subscriptions =
      "# Subscriptions\n\
      \# -------------\n\
      \\n\
      \# HELP simplex_ntf_subscriptions_created Created subscriptions\n\
      \# TYPE simplex_ntf_subscriptions_created counter\n\
      \simplex_ntf_subscriptions_created " <> mshow _subCreated <> "\n# subCreated\n\
      \\n\
      \# HELP simplex_ntf_subscriptions_deleted Deleted subscriptions\n\
      \# TYPE simplex_ntf_subscriptions_deleted counter\n\
      \simplex_ntf_subscriptions_deleted " <> mshow _subDeleted <> "\n# subDeleted\n\
      \\n\
      \# HELP simplex_ntf_subscriptions_count_daily Daily subscriptions count\n\
      \# TYPE simplex_ntf_subscriptions_count_daily gauge\n\
      \simplex_ntf_subscriptions_count_daily " <> mstr (dayCount psSubs) <> "\n# dayCountSub\n\
      \\n\
      \# HELP simplex_ntf_subscriptions_count_weekly Weekly subscriptions count\n\
      \# TYPE simplex_ntf_subscriptions_count_weekly gauge\n\
      \simplex_ntf_subscriptions_count_weekly " <> mstr (weekCount psSubs) <> "\n# weekCountSub\n\
      \\n\
      \# HELP simplex_ntf_subscriptions_count_monthly Monthly subscriptions count\n\
      \# TYPE simplex_ntf_subscriptions_count_monthly gauge\n\
      \simplex_ntf_subscriptions_count_monthly " <> mstr (monthCount psSubs) <> "\n# monthCountSub\n\
      \\n\
      \# HELP simplex_ntf_subscriptions_approx_total Approximate total number of subscriptions stored.\n\
      \# TYPE simplex_ntf_subscriptions_approx_total gauge\n\
      \simplex_ntf_subscriptions_approx_total " <> mshow approxSubCount <> "\n# approxSubCount\n\
      \\n"
      <> showSubMetric ntfActiveServiceSubs "simplex_ntf_smp_service_subscription_active_" "Active"
      <> showSubMetric ntfActiveQueueSubs "simplex_ntf_smp_subscription_active_" "Active"
      <> showSubMetric ntfPendingServiceSubs "simplex_ntf_smp_service_subscription_pending_" "Pending"
      <> showSubMetric ntfPendingQueueSubs "simplex_ntf_smp_subscription_pending_" "Pending"
    notifications =
      "# Notifications\n\
      \# -------------\n\
      \\n\
      \# HELP simplex_ntf_notifications_received Received notifications\n\
      \# TYPE simplex_ntf_notifications_received counter\n\
      \simplex_ntf_notifications_received " <> mshow _ntfReceived <> "\n# ntfReceived\n\
      \\n\
      \# HELP simplex_ntf_notifications_delivered Delivered notifications\n\
      \# TYPE simplex_ntf_notifications_delivered counter\n\
      \simplex_ntf_notifications_delivered " <> mshow _ntfDelivered <> "\n# ntfDelivered\n\
      \\n\
      \# HELP simplex_ntf_notifications_failed Failed notifications\n\
      \# TYPE simplex_ntf_notifications_failed counter\n\
      \simplex_ntf_notifications_failed " <> mshow _ntfFailed <> "\n# ntfFailed\n\
      \\n\
      \# HELP simplex_ntf_notifications_periodic_delivered Delivered periodic notifications\n\
      \# TYPE simplex_ntf_notifications_periodic_delivered counter\n\
      \simplex_ntf_notifications_periodic_delivered " <> mshow _ntfCronDelivered <> "\n# ntfCronDelivered\n\
      \\n\
      \# HELP simplex_ntf_notifications_periodic_failed Failed periodic notifications\n\
      \# TYPE simplex_ntf_notifications_periodic_failed counter\n\
      \simplex_ntf_notifications_periodic_failed " <> mshow _ntfCronFailed <> "\n# ntfCronFailed\n\
      \\n\
      \# HELP simplex_ntf_notifications_verification_queued Token verifications queued\n\
      \# TYPE simplex_ntf_notifications_verification_queued counter\n\
      \simplex_ntf_notifications_verification_queued " <> mshow _ntfVrfQueued <> "\n# ntfVrfQueued\n\
      \\n\
      \# HELP simplex_ntf_notifications_verification_delivered Delivered token verifications\n\
      \# TYPE simplex_ntf_notifications_verification_delivered counter\n\
      \simplex_ntf_notifications_verification_delivered " <> mshow _ntfVrfDelivered <> "\n# ntfVrfDelivered\n\
      \\n\
      \# HELP simplex_ntf_notifications_verification_failed Failed token verification deliveries\n\
      \# TYPE simplex_ntf_notifications_verification_failed counter\n\
      \simplex_ntf_notifications_verification_failed " <> mshow _ntfVrfFailed <> "\n# ntfVrfFailed\n\
      \\n\
      \# HELP simplex_ntf_notifications_verification_invalid_tkn Invalid token errors while delivering verifications\n\
      \# TYPE simplex_ntf_notifications_verification_invalid_tkn counter\n\
      \simplex_ntf_notifications_verification_invalid_tkn " <> mshow _ntfVrfInvalidTkn <> "\n# ntfVrfInvalidTkn\n\
      \\n\
      \# HELP simplex_ntf_notifications_total Total number of last notifications stored.\n\
      \# TYPE simplex_ntf_notifications_total gauge\n\
      \simplex_ntf_notifications_total " <> mshow lastNtfCount <> "\n# lastNtfCount\n\
      \\n"
      <> showNtfsByServer _ntfReceivedOwn "simplex_ntf_notifications_received_own" "Received" "ntfReceivedOwn"
      <> showNtfsByServer _ntfDeliveredOwn "simplex_ntf_notifications_delivered_own" "Delivered" "ntfDeliveredOwn"
      <> showNtfsByServer _ntfFailedOwn "simplex_ntf_notifications_failed_own" "Failed" "ntfFailedOwn"
    info =
      "# Info\n\
      \# ----\n\
      \\n\
      \# HELP simplex_ntf_info Server information. RTS options have to be passed via " <> rtsOptionsEnv <> " env var\n\
      \# TYPE simplex_ntf_info gauge\n\
      \simplex_ntf_info{version=\"" <> T.pack simplexMQVersion <> "\",rts_options=\"" <> rtsOptions <> "\"} 1\n\
      \\n\
      \# HELP simplex_ntf_threads_total Thread count\n\
      \# TYPE simplex_ntf_threads_total gauge\n\
      \simplex_ntf_threads_total " <> mshow threadsCount <> "\n# threadsCount\n\
      \\n"
      <> showWorkerMetric srvSubscribers "simplex_ntf_smp_subscribers_" "SMP subcscribers"
      <> showWorkerMetric srvClients "simplex_ntf_smp_agent_clients_" "SMP agent clients"
      <> showWorkerMetric srvSubWorkers "simplex_ntf_smp_agent_sub_workers_" "SMP agent subscription workers"
      <> "# HELP simplex_ntf_smp_sessions_count SMP sessions count\n\
      \# TYPE simplex_ntf_smp_sessions_count gauge\n\
      \simplex_ntf_smp_sessions_count " <> mshow smpSessionCount <> "\n# smpSessionCount\n\
      \\n\
      \# HELP simplex_ntf_apns_push_queue_length Count of notifications in push queue\n\
      \# TYPE simplex_ntf_apns_push_queue_length gauge\n\
      \simplex_ntf_apns_push_queue_length " <> mshow apnsPushQLength <> "\n# apnsPushQLength\n\
      \\n"
    showSubMetric NtfSMPSubMetrics {ownSrvSubs, otherServers, otherSrvSubCount} mPfx descrPfx =
      showOwnSrvSubs <> showOtherSrvSubs
      where
        showOwnSrvSubs
          | M.null ownSrvSubs = showOwn_ "" 0 0
          | otherwise = T.concat $ map (\(host, cnt) -> showOwn_ (metricHost host) 1 cnt) $ M.assocs ownSrvSubs
        showOwn_ param srvCnt subCnt =
          gaugeMetric (mPfx <> "server_count_own") param srvCnt (descrPfx <> " SMP subscriptions, own server count") "ownSrvSubs server"
            <> gaugeMetric (mPfx <> "sub_count_own") param subCnt (descrPfx <> " SMP subscriptions count for own servers") "ownSrvSubs count"
        showOtherSrvSubs =
          gaugeMetric (mPfx <> "server_count_other") "" otherServers (descrPfx <> " SMP subscriptions, other server count") "otherServers"
            <> gaugeMetric (mPfx <> "sub_count_other") "" otherSrvSubCount (descrPfx <> " SMP subscriptions count for other servers") "otherSrvSubCount"
    showNtfsByServer srvNtfs mName descrPfx varName =
      "# HELP " <> mName <> " " <> descrPfx <> " notifications\n\
      \# TYPE " <> mName <> " counter\n"
      <> showNtfMetrics
      <> "# " <> varName <> "\n\n"
      where
        showNtfMetrics
          | null srvNtfs = mName <> " " <> mshow 0 <> "\n"
          | otherwise = T.concat $ map (\(host, value) -> mName <> metricHost host <> " " <> mshow value <> "\n") srvNtfs
    showWorkerMetric NtfSMPWorkerMetrics {ownServers, otherServers} mPfx descrPfx =
      showOwnServers <> showOtherServers
      where
        showOwnServers
          | null ownServers = showOwn_ "" 0
          | otherwise = T.concat $ map (\host -> showOwn_ (metricHost host) 1) ownServers
        showOwn_ param cnt = gaugeMetric (mPfx <> "count_own") param cnt (descrPfx <> " count for own servers") "ownServers"
        showOtherServers = gaugeMetric (mPfx <> "count_other") "" otherServers (descrPfx <> " count for other servers") "otherServers"
    gaugeMetric :: Text -> Text -> Int -> Text -> Text -> Text
    gaugeMetric name param value descr codeRef =
      "# HELP " <> name <> " " <> descr <> "\n\
      \# TYPE " <> name <> " gauge\n\
      \" <> name <> param <> " " <> mshow value <> "\n# " <> codeRef <> "\n\
      \\n"
    metricHost host = "{server=\"" <> host <> "\"}"
    mstr a = a <> " " <> tsEpoch
    mshow :: Show a => a -> Text
    mshow = mstr . tshow
    tsEpoch = tshow @Int64 $ floor @Double $ realToFrac (ts `diffUTCTime` epoch) * 1000
    epoch = UTCTime systemEpochDay 0
{-# FOURMOLU_ENABLE\n#-}
