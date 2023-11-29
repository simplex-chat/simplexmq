{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Server.Stats where

import Control.Applicative (optional)
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import Data.Time.Clock (UTCTime)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol (NtfTokenId)
import Simplex.Messaging.Protocol (NotifierId)
import Simplex.Messaging.Server.Stats
import UnliftIO.STM

data NtfServerStats = NtfServerStats
  { fromTime :: TVar UTCTime,
    tknCreated :: TVar Int,
    tknVerified :: TVar Int,
    tknDeleted :: TVar Int,
    subCreated :: TVar Int,
    subDeleted :: TVar Int,
    ntfReceived :: TVar Int,
    ntfDelivered :: TVar Int,
    activeTokens :: PeriodStats NtfTokenId,
    activeSubs :: PeriodStats NotifierId
  }

data NtfServerStatsData = NtfServerStatsData
  { _fromTime :: UTCTime,
    _tknCreated :: Int,
    _tknVerified :: Int,
    _tknDeleted :: Int,
    _subCreated :: Int,
    _subDeleted :: Int,
    _ntfReceived :: Int,
    _ntfDelivered :: Int,
    _activeTokens :: PeriodStatsData NtfTokenId,
    _activeSubs :: PeriodStatsData NotifierId
  }

newNtfServerStats :: UTCTime -> STM NtfServerStats
newNtfServerStats ts = do
  fromTime <- newTVar ts
  tknCreated <- newTVar 0
  tknVerified <- newTVar 0
  tknDeleted <- newTVar 0
  subCreated <- newTVar 0
  subDeleted <- newTVar 0
  ntfReceived <- newTVar 0
  ntfDelivered <- newTVar 0
  activeTokens <- newPeriodStats
  activeSubs <- newPeriodStats
  pure NtfServerStats {fromTime, tknCreated, tknVerified, tknDeleted, subCreated, subDeleted, ntfReceived, ntfDelivered, activeTokens, activeSubs}

getNtfServerStatsData :: NtfServerStats -> STM NtfServerStatsData
getNtfServerStatsData s@NtfServerStats {fromTime} = do
  _fromTime <- readTVar fromTime
  _tknCreated <- readTVar $ tknCreated s
  _tknVerified <- readTVar $ tknVerified s
  _tknDeleted <- readTVar $ tknDeleted s
  _subCreated <- readTVar $ subCreated s
  _subDeleted <- readTVar $ subDeleted s
  _ntfReceived <- readTVar $ ntfReceived s
  _ntfDelivered <- readTVar $ ntfDelivered s
  _activeTokens <- getPeriodStatsData $ activeTokens s
  _activeSubs <- getPeriodStatsData $ activeSubs s
  pure NtfServerStatsData {_fromTime, _tknCreated, _tknVerified, _tknDeleted, _subCreated, _subDeleted, _ntfReceived, _ntfDelivered, _activeTokens, _activeSubs}

setNtfServerStats :: NtfServerStats -> NtfServerStatsData -> STM ()
setNtfServerStats s@NtfServerStats {fromTime} d@NtfServerStatsData {_fromTime} = do
  writeTVar fromTime $! _fromTime
  writeTVar (tknCreated s) $! _tknCreated d
  writeTVar (tknVerified s) $! _tknVerified d
  writeTVar (tknDeleted s) $! _tknDeleted d
  writeTVar (subCreated s) $! _subCreated d
  writeTVar (subDeleted s) $! _subDeleted d
  writeTVar (ntfReceived s) $! _ntfReceived d
  writeTVar (ntfDelivered s) $! _ntfDelivered d
  setPeriodStats (activeTokens s) (_activeTokens d)
  setPeriodStats (activeSubs s) (_activeSubs d)

instance StrEncoding NtfServerStatsData where
  strEncode NtfServerStatsData {_fromTime, _tknCreated, _tknVerified, _tknDeleted, _subCreated, _subDeleted, _ntfReceived, _ntfDelivered, _activeTokens, _activeSubs} =
    B.unlines
      [ "fromTime=" <> strEncode _fromTime,
        "tknCreated=" <> strEncode _tknCreated,
        "tknVerified=" <> strEncode _tknVerified,
        "tknDeleted=" <> strEncode _tknDeleted,
        "subCreated=" <> strEncode _subCreated,
        "subDeleted=" <> strEncode _subDeleted,
        "ntfReceived=" <> strEncode _ntfReceived,
        "ntfDelivered=" <> strEncode _ntfDelivered,
        "activeTokens:",
        strEncode _activeTokens,
        "activeSubs:",
        strEncode _activeSubs
      ]
  strP = do
    _fromTime <- "fromTime=" *> strP <* A.endOfLine
    _tknCreated <- "tknCreated=" *> strP <* A.endOfLine
    _tknVerified <- "tknVerified=" *> strP <* A.endOfLine
    _tknDeleted <- "tknDeleted=" *> strP <* A.endOfLine
    _subCreated <- "subCreated=" *> strP <* A.endOfLine
    _subDeleted <- "subDeleted=" *> strP <* A.endOfLine
    _ntfReceived <- "ntfReceived=" *> strP <* A.endOfLine
    _ntfDelivered <- "ntfDelivered=" *> strP <* A.endOfLine
    _ <- "activeTokens:" <* A.endOfLine
    _activeTokens <- strP <* A.endOfLine
    _ <- "activeSubs:" <* A.endOfLine
    _activeSubs <- strP <* optional A.endOfLine
    pure NtfServerStatsData {_fromTime, _tknCreated, _tknVerified, _tknDeleted, _subCreated, _subDeleted, _ntfReceived, _ntfDelivered, _activeTokens, _activeSubs}
