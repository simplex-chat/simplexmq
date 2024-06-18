{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.Agent.Stats where

import qualified Data.Aeson.TH as J
import Data.Map (Map)
import Database.SQLite.Simple.FromField (FromField (..))
import Database.SQLite.Simple.ToField (ToField (..))
import Simplex.Messaging.Agent.Protocol (UserId)
import Simplex.Messaging.Parsers (defaultJSON, fromTextField_)
import Simplex.Messaging.Protocol (SMPServer, XFTPServer)
import Simplex.Messaging.Util (decodeJSON, encodeJSON)
import UnliftIO.STM

data AgentSMPServerStats = AgentSMPServerStats
  { sentDirect :: TVar Int, -- successfully sent messages
    sentViaProxy :: TVar Int, -- successfully sent messages via proxy
    sentDirectAttempts :: TVar Int, -- direct sending attempts (min 1 for each sent message)
    sentViaProxyAttempts :: TVar Int, -- proxy sending attempts
    sentAuthErrs :: TVar Int, -- send AUTH errors
    sentQuotaErrs :: TVar Int, -- send QUOTA permanent errors (message expired)
    sentExpiredErrs :: TVar Int, -- send expired errors
    sentOtherErrs :: TVar Int, -- other send permanent errors (excluding above)
    -- sentDirectErrs :: TVar Int, -- other direct send permanent errors (excluding above)
    -- sentProxyErrs :: TVar Int, -- other proxy send permanent errors (excluding above)
    recvMsgs :: TVar Int, -- total messages received
    recvDuplicates :: TVar Int, -- duplicate messages received
    recvCryptoErrs :: TVar Int, -- message decryption errors
    recvErrs :: TVar Int, -- receive errors
    connCreated :: TVar Int,
    connSecured :: TVar Int,
    connCompleted :: TVar Int, -- ? unclear what this means in context of server (rcv/snd)
    connDeleted :: TVar Int, -- ? queue deleted?
    connSubscribed :: TVar Int, -- total successful subscription
    connSubAttempts :: TVar Int, -- subscription attempts
    connSubErrs :: TVar Int -- permanent subscription errors (temporary accounted for in attempts)
  }

data AgentSMPServerStatsData = AgentSMPServerStatsData
  { _sentDirect :: Int,
    _sentViaProxy :: Int,
    _sentDirectAttempts :: Int,
    _sentViaProxyAttempts :: Int,
    _sentAuthErrs :: Int,
    _sentQuotaErrs :: Int,
    _sentExpiredErrs :: Int,
    _sentOtherErrs :: Int,
    -- _sentDirectErrs :: Int,
    -- _sentProxyErrs :: Int,
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
  sentOtherErrs <- newTVar 0
  -- sentDirectErrs <- newTVar 0
  -- sentProxyErrs <- newTVar 0
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
        sentOtherErrs,
        -- sentDirectErrs,
        -- sentProxyErrs,
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
  sentViaProxy <- newTVar $ _sentViaProxy s
  sentDirectAttempts <- newTVar $ _sentDirectAttempts s
  sentViaProxyAttempts <- newTVar $ _sentViaProxyAttempts s
  sentAuthErrs <- newTVar $ _sentAuthErrs s
  sentQuotaErrs <- newTVar $ _sentQuotaErrs s
  sentExpiredErrs <- newTVar $ _sentExpiredErrs s
  sentOtherErrs <- newTVar $ _sentOtherErrs s
  -- sentDirectErrs <- newTVar $ _sentDirectErrs s
  -- sentProxyErrs <- newTVar $ _sentProxyErrs s
  recvMsgs <- newTVar $ _recvMsgs s
  recvDuplicates <- newTVar $ _recvDuplicates s
  recvCryptoErrs <- newTVar $ _recvCryptoErrs s
  recvErrs <- newTVar $ _recvErrs s
  connCreated <- newTVar $ _connCreated s
  connSecured <- newTVar $ _connSecured s
  connCompleted <- newTVar $ _connCompleted s
  connDeleted <- newTVar $ _connDeleted s
  connSubscribed <- newTVar $ _connSubscribed s
  connSubAttempts <- newTVar $ _connSubAttempts s
  connSubErrs <- newTVar $ _connSubErrs s
  pure
    AgentSMPServerStats
      { sentDirect,
        sentViaProxy,
        sentDirectAttempts,
        sentViaProxyAttempts,
        sentAuthErrs,
        sentQuotaErrs,
        sentExpiredErrs,
        sentOtherErrs,
        -- sentDirectErrs,
        -- sentProxyErrs,
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
  _sentViaProxy <- readTVar $ sentViaProxy s
  _sentDirectAttempts <- readTVar $ sentDirectAttempts s
  _sentViaProxyAttempts <- readTVar $ sentViaProxyAttempts s
  _sentAuthErrs <- readTVar $ sentAuthErrs s
  _sentQuotaErrs <- readTVar $ sentQuotaErrs s
  _sentExpiredErrs <- readTVar $ sentExpiredErrs s
  _sentOtherErrs <- readTVar $ sentOtherErrs s
  -- _sentDirectErrs <- readTVar $ sentDirectErrs s
  -- _sentProxyErrs <- readTVar $ sentProxyErrs s
  _recvMsgs <- readTVar $ recvMsgs s
  _recvDuplicates <- readTVar $ recvDuplicates s
  _recvCryptoErrs <- readTVar $ recvCryptoErrs s
  _recvErrs <- readTVar $ recvErrs s
  _connCreated <- readTVar $ connCreated s
  _connSecured <- readTVar $ connSecured s
  _connCompleted <- readTVar $ connCompleted s
  _connDeleted <- readTVar $ connDeleted s
  _connSubscribed <- readTVar $ connSubscribed s
  _connSubAttempts <- readTVar $ connSubAttempts s
  _connSubErrs <- readTVar $ connSubErrs s
  pure
    AgentSMPServerStatsData
      { _sentDirect,
        _sentViaProxy,
        _sentDirectAttempts,
        _sentViaProxyAttempts,
        _sentAuthErrs,
        _sentQuotaErrs,
        _sentExpiredErrs,
        _sentOtherErrs,
        -- _sentDirectErrs,
        -- _sentProxyErrs,
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
  writeTVar (sentOtherErrs s) $! _sentOtherErrs d
  -- writeTVar (sentDirectErrs s) $! _sentDirectErrs d
  -- writeTVar (sentProxyErrs s) $! _sentProxyErrs d
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
  { replUpload :: TVar Int, -- total replicas uploaded to server
    replUploadAttempts :: TVar Int, -- upload attempts
    replUploadErr :: TVar Int, -- upload errors
    replDownload :: TVar Int, -- total replicas downloaded from server
    replDownloadAttempts :: TVar Int, -- download attempts
    replDownloadAuth :: TVar Int, -- download AUTH errors
    replDownloadErr :: TVar Int, -- other download errors (excluding above)
    replDelete :: TVar Int, -- total replicas deleted from server
    replDeleteAttempts :: TVar Int, -- delete attempts
    replDeleteErr :: TVar Int -- delete errors
  }

data AgentXFTPServerStatsData = AgentXFTPServerStatsData
  { _replUpload :: Int,
    _replUploadAttempts :: Int,
    _replUploadErr :: Int,
    _replDownload :: Int,
    _replDownloadAttempts :: Int,
    _replDownloadAuth :: Int,
    _replDownloadErr :: Int,
    _replDelete :: Int,
    _replDeleteAttempts :: Int,
    _replDeleteErr :: Int
  }
  deriving (Show)

newAgentXFTPServerStats :: STM AgentXFTPServerStats
newAgentXFTPServerStats = do
  replUpload <- newTVar 0
  replUploadAttempts <- newTVar 0
  replUploadErr <- newTVar 0
  replDownload <- newTVar 0
  replDownloadAttempts <- newTVar 0
  replDownloadAuth <- newTVar 0
  replDownloadErr <- newTVar 0
  replDelete <- newTVar 0
  replDeleteAttempts <- newTVar 0
  replDeleteErr <- newTVar 0
  pure
    AgentXFTPServerStats
      { replUpload,
        replUploadAttempts,
        replUploadErr,
        replDownload,
        replDownloadAttempts,
        replDownloadAuth,
        replDownloadErr,
        replDelete,
        replDeleteAttempts,
        replDeleteErr
      }

newAgentXFTPServerStats' :: AgentXFTPServerStatsData -> STM AgentXFTPServerStats
newAgentXFTPServerStats' s = do
  replUpload <- newTVar $ _replUpload s
  replUploadAttempts <- newTVar $ _replUploadAttempts s
  replUploadErr <- newTVar $ _replUploadErr s
  replDownload <- newTVar $ _replDownload s
  replDownloadAttempts <- newTVar $ _replDownloadAttempts s
  replDownloadAuth <- newTVar $ _replDownloadAuth s
  replDownloadErr <- newTVar $ _replDownloadErr s
  replDelete <- newTVar $ _replDelete s
  replDeleteAttempts <- newTVar $ _replDeleteAttempts s
  replDeleteErr <- newTVar $ _replDeleteErr s
  pure
    AgentXFTPServerStats
      { replUpload,
        replUploadAttempts,
        replUploadErr,
        replDownload,
        replDownloadAttempts,
        replDownloadAuth,
        replDownloadErr,
        replDelete,
        replDeleteAttempts,
        replDeleteErr
      }

getAgentXFTPServerStats :: AgentXFTPServerStats -> STM AgentXFTPServerStatsData
getAgentXFTPServerStats s = do
  _replUpload <- readTVar $ replUpload s
  _replUploadAttempts <- readTVar $ replUploadAttempts s
  _replUploadErr <- readTVar $ replUploadErr s
  _replDownload <- readTVar $ replDownload s
  _replDownloadAttempts <- readTVar $ replDownloadAttempts s
  _replDownloadAuth <- readTVar $ replDownloadAuth s
  _replDownloadErr <- readTVar $ replDownloadErr s
  _replDelete <- readTVar $ replDelete s
  _replDeleteAttempts <- readTVar $ replDeleteAttempts s
  _replDeleteErr <- readTVar $ replDeleteErr s
  pure
    AgentXFTPServerStatsData
      { _replUpload,
        _replUploadAttempts,
        _replUploadErr,
        _replDownload,
        _replDownloadAttempts,
        _replDownloadAuth,
        _replDownloadErr,
        _replDelete,
        _replDeleteAttempts,
        _replDeleteErr
      }

setAgentXFTPServerStats :: AgentXFTPServerStats -> AgentXFTPServerStatsData -> STM ()
setAgentXFTPServerStats s d = do
  writeTVar (replUpload s) $! _replUpload d
  writeTVar (replUploadAttempts s) $! _replUploadAttempts d
  writeTVar (replUploadErr s) $! _replUploadErr d
  writeTVar (replDownload s) $! _replDownload d
  writeTVar (replDownloadAttempts s) $! _replDownloadAttempts d
  writeTVar (replDownloadAuth s) $! _replDownloadAuth d
  writeTVar (replDownloadErr s) $! _replDownloadErr d
  writeTVar (replDelete s) $! _replDelete d
  writeTVar (replDeleteAttempts s) $! _replDeleteAttempts d
  writeTVar (replDeleteErr s) $! _replDeleteErr d

-- Type for gathering both smp and xftp stats across all users and servers,
-- to then be persisted to db as a single json.
data AgentPersistedServerStats = AgentPersistedServerStats
  { smpServersStatsData :: Map (UserId, SMPServer) AgentSMPServerStatsData,
    xftpServersStatsData :: Map (UserId, XFTPServer) AgentXFTPServerStatsData
  }
  deriving (Show)

$(J.deriveJSON defaultJSON ''AgentSMPServerStatsData)

$(J.deriveJSON defaultJSON ''AgentXFTPServerStatsData)

$(J.deriveJSON defaultJSON ''AgentPersistedServerStats)

instance ToField AgentPersistedServerStats where
  toField = toField . encodeJSON

instance FromField AgentPersistedServerStats where
  fromField = fromTextField_ decodeJSON
