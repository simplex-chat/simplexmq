{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Server.Stats where

import Control.Applicative (optional)
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import Data.IORef
import Data.Time.Clock (UTCTime)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol (NtfTokenId)
import Simplex.Messaging.Protocol (NotifierId)
import Simplex.Messaging.Server.Stats

data NtfServerStats = NtfServerStats
  { fromTime :: IORef UTCTime,
    tknCreated :: IORef Int,
    tknVerified :: IORef Int,
    tknDeleted :: IORef Int,
    subCreated :: IORef Int,
    subDeleted :: IORef Int,
    ntfReceived :: IORef Int,
    ntfDelivered :: IORef Int,
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

newNtfServerStats :: UTCTime -> IO NtfServerStats
newNtfServerStats ts = do
  fromTime <- newIORef ts
  tknCreated <- newIORef 0
  tknVerified <- newIORef 0
  tknDeleted <- newIORef 0
  subCreated <- newIORef 0
  subDeleted <- newIORef 0
  ntfReceived <- newIORef 0
  ntfDelivered <- newIORef 0
  activeTokens <- newPeriodStats
  activeSubs <- newPeriodStats
  pure NtfServerStats {fromTime, tknCreated, tknVerified, tknDeleted, subCreated, subDeleted, ntfReceived, ntfDelivered, activeTokens, activeSubs}

getNtfServerStatsData :: NtfServerStats -> IO NtfServerStatsData
getNtfServerStatsData s@NtfServerStats {fromTime} = do
  _fromTime <- readIORef fromTime
  _tknCreated <- readIORef $ tknCreated s
  _tknVerified <- readIORef $ tknVerified s
  _tknDeleted <- readIORef $ tknDeleted s
  _subCreated <- readIORef $ subCreated s
  _subDeleted <- readIORef $ subDeleted s
  _ntfReceived <- readIORef $ ntfReceived s
  _ntfDelivered <- readIORef $ ntfDelivered s
  _activeTokens <- getPeriodStatsData $ activeTokens s
  _activeSubs <- getPeriodStatsData $ activeSubs s
  pure NtfServerStatsData {_fromTime, _tknCreated, _tknVerified, _tknDeleted, _subCreated, _subDeleted, _ntfReceived, _ntfDelivered, _activeTokens, _activeSubs}

-- this function is not thread safe, it is used on server start only
setNtfServerStats :: NtfServerStats -> NtfServerStatsData -> IO ()
setNtfServerStats s@NtfServerStats {fromTime} d@NtfServerStatsData {_fromTime} = do
  writeIORef fromTime $! _fromTime
  writeIORef (tknCreated s) $! _tknCreated d
  writeIORef (tknVerified s) $! _tknVerified d
  writeIORef (tknDeleted s) $! _tknDeleted d
  writeIORef (subCreated s) $! _subCreated d
  writeIORef (subDeleted s) $! _subDeleted d
  writeIORef (ntfReceived s) $! _ntfReceived d
  writeIORef (ntfDelivered s) $! _ntfDelivered d
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
