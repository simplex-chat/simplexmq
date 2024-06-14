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
  { fromTime :: TVar UTCTime,
    msgSent :: TVar Int, -- total messages sent to server directly
    msgSentRetries :: TVar Int, -- sending retries
    msgSentSuccesses :: TVar Int, -- successful sends
    msgSentAuth :: TVar Int, -- send AUTH errors
    msgSentQuota :: TVar Int, -- send QUOTA errors
    msgSentExpired :: TVar Int, -- send expired errors
    msgSentErr :: TVar Int, -- other send errors (excluding above)
    msgProx :: TVar Int, -- total messages sent to proxy server for forwarding
    msgProxRetries :: TVar Int, -- proxy sending retries
    msgProxSuccesses :: TVar Int, -- successful proxy sends
    msgProxExpired :: TVar Int, -- proxy send expired errors
    msgProxAuth :: TVar Int, -- proxy send AUTH errors (AUTH error at destination relay)
    msgProxQuota :: TVar Int, -- proxy send QUOTA errors (QUOTA error at destination relay)
    msgProxErr :: TVar Int, -- other proxy send errors (excluding above)
    msgRecv :: TVar Int, -- total messages received
    msgRecvDuplicate :: TVar Int, -- duplicate messages received
    msgRecvErr :: TVar Int, -- receive errors
    sub :: TVar Int, -- total subscriptions
    subRetries :: TVar Int, -- subscription retries
    subErr :: TVar Int -- subscription errors
  }

data AgentSMPServerStatsData = AgentSMPServerStatsData
  { _fromTime :: UTCTime,
    _msgSent :: Int,
    _msgSentRetries :: Int,
    _msgSentSuccesses :: Int,
    _msgSentAuth :: Int,
    _msgSentQuota :: Int,
    _msgSentExpired :: Int,
    _msgSentErr :: Int,
    _msgProx :: Int,
    _msgProxRetries :: Int,
    _msgProxSuccesses :: Int,
    _msgProxExpired :: Int,
    _msgProxAuth :: Int,
    _msgProxQuota :: Int,
    _msgProxErr :: Int,
    _msgRecv :: Int,
    _msgRecvDuplicate :: Int,
    _msgRecvErr :: Int,
    _sub :: Int,
    _subRetries :: Int,
    _subErr :: Int
  }
  deriving (Show)

newAgentSMPServerStats :: UTCTime -> STM AgentSMPServerStats
newAgentSMPServerStats ts = do
  fromTime <- newTVar ts
  msgSent <- newTVar 0
  msgSentRetries <- newTVar 0
  msgSentSuccesses <- newTVar 0
  msgSentAuth <- newTVar 0
  msgSentQuota <- newTVar 0
  msgSentExpired <- newTVar 0
  msgSentErr <- newTVar 0
  msgProx <- newTVar 0
  msgProxRetries <- newTVar 0
  msgProxSuccesses <- newTVar 0
  msgProxExpired <- newTVar 0
  msgProxAuth <- newTVar 0
  msgProxQuota <- newTVar 0
  msgProxErr <- newTVar 0
  msgRecv <- newTVar 0
  msgRecvDuplicate <- newTVar 0
  msgRecvErr <- newTVar 0
  sub <- newTVar 0
  subRetries <- newTVar 0
  subErr <- newTVar 0
  pure
    AgentSMPServerStats
      { fromTime,
        msgSent,
        msgSentRetries,
        msgSentSuccesses,
        msgSentAuth,
        msgSentQuota,
        msgSentExpired,
        msgSentErr,
        msgProx,
        msgProxRetries,
        msgProxSuccesses,
        msgProxExpired,
        msgProxAuth,
        msgProxQuota,
        msgProxErr,
        msgRecv,
        msgRecvDuplicate,
        msgRecvErr,
        sub,
        subRetries,
        subErr
      }

newAgentSMPServerStats' :: AgentSMPServerStatsData -> STM AgentSMPServerStats
newAgentSMPServerStats' s@AgentSMPServerStatsData {_fromTime} = do
  fromTime <- newTVar _fromTime
  msgSent <- newTVar $ _msgSent s
  msgSentRetries <- newTVar $ _msgSentRetries s
  msgSentSuccesses <- newTVar $ _msgSentSuccesses s
  msgSentAuth <- newTVar $ _msgSentAuth s
  msgSentQuota <- newTVar $ _msgSentQuota s
  msgSentExpired <- newTVar $ _msgSentExpired s
  msgSentErr <- newTVar $ _msgSentErr s
  msgProx <- newTVar $ _msgProx s
  msgProxRetries <- newTVar $ _msgProxRetries s
  msgProxSuccesses <- newTVar $ _msgProxSuccesses s
  msgProxExpired <- newTVar $ _msgProxExpired s
  msgProxAuth <- newTVar $ _msgProxAuth s
  msgProxQuota <- newTVar $ _msgProxQuota s
  msgProxErr <- newTVar $ _msgProxErr s
  msgRecv <- newTVar $ _msgRecv s
  msgRecvDuplicate <- newTVar $ _msgRecvDuplicate s
  msgRecvErr <- newTVar $ _msgRecvErr s
  sub <- newTVar $ _sub s
  subRetries <- newTVar $ _subRetries s
  subErr <- newTVar $ _subErr s
  pure
    AgentSMPServerStats
      { fromTime,
        msgSent,
        msgSentRetries,
        msgSentSuccesses,
        msgSentAuth,
        msgSentQuota,
        msgSentExpired,
        msgSentErr,
        msgProx,
        msgProxRetries,
        msgProxSuccesses,
        msgProxExpired,
        msgProxAuth,
        msgProxQuota,
        msgProxErr,
        msgRecv,
        msgRecvDuplicate,
        msgRecvErr,
        sub,
        subRetries,
        subErr
      }

