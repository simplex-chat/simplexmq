{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Server.Stats where

import Control.Applicative (optional, (<|>))
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import Data.Set (Set)
import qualified Data.Set as S
import Data.Time.Calendar.Month (pattern MonthDay)
import Data.Time.Calendar.OrdinalDate (mondayStartWeek)
import Data.Time.Clock (UTCTime (..))
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (RecipientId)
import UnliftIO.STM

data ServerStats = ServerStats
  { fromTime :: TVar UTCTime,
    qCreated :: TVar Int,
    qSecured :: TVar Int,
    qDeletedAll :: TVar Int,
    qDeletedNew :: TVar Int,
    qDeletedSecured :: TVar Int,
    msgSent :: TVar Int,
    msgRecv :: TVar Int,
    msgExpired :: TVar Int,
    activeQueues :: PeriodStats RecipientId,
    msgSentNtf :: TVar Int,
    msgRecvNtf :: TVar Int,
    activeQueuesNtf :: PeriodStats RecipientId,
    qCount :: TVar Int,
    msgCount :: TVar Int,
    proxyRelaysRequested :: TVar Int,
    proxyRelaysConnected :: TVar Int,
    msgSentViaProxy :: TVar Int,
    msgDeliveredViaProxy :: TVar Int,
    msgDeliveredFromProxy :: TVar Int
  }

data ServerStatsData = ServerStatsData
  { _fromTime :: UTCTime,
    _qCreated :: Int,
    _qSecured :: Int,
    _qDeletedAll :: Int,
    _qDeletedNew :: Int,
    _qDeletedSecured :: Int,
    _msgSent :: Int,
    _msgRecv :: Int,
    _msgExpired :: Int,
    _activeQueues :: PeriodStatsData RecipientId,
    _msgSentNtf :: Int,
    _msgRecvNtf :: Int,
    _activeQueuesNtf :: PeriodStatsData RecipientId,
    _qCount :: Int,
    _msgCount :: Int,
    _proxyRelaysRequested :: Int,
    _proxyRelaysConnected :: Int,
    _msgSentViaProxy :: Int,
    _msgDeliveredViaProxy :: Int,
    _msgDeliveredFromProxy :: Int
  }
  deriving (Show)

newServerStats :: UTCTime -> STM ServerStats
newServerStats ts = do
  fromTime <- newTVar ts
  qCreated <- newTVar 0
  qSecured <- newTVar 0
  qDeletedAll <- newTVar 0
  qDeletedNew <- newTVar 0
  qDeletedSecured <- newTVar 0
  msgSent <- newTVar 0
  msgRecv <- newTVar 0
  msgExpired <- newTVar 0
  activeQueues <- newPeriodStats
  msgSentNtf <- newTVar 0
  msgRecvNtf <- newTVar 0
  activeQueuesNtf <- newPeriodStats
  qCount <- newTVar 0
  msgCount <- newTVar 0
  proxyRelaysRequested <- newTVar 0
  proxyRelaysConnected <- newTVar 0
  msgSentViaProxy <- newTVar 0
  msgDeliveredViaProxy <- newTVar 0
  msgDeliveredFromProxy <- newTVar 0
  pure ServerStats {fromTime, qCreated, qSecured, qDeletedAll, qDeletedNew, qDeletedSecured, msgSent, msgRecv, msgExpired, activeQueues, msgSentNtf, msgRecvNtf, activeQueuesNtf, qCount, msgCount, proxyRelaysRequested, proxyRelaysConnected, msgSentViaProxy, msgDeliveredViaProxy, msgDeliveredFromProxy}

getServerStatsData :: ServerStats -> STM ServerStatsData
getServerStatsData s = do
  _fromTime <- readTVar $ fromTime s
  _qCreated <- readTVar $ qCreated s
  _qSecured <- readTVar $ qSecured s
  _qDeletedAll <- readTVar $ qDeletedAll s
  _qDeletedNew <- readTVar $ qDeletedNew s
  _qDeletedSecured <- readTVar $ qDeletedSecured s
  _msgSent <- readTVar $ msgSent s
  _msgRecv <- readTVar $ msgRecv s
  _msgExpired <- readTVar $ msgExpired s
  _activeQueues <- getPeriodStatsData $ activeQueues s
  _msgSentNtf <- readTVar $ msgSentNtf s
  _msgRecvNtf <- readTVar $ msgRecvNtf s
  _activeQueuesNtf <- getPeriodStatsData $ activeQueuesNtf s
  _qCount <- readTVar $ qCount s
  _msgCount <- readTVar $ msgCount s
  _proxyRelaysRequested <- readTVar $ proxyRelaysRequested s
  _proxyRelaysConnected <- readTVar $ proxyRelaysConnected s
  _msgSentViaProxy <- readTVar $ msgSentViaProxy s
  _msgDeliveredViaProxy <- readTVar $ msgDeliveredViaProxy s
  _msgDeliveredFromProxy <- readTVar $ msgDeliveredFromProxy s
  pure ServerStatsData {_fromTime, _qCreated, _qSecured, _qDeletedAll, _qDeletedNew, _qDeletedSecured, _msgSent, _msgRecv, _msgExpired, _activeQueues, _msgSentNtf, _msgRecvNtf, _proxyRelaysRequested, _proxyRelaysConnected, _msgSentViaProxy, _msgDeliveredViaProxy, _msgDeliveredFromProxy, _activeQueuesNtf, _qCount, _msgCount}

setServerStats :: ServerStats -> ServerStatsData -> STM ()
setServerStats s d = do
  writeTVar (fromTime s) $! _fromTime d
  writeTVar (qCreated s) $! _qCreated d
  writeTVar (qSecured s) $! _qSecured d
  writeTVar (qDeletedAll s) $! _qDeletedAll d
  writeTVar (qDeletedNew s) $! _qDeletedNew d
  writeTVar (qDeletedSecured s) $! _qDeletedSecured d
  writeTVar (msgSent s) $! _msgSent d
  writeTVar (msgRecv s) $! _msgRecv d
  writeTVar (msgExpired s) $! _msgExpired d
  setPeriodStats (activeQueues s) (_activeQueues d)
  writeTVar (msgSentNtf s) $! _msgSentNtf d
  writeTVar (msgRecvNtf s) $! _msgRecvNtf d
  setPeriodStats (activeQueuesNtf s) (_activeQueuesNtf d)
  writeTVar (qCount s) $! _qCount d
  writeTVar (msgCount s) $! _msgCount d
  writeTVar (proxyRelaysRequested s) $! _proxyRelaysRequested d
  writeTVar (proxyRelaysConnected s) $! _proxyRelaysConnected d
  writeTVar (msgSentViaProxy s) $! _msgSentViaProxy d
  writeTVar (msgDeliveredViaProxy s) $! _msgDeliveredViaProxy d
  writeTVar (msgDeliveredFromProxy s) $! _msgDeliveredFromProxy d

instance StrEncoding ServerStatsData where
  strEncode ServerStatsData {_fromTime, _qCreated, _qSecured, _qDeletedAll, _qDeletedNew, _qDeletedSecured, _msgSent, _msgRecv, _msgExpired, _msgSentNtf, _msgRecvNtf, _proxyRelaysRequested, _proxyRelaysConnected, _msgSentViaProxy, _msgDeliveredViaProxy, _msgDeliveredFromProxy, _activeQueues, _activeQueuesNtf, _qCount, _msgCount} =
    B.unlines
      [ "fromTime=" <> strEncode _fromTime,
        "qCreated=" <> strEncode _qCreated,
        "qSecured=" <> strEncode _qSecured,
        "qDeletedAll=" <> strEncode _qDeletedAll,
        "qDeletedNew=" <> strEncode _qDeletedNew,
        "qDeletedSecured=" <> strEncode _qDeletedSecured,
        "qCount=" <> strEncode _qCount,
        "msgSent=" <> strEncode _msgSent,
        "msgRecv=" <> strEncode _msgRecv,
        "msgExpired=" <> strEncode _msgExpired,
        "msgSentNtf=" <> strEncode _msgSentNtf,
        "msgRecvNtf=" <> strEncode _msgRecvNtf,
        "proxyRelaysRequested=" <> strEncode _proxyRelaysRequested,
        "proxyRelaysConnected=" <> strEncode _proxyRelaysConnected,
        "msgSentViaProxy=" <> strEncode _msgSentViaProxy,
        "msgDeliveredViaProxy=" <> strEncode _msgDeliveredViaProxy,
        "msgDeliveredFromProxy=" <> strEncode _msgDeliveredFromProxy,
        "activeQueues:",
        strEncode _activeQueues,
        "activeQueuesNtf:",
        strEncode _activeQueuesNtf
      ]
  strP = do
    _fromTime <- "fromTime=" *> strP <* A.endOfLine
    _qCreated <- "qCreated=" *> strP <* A.endOfLine
    _qSecured <- "qSecured=" *> strP <* A.endOfLine
    (_qDeletedAll, _qDeletedNew, _qDeletedSecured) <-
      (,0,0) <$> ("qDeleted=" *> strP <* A.endOfLine)
        <|> ((,,) <$> ("qDeletedAll=" *> strP <* A.endOfLine) <*> ("qDeletedNew=" *> strP <* A.endOfLine) <*> ("qDeletedSecured=" *> strP <* A.endOfLine))
    _qCount <- "qCount=" *> strP <* A.endOfLine <|> pure 0
    _msgSent <- "msgSent=" *> strP <* A.endOfLine
    _msgRecv <- "msgRecv=" *> strP <* A.endOfLine
    _msgExpired <- "msgExpired=" *> strP <* A.endOfLine <|> pure 0
    _msgSentNtf <- "msgSentNtf=" *> strP <* A.endOfLine <|> pure 0
    _msgRecvNtf <- "msgRecvNtf=" *> strP <* A.endOfLine <|> pure 0
    _proxyRelaysRequested <- "proxyRelaysRequested=" *> strP <* A.endOfLine <|> pure 0
    _proxyRelaysConnected <- "proxyRelaysConnected=" *> strP <* A.endOfLine <|> pure 0
    _msgSentViaProxy <- "msgSentViaProxy=" *> strP <* A.endOfLine <|> pure 0
    _msgDeliveredViaProxy <- "msgDeliveredViaProxy=" *> strP <* A.endOfLine <|> pure 0
    _msgDeliveredFromProxy <- "msgDeliveredFromProxy=" *> strP <* A.endOfLine <|> pure 0
    _activeQueues <-
      optional ("activeQueues:" <* A.endOfLine) >>= \case
        Just _ -> strP <* optional A.endOfLine
        _ -> do
          _day <- "dayMsgQueues=" *> strP <* A.endOfLine
          _week <- "weekMsgQueues=" *> strP <* A.endOfLine
          _month <- "monthMsgQueues=" *> strP <* optional A.endOfLine
          pure PeriodStatsData {_day, _week, _month}
    _activeQueuesNtf <-
      optional ("activeQueuesNtf:" <* A.endOfLine) >>= \case
        Just _ -> strP <* optional A.endOfLine
        _ -> pure newPeriodStatsData
    pure ServerStatsData {_fromTime, _qCreated, _qSecured, _qDeletedAll, _qDeletedNew, _qDeletedSecured, _msgSent, _msgRecv, _msgExpired, _msgSentNtf, _msgRecvNtf, _proxyRelaysRequested, _proxyRelaysConnected, _msgSentViaProxy, _msgDeliveredViaProxy, _msgDeliveredFromProxy, _activeQueues, _activeQueuesNtf, _qCount, _msgCount = 0}

data PeriodStats a = PeriodStats
  { day :: TVar (Set a),
    week :: TVar (Set a),
    month :: TVar (Set a)
  }

newPeriodStats :: STM (PeriodStats a)
newPeriodStats = do
  day <- newTVar S.empty
  week <- newTVar S.empty
  month <- newTVar S.empty
  pure PeriodStats {day, week, month}

data PeriodStatsData a = PeriodStatsData
  { _day :: Set a,
    _week :: Set a,
    _month :: Set a
  }
  deriving (Show)

newPeriodStatsData :: PeriodStatsData a
newPeriodStatsData = PeriodStatsData {_day = S.empty, _week = S.empty, _month = S.empty}

getPeriodStatsData :: PeriodStats a -> STM (PeriodStatsData a)
getPeriodStatsData s = do
  _day <- readTVar $ day s
  _week <- readTVar $ week s
  _month <- readTVar $ month s
  pure PeriodStatsData {_day, _week, _month}

setPeriodStats :: PeriodStats a -> PeriodStatsData a -> STM ()
setPeriodStats s d = do
  writeTVar (day s) $! _day d
  writeTVar (week s) $! _week d
  writeTVar (month s) $! _month d

instance (Ord a, StrEncoding a) => StrEncoding (PeriodStatsData a) where
  strEncode PeriodStatsData {_day, _week, _month} =
    "day=" <> strEncode _day <> "\nweek=" <> strEncode _week <> "\nmonth=" <> strEncode _month
  strP = do
    _day <- "day=" *> strP <* A.endOfLine
    _week <- "week=" *> strP <* A.endOfLine
    _month <- "month=" *> strP
    pure PeriodStatsData {_day, _week, _month}

data PeriodStatCounts = PeriodStatCounts
  { dayCount :: String,
    weekCount :: String,
    monthCount :: String
  }

periodStatCounts :: forall a. PeriodStats a -> UTCTime -> STM PeriodStatCounts
periodStatCounts ps ts = do
  let d = utctDay ts
      (_, wDay) = mondayStartWeek d
      MonthDay _ mDay = d
  dayCount <- periodCount 1 $ day ps
  weekCount <- periodCount wDay $ week ps
  monthCount <- periodCount mDay $ month ps
  pure PeriodStatCounts {dayCount, weekCount, monthCount}
  where
    periodCount :: Int -> TVar (Set a) -> STM String
    periodCount 1 pVar = show . S.size <$> swapTVar pVar S.empty
    periodCount _ _ = pure ""

updatePeriodStats :: Ord a => PeriodStats a -> a -> STM ()
updatePeriodStats stats pId = do
  updatePeriod day
  updatePeriod week
  updatePeriod month
  where
    updatePeriod pSel = modifyTVar' (pSel stats) (S.insert pId)
