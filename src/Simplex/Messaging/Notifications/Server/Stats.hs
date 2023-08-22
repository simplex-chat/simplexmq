{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedRecordDot #-}
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
getNtfServerStatsData s = do
  _fromTime <- readTVar s.fromTime
  _tknCreated <- readTVar s.tknCreated
  _tknVerified <- readTVar s.tknVerified
  _tknDeleted <- readTVar s.tknDeleted
  _subCreated <- readTVar s.subCreated
  _subDeleted <- readTVar s.subDeleted
  _ntfReceived <- readTVar s.ntfReceived
  _ntfDelivered <- readTVar s.ntfDelivered
  _activeTokens <- getPeriodStatsData s.activeTokens
  _activeSubs <- getPeriodStatsData s.activeSubs
  pure NtfServerStatsData {_fromTime, _tknCreated, _tknVerified, _tknDeleted, _subCreated, _subDeleted, _ntfReceived, _ntfDelivered, _activeTokens, _activeSubs}

setNtfServerStats :: NtfServerStats -> NtfServerStatsData -> STM ()
setNtfServerStats s d = do
  writeTVar s.fromTime $! d._fromTime
  writeTVar s.tknCreated $! _tknCreated d
  writeTVar s.tknVerified $! _tknVerified d
  writeTVar s.tknDeleted $! _tknDeleted d
  writeTVar s.subCreated $! _subCreated d
  writeTVar s.subDeleted $! _subDeleted d
  writeTVar s.ntfReceived $! _ntfReceived d
  writeTVar s.ntfDelivered $! _ntfDelivered d
  setPeriodStats s.activeTokens (_activeTokens d)
  setPeriodStats s.activeSubs (_activeSubs d)

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