getAgentSMPServerStats :: AgentSMPServerStats -> STM AgentSMPServerStatsData
getAgentSMPServerStats s@AgentSMPServerStats {fromTime} = do
  _fromTime <- readTVar fromTime
  _msgSent <- readTVar $ msgSent s
  _msgSentRetries <- readTVar $ msgSentRetries s
  _msgSentSuccesses <- readTVar $ msgSentSuccesses s
  _msgSentAuth <- readTVar $ msgSentAuth s
  _msgSentQuota <- readTVar $ msgSentQuota s
  _msgSentExpired <- readTVar $ msgSentExpired s
  _msgSentErr <- readTVar $ msgSentErr s
  _msgProx <- readTVar $ msgProx s
  _msgProxRetries <- readTVar $ msgProxRetries s
  _msgProxSuccesses <- readTVar $ msgProxSuccesses s
  _msgProxExpired <- readTVar $ msgProxExpired s
  _msgProxAuth <- readTVar $ msgProxAuth s
  _msgProxQuota <- readTVar $ msgProxQuota s
  _msgProxErr <- readTVar $ msgProxErr s
  _msgRecv <- readTVar $ msgRecv s
  _msgRecvDuplicate <- readTVar $ msgRecvDuplicate s
  _msgRecvErr <- readTVar $ msgRecvErr s
  _sub <- readTVar $ sub s
  _subRetries <- readTVar $ subRetries s
  _subErr <- readTVar $ subErr s
  pure
    AgentSMPServerStatsData
      { _fromTime,
        _msgSent,
        _msgSentRetries,
        _msgSentSuccesses,
        _msgSentAuth,
        _msgSentQuota,
        _msgSentExpired,
        _msgSentErr,
        _msgProx,
        _msgProxRetries,
        _msgProxSuccesses,
        _msgProxExpired,
        _msgProxAuth,
        _msgProxQuota,
        _msgProxErr,
        _msgRecv,
        _msgRecvDuplicate,
        _msgRecvErr,
        _sub,
        _subRetries,
        _subErr
      }

setAgentSMPServerStats :: AgentSMPServerStats -> AgentSMPServerStatsData -> STM ()
setAgentSMPServerStats s@AgentSMPServerStats {fromTime} d@AgentSMPServerStatsData {_fromTime} = do
  writeTVar fromTime $! _fromTime
  writeTVar (msgSent s) $! _msgSent d
  writeTVar (msgSentRetries s) $! _msgSentRetries d
  writeTVar (msgSentSuccesses s) $! _msgSentSuccesses d
  writeTVar (msgSentAuth s) $! _msgSentAuth d
  writeTVar (msgSentQuota s) $! _msgSentQuota d
  writeTVar (msgSentExpired s) $! _msgSentExpired d
  writeTVar (msgSentErr s) $! _msgSentErr d
  writeTVar (msgProx s) $! _msgProx d
  writeTVar (msgProxRetries s) $! _msgProxRetries d
  writeTVar (msgProxSuccesses s) $! _msgProxSuccesses d
  writeTVar (msgProxErr s) $! _msgProxErr d
  writeTVar (msgRecv s) $! _msgRecv d
  writeTVar (msgRecvDuplicate s) $! _msgRecvDuplicate d
  writeTVar (msgRecvErr s) $! _msgRecvErr d
  writeTVar (sub s) $! _sub d
  writeTVar (subRetries s) $! _subRetries d
  writeTVar (subErr s) $! _subErr d

data AgentXFTPServerStats = AgentXFTPServerStats
  { fromTime :: TVar UTCTime,
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
  { _fromTime :: UTCTime,
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

newAgentXFTPServerStats :: UTCTime -> STM AgentXFTPServerStats
newAgentXFTPServerStats ts = do
  fromTime <- newTVar ts
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
      { fromTime,
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
newAgentXFTPServerStats' s@AgentXFTPServerStatsData {_fromTime} = do
  fromTime <- newTVar _fromTime
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
      { fromTime,
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
getAgentXFTPServerStats s@AgentXFTPServerStats {fromTime} = do
  _fromTime <- readTVar fromTime
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
      { _fromTime,
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
setAgentXFTPServerStats s@AgentXFTPServerStats {fromTime} d@AgentXFTPServerStatsData {_fromTime} = do
  writeTVar fromTime $! _fromTime
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
