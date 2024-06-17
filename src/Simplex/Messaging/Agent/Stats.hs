{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.Agent.Stats where

import qualified Data.Aeson.TH as J
import Data.Map (Map)
import Data.Time.Clock (UTCTime (..))
import Simplex.Messaging.Agent.Protocol (UserId)
import Simplex.Messaging.Parsers (defaultJSON)
import Simplex.Messaging.Protocol (SMPServer, XFTPServer)
import UnliftIO.STM

data AgentSMPServerStats = AgentSMPServerStats
  { sentDirect :: TVar Int, -- successfully sent messages
    sentViaProxy :: TVar Int, -- successfully sent messages via proxy
    sentDirectAttempts :: TVar Int, -- direct sending attempts (min 1 for each sent message)
    sentViaProxyAttempts :: TVar Int, -- proxy sending retries
    sentAuthErrs :: TVar Int, -- send AUTH errors
    sentQuotaErrs :: TVar Int, -- send QUOTA permanent errors (message expired)
    sentExpiredErrs :: TVar Int, -- send expired errors
    sentDirectErrs :: TVar Int, -- other direct send permanent errors (excluding above)
    sentProxyErrs :: TVar Int, -- other proxy send permanent errors (excluding above)
    recvMsgs :: TVar Int, -- total messages received
    recvDuplicates :: TVar Int, -- duplicate messages received
    recvCryptoErrs :: TVar Int, -- message decryption errors
    recvErrs :: TVar Int, -- receive errors
    connCreated :: TVar Int,
    connSecured :: TVar Int,
    connCompleted :: TVar Int,
    connDeleted :: TVar Int,
    connSubscribed :: TVar Int, -- total successful subscription
    connSubAttempts :: TVar Int, -- subscription retries
    connSubErrs :: TVar Int -- permanent subscription errors (temporary accounted for in retries)
  }

data AgentSMPServerStatsData = AgentSMPServerStatsData
  { _sentDirect :: Int,
    _sentViaProxy :: Int,
    _sentDirectAttempts :: Int,
    _sentViaProxyAttempts :: Int,
    _sentAuthErrs :: Int,
    _sentQuotaErrs :: Int,
    _sentExpiredErrs :: Int,
    _sentDirectErrs :: Int,
    _sentProxyErrs :: Int,
    _recvMsgs :: Int,
    _recvDuplicates :: Int,
    _recvCryptoErrs :: Int,
    _recvErrs :: Int,
    _connCreated :: Int,
    _connSecured :: Int,
    _connCompleted :: Int,
    _connDeleted :: Int,
    _connSubscribed :: Int,
    _connSubAttempts :: Int,
    _connSubErrs :: Int
  }
  deriving (Show)

newAgentSMPServerStats :: STM AgentSMPServerStats
newAgentSMPServerStats = do
  sentDirect <- newTVar 0
  sentViaProxy <- newTVar 0
  sentDirectAttempts <- newTVar 0
  sentViaProxyAttempts <- newTVar 0
  sentAuthErrs <- newTVar 0
  sentQuotaErrs <- newTVar 0
  sentExpiredErrs <- newTVar 0
  sentDirectErrs <- newTVar 0
  sentProxyErrs <- newTVar 0
  recvMsgs <- newTVar 0
  recvDuplicates <- newTVar 0
  recvCryptoErrs <- newTVar 0
  recvErrs <- newTVar 0
  connCreated <- newTVar 0
  connSecured <- newTVar 0
  connCompleted <- newTVar 0
  connDeleted <- newTVar 0
  connSubscribed <- newTVar 0
  connSubAttempts <- newTVar 0
  connSubErrs <- newTVar 0
  pure
    AgentSMPServerStats
      { sentDirect,
        sentViaProxy,
        sentDirectAttempts,
        sentViaProxyAttempts,
        sentAuthErrs,
        sentQuotaErrs,
        sentExpiredErrs,
        sentDirectErrs,
        sentProxyErrs,
        recvMsgs,
        recvDuplicates,
        recvCryptoErrs,
        recvErrs,
        connCreated,
        connSecured,
        connCompleted,
        connDeleted,
        connSubscribed,
        connSubAttempts,
        connSubErrs
      }

newAgentSMPServerStats' :: AgentSMPServerStatsData -> STM AgentSMPServerStats
newAgentSMPServerStats' s = do
  sentDirect <- newTVar $ _sentDirect s
  sentViaProxy <- newTVar $ _sentDirect s
  sentDirectAttempts <- newTVar $ _sentDirect s
  sentViaProxyAttempts <- newTVar $ _sentDirect s
  sentAuthErrs <- newTVar $ _sentDirect s
  sentQuotaErrs <- newTVar $ _sentDirect s
  sentExpiredErrs <- newTVar $ _sentDirect s
  sentDirectErrs <- newTVar $ _sentDirect s
  sentProxyErrs <- newTVar $ _sentDirect s
  recvMsgs <- newTVar $ _sentDirect s
  recvDuplicates <- newTVar $ _sentDirect s
  recvCryptoErrs <- newTVar $ _sentDirect s
  recvErrs <- newTVar $ _sentDirect s
  connCreated <- newTVar $ _sentDirect s
  connSecured <- newTVar $ _sentDirect s
  connCompleted <- newTVar $ _sentDirect s
  connDeleted <- newTVar $ _sentDirect s
  connSubscribed <- newTVar $ _sentDirect s
  connSubAttempts <- newTVar $ _sentDirect s
  connSubErrs <- newTVar $ _sentDirect s
  pure
    AgentSMPServerStats
      { sentDirect,
        sentViaProxy,
        sentDirectAttempts,
        sentViaProxyAttempts,
        sentAuthErrs,
        sentQuotaErrs,
        sentExpiredErrs,
        sentDirectErrs,
        sentProxyErrs,
        recvMsgs,
        recvDuplicates,
        recvCryptoErrs,
        recvErrs,
        connCreated,
        connSecured,
        connCompleted,
        connDeleted,
        connSubscribed,
        connSubAttempts,
        connSubErrs
      }

getAgentSMPServerStats :: AgentSMPServerStats -> STM AgentSMPServerStatsData
getAgentSMPServerStats s = do
  _sentDirect <- readTVar $ sentDirect s
  _sentViaProxy <- readTVar $ sentDirect s
  _sentDirectAttempts <- readTVar $ sentDirect s
  _sentViaProxyAttempts <- readTVar $ sentDirect s
  _sentAuthErrs <- readTVar $ sentDirect s
  _sentQuotaErrs <- readTVar $ sentDirect s
  _sentExpiredErrs <- readTVar $ sentDirect s
  _sentDirectErrs <- readTVar $ sentDirect s
  _sentProxyErrs <- readTVar $ sentDirect s
  _recvMsgs <- readTVar $ sentDirect s
  _recvDuplicates <- readTVar $ sentDirect s
  _recvCryptoErrs <- readTVar $ sentDirect s
  _recvErrs <- readTVar $ sentDirect s
  _connCreated <- readTVar $ sentDirect s
  _connSecured <- readTVar $ sentDirect s
  _connCompleted <- readTVar $ sentDirect s
  _connDeleted <- readTVar $ sentDirect s
  _connSubscribed <- readTVar $ sentDirect s
  _connSubAttempts <- readTVar $ sentDirect s
  _connSubErrs <- readTVar $ sentDirect s
  pure
    AgentSMPServerStatsData
      { _sentDirect,
        _sentViaProxy,
        _sentDirectAttempts,
        _sentViaProxyAttempts,
        _sentAuthErrs,
        _sentQuotaErrs,
        _sentExpiredErrs,
        _sentDirectErrs,
        _sentProxyErrs,
        _recvMsgs,
        _recvDuplicates,
        _recvCryptoErrs,
        _recvErrs,
        _connCreated,
        _connSecured,
        _connCompleted,
        _connDeleted,
        _connSubscribed,
        _connSubAttempts,
        _connSubErrs
      }

setAgentSMPServerStats :: AgentSMPServerStats -> AgentSMPServerStatsData -> STM ()
setAgentSMPServerStats s d = do
  writeTVar (sentDirect s) $! _sentDirect d
  writeTVar (sentViaProxy s) $! _sentViaProxy d
  writeTVar (sentDirectAttempts s) $! _sentDirectAttempts d
  writeTVar (sentViaProxyAttempts s) $! _sentViaProxyAttempts d
  writeTVar (sentAuthErrs s) $! _sentAuthErrs d
  writeTVar (sentQuotaErrs s) $! _sentQuotaErrs d
  writeTVar (sentExpiredErrs s) $! _sentExpiredErrs d
  writeTVar (sentDirectErrs s) $! _sentDirectErrs d
  writeTVar (sentProxyErrs s) $! _sentProxyErrs d
  writeTVar (recvMsgs s) $! _recvMsgs d
  writeTVar (recvDuplicates s) $! _recvDuplicates d
  writeTVar (recvCryptoErrs s) $! _recvCryptoErrs d
  writeTVar (recvErrs s) $! _recvErrs d
  writeTVar (connCreated s) $! _connCreated d
  writeTVar (connSecured s) $! _connSecured d
  writeTVar (connCompleted s) $! _connCompleted d
  writeTVar (connDeleted s) $! _connDeleted d
  writeTVar (connSubscribed s) $! _connSubscribed d
  writeTVar (connSubAttempts s) $! _connSubAttempts d
  writeTVar (connSubErrs s) $! _connSubErrs d

data AgentXFTPServerStats = AgentXFTPServerStats
  { -- fromTime :: TVar UTCTime,
    replUpload :: TVar Int, -- total replicas uploaded to server
    replUploadRetries :: TVar Int, -- upload retries
    replUploadSuccesses :: TVar Int, -- successful uploads
    replUploadErr :: TVar Int, -- upload errors
    replDownload :: TVar Int, -- total replicas downloaded from server
    replDownloadRetries :: TVar Int, -- download retries
    replDownloadSuccesses :: TVar Int, -- successful downloads
    replDownloadAuth :: TVar Int, -- download AUTH errors
    replDownloadErr :: TVar Int, -- other download errors (excluding above)
    replDelete :: TVar Int, -- total replicas deleted from server
    replDeleteRetries :: TVar Int, -- delete retries
    replDeleteSuccesses :: TVar Int, -- successful deletes
    replDeleteErr :: TVar Int -- delete errors
  }

data AgentXFTPServerStatsData = AgentXFTPServerStatsData
  { -- _fromTime :: UTCTime,
    _replUpload :: Int,
    _replUploadRetries :: Int,
    _replUploadSuccesses :: Int,
    _replUploadErr :: Int,
    _replDownload :: Int,
    _replDownloadRetries :: Int,
    _replDownloadSuccesses :: Int,
    _replDownloadAuth :: Int,
    _replDownloadErr :: Int,
    _replDelete :: Int,
    _replDeleteRetries :: Int,
    _replDeleteSuccesses :: Int,
    _replDeleteErr :: Int
  }
  deriving (Show)

-- newAgentXFTPServerStats :: UTCTime -> STM AgentXFTPServerStats
-- newAgentXFTPServerStats ts = do
newAgentXFTPServerStats :: STM AgentXFTPServerStats
newAgentXFTPServerStats = do
  -- fromTime <- newTVar ts
  replUpload <- newTVar 0
  replUploadRetries <- newTVar 0
  replUploadSuccesses <- newTVar 0
  replUploadErr <- newTVar 0
  replDownload <- newTVar 0
  replDownloadRetries <- newTVar 0
  replDownloadSuccesses <- newTVar 0
  replDownloadAuth <- newTVar 0
  replDownloadErr <- newTVar 0
  replDelete <- newTVar 0
  replDeleteRetries <- newTVar 0
  replDeleteSuccesses <- newTVar 0
  replDeleteErr <- newTVar 0
  pure
    AgentXFTPServerStats
      { -- fromTime,
        replUpload,
        replUploadRetries,
        replUploadSuccesses,
        replUploadErr,
        replDownload,
        replDownloadRetries,
        replDownloadSuccesses,
        replDownloadAuth,
        replDownloadErr,
        replDelete,
        replDeleteRetries,
        replDeleteSuccesses,
        replDeleteErr
      }

newAgentXFTPServerStats' :: AgentXFTPServerStatsData -> STM AgentXFTPServerStats
newAgentXFTPServerStats' s = do
  -- s@AgentXFTPServerStatsData {_fromTime} = do
  -- fromTime <- newTVar _fromTime
  replUpload <- newTVar $ _replUpload s
  replUploadRetries <- newTVar $ _replUploadRetries s
  replUploadSuccesses <- newTVar $ _replUploadSuccesses s
  replUploadErr <- newTVar $ _replUploadErr s
  replDownload <- newTVar $ _replDownload s
  replDownloadRetries <- newTVar $ _replDownloadRetries s
  replDownloadSuccesses <- newTVar $ _replDownloadSuccesses s
  replDownloadAuth <- newTVar $ _replDownloadAuth s
  replDownloadErr <- newTVar $ _replDownloadErr s
  replDelete <- newTVar $ _replDelete s
  replDeleteRetries <- newTVar $ _replDeleteRetries s
  replDeleteSuccesses <- newTVar $ _replDeleteSuccesses s
  replDeleteErr <- newTVar $ _replDeleteErr s
  pure
    AgentXFTPServerStats
      { -- fromTime,
        replUpload,
        replUploadRetries,
        replUploadSuccesses,
        replUploadErr,
        replDownload,
        replDownloadRetries,
        replDownloadSuccesses,
        replDownloadAuth,
        replDownloadErr,
        replDelete,
        replDeleteRetries,
        replDeleteSuccesses,
        replDeleteErr
      }

getAgentXFTPServerStats :: AgentXFTPServerStats -> STM AgentXFTPServerStatsData
getAgentXFTPServerStats s = do
  -- s@AgentXFTPServerStats {fromTime} = do
  -- _fromTime <- readTVar fromTime
  _replUpload <- readTVar $ replUpload s
  _replUploadRetries <- readTVar $ replUpload s
  _replUploadSuccesses <- readTVar $ replUpload s
  _replUploadErr <- readTVar $ replUpload s
  _replDownload <- readTVar $ replUpload s
  _replDownloadRetries <- readTVar $ replUpload s
  _replDownloadSuccesses <- readTVar $ replUpload s
  _replDownloadAuth <- readTVar $ replUpload s
  _replDownloadErr <- readTVar $ replUpload s
  _replDelete <- readTVar $ replUpload s
  _replDeleteRetries <- readTVar $ replUpload s
  _replDeleteSuccesses <- readTVar $ replUpload s
  _replDeleteErr <- readTVar $ replUpload s
  pure
    AgentXFTPServerStatsData
      { -- _fromTime,
        _replUpload,
        _replUploadRetries,
        _replUploadSuccesses,
        _replUploadErr,
        _replDownload,
        _replDownloadRetries,
        _replDownloadSuccesses,
        _replDownloadAuth,
        _replDownloadErr,
        _replDelete,
        _replDeleteRetries,
        _replDeleteSuccesses,
        _replDeleteErr
      }

setAgentXFTPServerStats :: AgentXFTPServerStats -> AgentXFTPServerStatsData -> STM ()
setAgentXFTPServerStats s d = do
  -- s@AgentXFTPServerStats {fromTime} d@AgentXFTPServerStatsData {_fromTime} = do
  -- writeTVar fromTime $! _fromTime
  writeTVar (replUpload s) $! _replUpload d
  writeTVar (replUploadRetries s) $! _replUploadRetries d
  writeTVar (replUploadSuccesses s) $! _replUploadSuccesses d
  writeTVar (replUploadErr s) $! _replUploadErr d
  writeTVar (replDownload s) $! _replDownload d
  writeTVar (replDownloadRetries s) $! _replDownloadRetries d
  writeTVar (replDownloadSuccesses s) $! _replDownloadSuccesses d
  writeTVar (replDownloadAuth s) $! _replDownloadAuth d
  writeTVar (replDownloadErr s) $! _replDownloadErr d
  writeTVar (replDelete s) $! _replDelete d
  writeTVar (replDeleteRetries s) $! _replDeleteRetries d
  writeTVar (replDeleteSuccesses s) $! _replDeleteSuccesses d
  writeTVar (replDeleteErr s) $! _replDeleteErr d

-- Type for gathering both smp and xftp stats across all users and servers.
--
-- Idea is to provide agent with a single path to save/restore stats, instead of managing it in UI
-- and providing agent with "initial stats".
--
-- Agent would use this unifying type to write/read json representation of all stats
-- and populating AgentClient maps:
-- smpServersStats :: TMap (UserId, SMPServer) AgentSMPServerStats,
-- xftpServersStats :: TMap (UserId, XFTPServer) AgentXFTPServerStats
data AgentPersistedServerStats = AgentPersistedServerStats
  { smpServersStatsData :: Map (UserId, SMPServer) AgentSMPServerStatsData,
    xftpServersStatsData :: Map (UserId, XFTPServer) AgentXFTPServerStatsData
  }
  deriving (Show)

$(J.deriveJSON defaultJSON ''AgentSMPServerStatsData)

$(J.deriveJSON defaultJSON ''AgentXFTPServerStatsData)

$(J.deriveJSON defaultJSON ''AgentPersistedServerStats)
