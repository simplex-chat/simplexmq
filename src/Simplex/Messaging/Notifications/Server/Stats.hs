{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Server.Stats where

import Control.Applicative (optional, (<|>))
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import Data.IORef
import Data.Time.Clock (UTCTime)
import Simplex.Messaging.Encoding.String
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
    ntfFailed :: IORef Int,
    ntfCronDelivered :: IORef Int,
    ntfCronFailed :: IORef Int,
    ntfVrfDelivered :: IORef Int,
    ntfVrfFailed :: IORef Int,
    ntfVrfInvalidTkn :: IORef Int,
    activeTokens :: PeriodStats,
    activeSubs :: PeriodStats
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
    _ntfFailed :: Int,
    _ntfCronDelivered :: Int,
    _ntfCronFailed :: Int,
    _ntfVrfDelivered :: Int,
    _ntfVrfFailed :: Int,
    _ntfVrfInvalidTkn :: Int,
    _activeTokens :: PeriodStatsData,
    _activeSubs :: PeriodStatsData
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
  ntfFailed <- newIORef 0
  ntfCronDelivered <- newIORef 0
  ntfCronFailed <- newIORef 0
  ntfVrfDelivered <- newIORef 0
  ntfVrfFailed <- newIORef 0
  ntfVrfInvalidTkn <- newIORef 0
  activeTokens <- newPeriodStats
  activeSubs <- newPeriodStats
  pure
    NtfServerStats
      { fromTime,
        tknCreated,
        tknVerified,
        tknDeleted,
        subCreated,
        subDeleted,
        ntfReceived,
        ntfDelivered,
        ntfFailed,
        ntfCronDelivered,
        ntfCronFailed,
        ntfVrfDelivered,
        ntfVrfFailed,
        ntfVrfInvalidTkn,
        activeTokens,
        activeSubs
      }

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
  _ntfFailed <- readIORef $ ntfFailed s
  _ntfCronDelivered <- readIORef $ ntfCronDelivered s
  _ntfCronFailed <- readIORef $ ntfCronFailed s
  _ntfVrfDelivered <- readIORef $ ntfVrfDelivered s
  _ntfVrfFailed <- readIORef $ ntfVrfFailed s
  _ntfVrfInvalidTkn <- readIORef $ ntfVrfInvalidTkn s
  _activeTokens <- getPeriodStatsData $ activeTokens s
  _activeSubs <- getPeriodStatsData $ activeSubs s
  pure
    NtfServerStatsData
      { _fromTime,
        _tknCreated,
        _tknVerified,
        _tknDeleted,
        _subCreated,
        _subDeleted,
        _ntfReceived,
        _ntfDelivered,
        _ntfFailed,
        _ntfCronDelivered,
        _ntfCronFailed,
        _ntfVrfDelivered,
        _ntfVrfFailed,
        _ntfVrfInvalidTkn,
        _activeTokens,
        _activeSubs
      }

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
  writeIORef (ntfFailed s) $! _ntfFailed d
  writeIORef (ntfCronDelivered s) $! _ntfCronDelivered d
  writeIORef (ntfCronFailed s) $! _ntfCronFailed d
  writeIORef (ntfVrfDelivered s) $! _ntfVrfDelivered d
  writeIORef (ntfVrfFailed s) $! _ntfVrfFailed d
  writeIORef (ntfVrfInvalidTkn s) $! _ntfVrfInvalidTkn d
  setPeriodStats (activeTokens s) (_activeTokens d)
  setPeriodStats (activeSubs s) (_activeSubs d)

instance StrEncoding NtfServerStatsData where
  strEncode
    NtfServerStatsData
      { _fromTime,
        _tknCreated,
        _tknVerified,
        _tknDeleted,
        _subCreated,
        _subDeleted,
        _ntfReceived,
        _ntfDelivered,
        _ntfFailed,
        _ntfCronDelivered,
        _ntfCronFailed,
        _ntfVrfDelivered,
        _ntfVrfFailed,
        _ntfVrfInvalidTkn,
        _activeTokens,
        _activeSubs
      } =
    B.unlines
      [ "fromTime=" <> strEncode _fromTime,
        "tknCreated=" <> strEncode _tknCreated,
        "tknVerified=" <> strEncode _tknVerified,
        "tknDeleted=" <> strEncode _tknDeleted,
        "subCreated=" <> strEncode _subCreated,
        "subDeleted=" <> strEncode _subDeleted,
        "ntfReceived=" <> strEncode _ntfReceived,
        "ntfDelivered=" <> strEncode _ntfDelivered,
        "ntfFailed=" <> strEncode _ntfFailed,
        "ntfCronDelivered=" <> strEncode _ntfCronDelivered,
        "ntfCronFailed=" <> strEncode _ntfCronFailed,
        "ntfVrfDelivered=" <> strEncode _ntfVrfDelivered,
        "ntfVrfFailed=" <> strEncode _ntfVrfFailed,
        "ntfVrfInvalidTkn=" <> strEncode _ntfVrfInvalidTkn,
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
    _ntfFailed <- opt "ntfFailed="
    _ntfCronDelivered <- opt "ntfCronDelivered="
    _ntfCronFailed <- opt "ntfCronFailed="
    _ntfVrfDelivered <- opt "ntfVrfDelivered="
    _ntfVrfFailed <- opt "ntfVrfFailed="
    _ntfVrfInvalidTkn <- opt "ntfVrfInvalidTkn="
    _ <- "activeTokens:" <* A.endOfLine
    _activeTokens <- strP <* A.endOfLine
    _ <- "activeSubs:" <* A.endOfLine
    _activeSubs <- strP <* optional A.endOfLine
    pure
      NtfServerStatsData
        { _fromTime,
          _tknCreated,
          _tknVerified,
          _tknDeleted,
          _subCreated,
          _subDeleted,
          _ntfReceived,
          _ntfDelivered,
          _ntfFailed,
          _ntfCronDelivered,
          _ntfCronFailed,
          _ntfVrfDelivered,
          _ntfVrfFailed,
          _ntfVrfInvalidTkn,
          _activeTokens,
          _activeSubs
        }
    where
      opt s = A.string s *> strP <* A.endOfLine <|> pure 0
