{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-unrecognised-pragmas #-}

module Simplex.Messaging.Server.Prometheus where

import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime (..), diffUTCTime)
import Data.Time.Clock.System (systemEpochDay)
import Data.Time.Format.ISO8601 (iso8601Show)
import Network.Socket (ServiceName)
import Simplex.Messaging.Server.Stats

data ServerMetrics = ServerMetrics
  { statsData :: ServerStatsData,
    activeQueueCounts :: PeriodStatCounts,
    activeNtfCounts :: PeriodStatCounts,
    queueCount :: Int,
    notifierCount :: Int
  }

data RealTimeMetrics = RealTimeMetrics
  { socketStats :: [(ServiceName, SocketStats)],
    threadsCount :: Int,
    clientsCount :: Int,
    smpSubsCount :: Int,
    smpSubClientsCount :: Int,
    ntfSubsCount :: Int,
    ntfSubClientsCount :: Int
  }

data SocketStats = SocketStats
  { socketsAccepted :: Int,
    socketsClosed :: Int,
    socketsActive :: Int,
    socketsLeaked :: Int
  }

{-# FOURMOLU_DISABLE\n#-}
prometheusMetrics :: ServerMetrics -> RealTimeMetrics -> UTCTime -> Text
prometheusMetrics sm rtm ts =
  time <> queues <> subscriptions <> messages <> ntfMessages <> ntfs <> relays <> info
  where
    ServerMetrics {statsData, activeQueueCounts = ps, activeNtfCounts = psNtf, queueCount, notifierCount} = sm
    RealTimeMetrics
      { socketStats,
        threadsCount,
        clientsCount,
        smpSubsCount,
        smpSubClientsCount,
        ntfSubsCount,
        ntfSubClientsCount
      } = rtm
    ServerStatsData
      { _fromTime,
        _qCreated,
        _qSecured,
        _qDeletedAll,
        _qDeletedAllB,
        _qDeletedNew,
        _qDeletedSecured,
        _qSub,
        _qSubAllB,
        _qSubAuth,
        _qSubDuplicate,
        _qSubProhibited,
        _qSubEnd,
        _qSubEndB,
        _ntfCreated,
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
        _msgRecv,
        _msgRecvGet,
        _msgGet,
        _msgGetNoMsg,
        _msgGetAuth,
        _msgGetDuplicate,
        _msgGetProhibited,
        _msgExpired,
        _activeQueues,
        _msgSentNtf,
        _msgRecvNtf,
        _activeQueuesNtf,
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
        _qCount,
        _msgCount,
        _ntfCount
      } = statsData
    time =
      "# Recorded at: " <> T.pack (iso8601Show ts) <> "\n\
      \# Stats from: " <> T.pack (iso8601Show _fromTime) <> "\n\
      \\n"
    queues =
      "# Queues\n\
      \# ------\n\
      \\n\
      \# HELP simplex_smp_queues_created Created queues\n\
      \# TYPE simplex_smp_queues_created counter\n\
      \simplex_smp_queues_created " <> mshow _qCreated <> "\n# qCreated\n\
      \\n\
      \# HELP simplex_smp_queues_secured Secured queues\n\
      \# TYPE simplex_smp_queues_secured counter\n\
      \simplex_smp_queues_secured " <> mshow _qSecured <> "\n# qSecured\n\
      \\n\
      \# HELP simplex_smp_queues_deleted Deleted queues\n\
      \# TYPE simplex_smp_queues_deleted counter\n\
      \simplex_smp_queues_deleted{type=\"all\"} " <> mshow _qDeletedAll <> "\n# qDeleted\n\
      \simplex_smp_queues_deleted{type=\"new\"} " <> mshow _qDeletedNew <> "\n# qDeletedNew\n\
      \simplex_smp_queues_deleted{type=\"secured\"} " <> mshow _qDeletedSecured <> "\n# qDeletedSecured\n\
      \\n\
      \# HELP simplex_smp_queues_deleted_batch Batched requests to delete queues\n\
      \# TYPE simplex_smp_queues_deleted_batch counter\n\
      \simplex_smp_queues_deleted_batch " <> mshow _qDeletedAllB <> "\n# qDeletedAllB\n\
      \\n\
      \# HELP simplex_smp_queues_total1 Total number of stored queues (first type of count).\n\
      \# TYPE simplex_smp_queues_total1 gauge\n\
      \simplex_smp_queues_total1 " <> mshow _qCount <> "\n# qCount\n\
      \\n\
      \# HELP simplex_smp_queues_total2 Total number of stored queues (second type of count).\n\
      \# TYPE simplex_smp_queues_total2 gauge\n\
      \simplex_smp_queues_total2 " <> mshow queueCount <> "\n# qCount2\n\
      \\n\
      \# HELP simplex_smp_queues_daily Daily active queues.\n\
      \# TYPE simplex_smp_queues_daily gauge\n\
      \simplex_smp_queues_daily " <> mstr (dayCount ps) <> "\n# dayMsgQueues\n\
      \\n\
      \# HELP simplex_smp_queues_weekly Weekly active queues.\n\
      \# TYPE simplex_smp_queues_weekly gauge\n\
      \simplex_smp_queues_weekly " <> mstr (weekCount ps) <> "\n# weekMsgQueues\n\
      \\n\
      \# HELP simplex_smp_queues_monthly Monthly active queues.\n\
      \# TYPE simplex_smp_queues_monthly gauge\n\
      \simplex_smp_queues_monthly " <> mstr (monthCount ps) <> "\n# monthMsgQueues\n\
      \\n\
      \# HELP simplex_smp_queues_notify_daily Daily active queues with notifications.\n\
      \# TYPE simplex_smp_queues_notify_daily gauge\n\
      \simplex_smp_queues_notify_daily " <> mstr (dayCount psNtf) <> "\n# dayCountNtf\n\
      \\n\
      \# HELP simplex_smp_queues_notify_weekly Weekly active queues with notifications.\n\
      \# TYPE simplex_smp_queues_notify_weekly gauge\n\
      \simplex_smp_queues_notify_weekly " <> mstr (weekCount psNtf) <> "\n# weekCountNtf\n\
      \\n\
      \# HELP simplex_smp_queues_notify_monthly Monthly active queues with notifications.\n\
      \# TYPE simplex_smp_queues_notify_monthly gauge\n\
      \simplex_smp_queues_notify_monthly " <> mstr (monthCount psNtf) <> "\n# monthCountNtf\n\
      \\n"
    subscriptions =
      "# Subscriptions\n\
      \# -------------\n\
      \\n\
      \# HELP simplex_smp_subscribtion_successes Successful subscriptions.\n\
      \# TYPE simplex_smp_subscribtion_successes counter\n\
      \simplex_smp_subscribtion_successes " <> mshow _qSub <> "\n# qSub\n\
      \\n\
      \# HELP simplex_smp_subscribtion_successes_batch Batched successful subscriptions.\n\
      \# TYPE simplex_smp_subscribtion_successes_batch counter\n\
      \simplex_smp_subscribtion_successes_batch " <> mshow _qSubAllB <> "\n# qSubAllB\n\
      \\n\
      \# HELP simplex_smp_subscribtion_end Ended subscriptions.\n\
      \# TYPE simplex_smp_subscribtion_end counter\n\
      \simplex_smp_subscribtion_end " <> mshow _qSubEnd <> "\n# qSubEnd\n\
      \\n\
      \# HELP simplex_smp_subscribtion_end_batch Batched ended subscriptions.\n\
      \# TYPE simplex_smp_subscribtion_end_batch counter\n\
      \simplex_smp_subscribtion_end_batch " <> mshow _qSubEndB <> "\n# qSubEndB\n\
      \\n\
      \# HELP simplex_smp_subscribtion_errors Subscription errors.\n\
      \# TYPE simplex_smp_subscribtion_errors counter\n\
      \simplex_smp_subscribtion_errors{type=\"auth\"} " <> mshow _qSubAuth <> "\n# qSubAuth\n\
      \simplex_smp_subscribtion_errors{type=\"duplicate\"} " <> mshow _qSubDuplicate <> "\n# qSubDuplicate\n\
      \simplex_smp_subscribtion_errors{type=\"prohibited\"} " <> mshow _qSubProhibited <> "\n# qSubProhibited\n\
      \\n"
    messages =
      "# Messages\n\
      \# --------\n\
      \\n\
      \# HELP simplex_smp_messages_sent Sent messages.\n\
      \# TYPE simplex_smp_messages_sent counter\n\
      \simplex_smp_messages_sent " <> mshow _msgSent <> "\n# msgSent\n\
      \\n\
      \# HELP simplex_smp_messages_sent_errors Total number of messages errors by type.\n\
      \# TYPE simplex_smp_messages_sent_errors counter\n\
      \simplex_smp_messages_sent_errors{type=\"auth\"} " <> mshow _msgSentAuth <> "\n# msgSentAuth\n\
      \simplex_smp_messages_sent_errors{type=\"quota\"} " <> mshow _msgSentQuota <> "\n# msgSentQuota\n\
      \simplex_smp_messages_sent_errors{type=\"large\"} " <> mshow _msgSentLarge <> "\n# msgSentLarge\n\
      \\n\
      \# HELP simplex_smp_messages_received Received messages.\n\
      \# TYPE simplex_smp_messages_received counter\n\
      \simplex_smp_messages_received " <> mshow _msgRecv <> "\n# msgRecv\n\
      \\n\
      \# HELP simplex_smp_messages_expired Expired messages.\n\
      \# TYPE simplex_smp_messages_expired counter\n\
      \simplex_smp_messages_expired " <> mshow _msgExpired <> "\n# msgExpired\n\
      \\n\
      \# HELP simplex_smp_messages_total Total number of messages stored.\n\
      \# TYPE simplex_smp_messages_total gauge\n\
      \simplex_smp_messages_total " <> mshow _msgCount <> "\n# msgCount\n\
      \\n"
    ntfMessages =
      "# Notification messages (client)\n\
      \# ------------------------------\n\
      \\n\
      \# HELP simplex_smp_messages_notify_sent Sent messages with notification flag (cleint).\n\
      \# TYPE simplex_smp_messages_notify_sent counter\n\
      \simplex_smp_messages_notify_sent " <> mshow _msgSentNtf <> "\n# msgSentNtf\n\
      \\n\
      \# HELP simplex_smp_messages_notify_received Received messages with notification flag (client).\n\
      \# TYPE simplex_smp_messages_notify_received counter\n\
      \simplex_smp_messages_notify_received " <> mshow _msgRecvNtf <> "\n# msgRecvNtf\n\
      \\n\
      \# HELP simplex_smp_messages_notify_get_sent Requests to get messages with notification flag (client).\n\
      \# TYPE simplex_smp_messages_notify_get_sent counter\n\
      \simplex_smp_messages_notify_get_sent " <> mshow _msgGet <> "\n# msgGet\n\
      \\n\
      \# HELP simplex_smp_messages_notify_get_received Succesfully received get requests messages with notification flag (client).\n\
      \# TYPE simplex_smp_messages_notify_get_received counter\n\
      \simplex_smp_messages_notify_get_received " <> mshow _msgRecvGet <> "\n# msgRecvGet\n\
      \\n\
      \# HELP simplex_smp_messages_notify_get_errors Error events with messages with notification flag (client). \n\
      \# TYPE simplex_smp_messages_notify_get_errors counter\n\
      \simplex_smp_messages_notify_get_errors{type=\"nomsg\"} " <> mshow _msgGetNoMsg <> "\n# msgGetNoMsg\n\
      \simplex_smp_messages_notify_get_errors{type=\"auth\"} " <> mshow _msgGetAuth <> "\n# msgGetAuth\n\
      \simplex_smp_messages_notify_get_errors{type=\"duplicate\"} " <> mshow _msgGetDuplicate <> "\n# msgGetDuplicate\n\
      \simplex_smp_messages_notify_get_errors{type=\"prohibited\"} " <> mshow _msgGetProhibited <> "\n# msgGetProhibited\n\
      \\n\
      \# HELP simplex_smp_queues_notify_created Created queues with notification flag (client).\n\
      \# TYPE simplex_smp_queues_notify_created counter\n\
      \simplex_smp_queues_notify_created " <> mshow _ntfCreated <> "\n# ntfCreated\n\
      \\n\
      \# HELP simplex_smp_queues_notify_deleted Deleted queues with notification flag (client).\n\
      \# TYPE simplex_smp_queues_notify_deleted counter\n\
      \simplex_smp_queues_notify_deleted " <> mshow _ntfDeleted <> "\n# ntfDeleted\n\
      \\n\
      \# HELP simplex_smp_queues_notify_deleted_batch Deleted batched queues with notification flag (client).\n\
      \# TYPE simplex_smp_queues_notify_deleted_batch counter\n\
      \simplex_smp_queues_notify_deleted_batch " <> mshow _ntfDeletedB <> "\n# ntfDeletedB\n\
      \\n\
      \# HELP simplex_smp_queues_notify_total1 Total number of stored queues with notification flag (first type of count).\n\
      \# TYPE simplex_smp_queues_notify_total1 gauge\n\
      \simplex_smp_queues_notify_total1 " <> mshow _ntfCount <> "\n# ntfCount1\n\
      \\n\
      \# HELP simplex_smp_queues_notify_total2 Total number of stored queues with notification flag (second type of count).\n\
      \# TYPE simplex_smp_queues_notify_total2 gauge\n\
      \simplex_smp_queues_notify_total2 " <> mshow notifierCount <> "\n# ntfCount2\n\
      \\n"
    ntfs =
      "# Notifications (server)\n\
      \# ----------------------\n\
      \\n\
      \# HELP simplex_smp_messages_ntf_successes Successful events with notification messages (to ntf server). \n\
      \# TYPE simplex_smp_messages_ntf_successes counter\n\
      \simplex_smp_messages_ntf_successes " <> mshow _msgNtfs <> "\n# msgNtfs\n\
      \\n\
      \# HELP simplex_smp_messages_ntf_successes_batch Successful batched events with notification messages (to ntf server). \n\
      \# TYPE simplex_smp_messages_ntf_successes_batch counter\n\
      \simplex_smp_messages_ntf_successes_batch " <> mshow _msgNtfsB <> "\n# msgNtfsB\n\
      \\n\
      \# HELP simplex_smp_messages_ntf_errors Error events with notification messages (to ntf server). \n\
      \# TYPE simplex_smp_messages_ntf_errors counter\n\
      \simplex_smp_messages_ntf_errors{type=\"nosub\"} " <> mshow _msgNtfNoSub <> "\n# msgNtfNoSub\n\
      \simplex_smp_messages_ntf_errors{type=\"lost\"} " <> mshow _msgNtfLost <> "\n# msgNtfLost\n\
      \simplex_smp_messages_ntf_errors{type=\"expired\"} " <> mshow _msgNtfExpired <> "\n# msgNtfExpired\n\
      \\n\
      \# HELP simplex_smp_subscription_ntf_requests Subscription requests with notification flag (from ntf server). \n\
      \# TYPE simplex_smp_subscription_ntf_requests counter\n\
      \simplex_smp_subscription_ntf_requests " <> mshow _ntfSub <> "\n# ntfSub\n\
      \\n\
      \# HELP simplex_smp_subscription_ntf_requests_batch Batched subscription requests with notification flag (from ntf server). \n\
      \# TYPE simplex_smp_subscription_ntf_requests_batch counter\n\
      \simplex_smp_subscription_ntf_requests_batch " <> mshow _ntfSubB <> "\n# ntfSubB\n\
      \\n\
      \# HELP simplex_smp_subscribtion_ntf_errors Subscription errors with notification flag (from ntf server). \n\
      \# TYPE simplex_smp_subscribtion_ntf_errors counter\n\
      \simplex_smp_subscribtion_ntf_errors{type=\"auth\"} " <> mshow _ntfSubAuth <> "\n# ntfSubAuth\n\
      \simplex_smp_subscribtion_ntf_errors{type=\"duplicate\"} " <> mshow _ntfSubDuplicate <> "\n# ntfSubDuplicate\n\
      \\n"
    relays =
      "# Relays\n\
      \# ------\n\
      \\n\
      \# HELP simplex_smp_relay_sessions_requests Session requests through relay.\n\
      \# TYPE simplex_smp_relay_sessions_requests counter\n\
      \simplex_smp_relay_sessions_requests{source=\"all\"} " <> mshow (_pRequests _pRelays) <> "\n# pRelays_pRequests\n\
      \simplex_smp_relay_sessions_requests{source=\"own\"} " <> mshow (_pRequests _pRelaysOwn) <> "\n# pRelaysOwn_pRequests\n\
      \\n\
      \# HELP simplex_smp_relay_sessions_successes Successful session events through relay.\n\
      \# TYPE simplex_smp_relay_sessions_successes counter\n\
      \simplex_smp_relay_sessions_successes{source=\"all\"} " <> mshow (_pSuccesses _pRelays) <> "\n# pRelays_pSuccesses\n\
      \simplex_smp_relay_sessions_successes{source=\"own\"} " <> mshow (_pSuccesses _pRelaysOwn) <> "\n# pRelaysOwn_pSuccesses\n\
      \\n\
      \# HELP simplex_smp_relay_sessions_errors Error session events through relay.\n\
      \# TYPE simplex_smp_relay_sessions_errors counter\n\
      \simplex_smp_relay_sessions_errors{source=\"all\",type=\"connect\"} " <> mshow (_pErrorsConnect _pRelays) <> "\n# pRelays_pErrorsConnect\n\
      \simplex_smp_relay_sessions_errors{source=\"all\",type=\"compat\"} " <> mshow (_pErrorsCompat _pRelays) <> "\n# pRelays_pErrorsCompat\n\
      \simplex_smp_relay_sessions_errors{source=\"all\",type=\"other\"} " <> mshow (_pErrorsOther _pRelays) <> "\n# pRelays_pErrorsOther\n\
      \simplex_smp_relay_sessions_errors{source=\"own\",type=\"connect\"} " <> mshow (_pErrorsConnect _pRelaysOwn) <> "\n# pRelaysOwn_pErrorsConnect\n\
      \simplex_smp_relay_sessions_errors{source=\"own\",type=\"compat\"} " <> mshow (_pErrorsCompat _pRelaysOwn) <> "\n# pRelaysOwn_pErrorsCompat\n\
      \simplex_smp_relay_sessions_errors{source=\"own\",type=\"other\"} " <> mshow (_pErrorsOther _pRelaysOwn) <> "\n# pRelaysOwn_pErrorsOther\n\
      \\n\
      \# HELP simplex_smp_relay_messages_requests Message requests sent through relay.\n\
      \# TYPE simplex_smp_relay_messages_requests counter\n\
      \simplex_smp_relay_messages_requests{source=\"all\"} " <> mshow (_pRequests _pMsgFwds) <> "\n# pMsgFwds_pRequests\n\
      \simplex_smp_relay_messages_requests{source=\"own\"} " <> mshow (_pRequests _pMsgFwdsOwn) <> "\n# pMsgFwdsOwn_pRequests\n\
      \\n\
      \# HELP simplex_smp_relay_messages_successes Successful messages sent through relay.\n\
      \# TYPE simplex_smp_relay_messages_successes counter\n\
      \simplex_smp_relay_messages_successes{source=\"all\"} " <> mshow (_pSuccesses _pMsgFwds) <> "\n# pMsgFwds_pSuccesses\n\
      \simplex_smp_relay_messages_successes{source=\"own\"} " <> mshow (_pSuccesses _pMsgFwdsOwn) <> "\n# pMsgFwdsOwn_pSuccesses\n\
      \\n\
      \# HELP simplex_smp_relay_messages_errors Error events with messages sent through relay.\n\
      \# TYPE simplex_smp_relay_messages_errors counter\n\
      \simplex_smp_relay_messages_errors{source=\"all\",type=\"connect\"} " <> mshow (_pErrorsConnect _pMsgFwds) <> "\n# pMsgFwds_pErrorsConnect\n\
      \simplex_smp_relay_messages_errors{source=\"all\",type=\"compat\"} " <> mshow (_pErrorsCompat _pMsgFwds) <> "\n# pMsgFwds_pErrorsCompat\n\
      \simplex_smp_relay_messages_errors{source=\"all\",type=\"other\"} " <> mshow (_pErrorsOther _pMsgFwds) <> "\n# pMsgFwds_pErrorsOther\n\
      \simplex_smp_relay_messages_errors{source=\"own\",type=\"connect\"} " <> mshow (_pErrorsConnect _pMsgFwdsOwn) <> "\n# pMsgFwdsOwn_pErrorsConnect\n\
      \simplex_smp_relay_messages_errors{source=\"own\",type=\"compat\"} " <> mshow (_pErrorsCompat _pMsgFwdsOwn) <> "\n# pMsgFwdsOwn_pErrorsCompat\n\
      \simplex_smp_relay_messages_errors{source=\"own\",type=\"other\"} " <> mshow (_pErrorsOther _pMsgFwdsOwn) <> "\n# pMsgFwdsOwn_pErrorsOther\n\
      \\n\
      \# HELP simplex_smp_relay_messages_received Relay messages statistics.\n\
      \# TYPE simplex_smp_relay_messages_received counter\n\
      \simplex_smp_relay_messages_received " <> mshow _pMsgFwdsRecv <> "\n# pMsgFwdsRecv\n\
      \\n"
    info =
      "# Info\n\
      \# ----\n\
      \\n"
      <> socketsMetric socketsAccepted "simplex_smp_sockets_accepted" "Accepted sockets"
      <> socketsMetric socketsClosed "simplex_smp_sockets_closed" "Closed sockets"
      <> socketsMetric socketsActive "simplex_smp_sockets_active" "Active sockets"
      <> socketsMetric socketsLeaked "simplex_smp_sockets_leaked" "Leaked sockets"
      <> "# HELP simplex_smp_threads_total Threads\n\
      \# TYPE simplex_smp_threads_total gauge\n\
      \simplex_smp_threads_total " <> mshow threadsCount <> "\n\
      \\n\
      \# HELP simplex_smp_clients_total Clients\n\
      \# TYPE simplex_smp_clients_total gauge\n\
      \simplex_smp_clients_total " <> mshow clientsCount <> "\n\
      \\n\
      \# HELP simplex_smp_subscribtion_total Total subscriptions\n\
      \# TYPE simplex_smp_subscribtion_total gauge\n\
      \simplex_smp_subscribtion_total " <> mshow smpSubsCount <> "\n# smpSubs\n\
      \\n\
      \# HELP simplex_smp_subscribtion_clients_total Subscribed clients, first counting method\n\
      \# TYPE simplex_smp_subscribtion_clients_total gauge\n\
      \simplex_smp_subscribtion_clients_total " <> mshow smpSubClientsCount <> "\n# smpSubClients\n\
      \\n\
      \# HELP simplex_smp_subscription_ntf_total Total notification subscripbtions (from ntf server)\n\
      \# TYPE simplex_smp_subscription_ntf_total gauge\n\
      \simplex_smp_subscription_ntf_total " <> mshow ntfSubsCount <> "\n# ntfSubs\n\
      \\n\
      \# HELP simplex_smp_subscription_ntf_clients_total Total subscribed NTF servers, first counting method\n\
      \# TYPE simplex_smp_subscription_ntf_clients_total gauge\n\
      \simplex_smp_subscription_ntf_clients_total " <> mshow ntfSubClientsCount <> "\n# ntfSubClients\n"
    socketsMetric :: (SocketStats -> Int) -> Text -> Text -> Text
    socketsMetric sel metric descr =
      "# HELP " <> metric <> " " <> descr <> "\n"
        <> "# TYPE " <> metric <> " gauge\n"
        <> T.concat (map (\(port, ss) -> metric <> "{port=\"" <> T.pack port <> "\"} " <> mshow (sel ss) <> "\n") socketStats)
        <> "\n"
    mstr a = T.pack a <> " " <> tsEpoch
    mshow :: Show a => a -> Text
    mshow = mstr . show
    tsEpoch = T.pack $ show @Int64 $ floor @Double $ realToFrac (ts `diffUTCTime` epoch) * 1000
    epoch = UTCTime systemEpochDay 0
{-# FOURMOLU_ENABLE\n#-}
