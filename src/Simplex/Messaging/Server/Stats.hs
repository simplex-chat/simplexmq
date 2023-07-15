{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Server.Stats where

import Control.Applicative (optional, (<|>))
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import Data.Set (Set)
import qualified Data.Set as S
import Data.Time.Calendar.Month.Compat (pattern MonthDay)
import Data.Time.Calendar.OrdinalDate (mondayStartWeek)
import Data.Time.Clock (UTCTime (..))
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (RecipientId)
import UnliftIO.STM

data ServerStats = ServerStats
  { fromTime :: TVar UTCTime,
    qCreated :: TVar Int,
    qSecured :: TVar Int,
    qDeleted :: TVar Int,
    msgSent :: TVar Int,
    msgRecv :: TVar Int,
    activeQueues :: PeriodStats RecipientId,
    msgSentNtf :: TVar Int,
    msgRecvNtf :: TVar Int,
    activeQueuesNtf :: PeriodStats RecipientId,
    qCount :: TVar Int,
    msgCount :: TVar Int
  }

data ServerStatsData = ServerStatsData
  { _fromTime :: UTCTime,
    _qCreated :: Int,
    _qSecured :: Int,
    _qDeleted :: Int,
    _msgSent :: Int,
    _msgRecv :: Int,
    _activeQueues :: PeriodStatsData RecipientId,
    _msgSentNtf :: Int,
    _msgRecvNtf :: Int,
    _activeQueuesNtf :: PeriodStatsData RecipientId,
    _qCount :: Int,
    _msgCount :: Int
  }
  deriving (Show)

newServerStats :: UTCTime -> STM ServerStats
newServerStats ts = do
  fromTime <- newTVar ts
  qCreated <- newTVar 0
  qSecured <- newTVar 0
  qDeleted <- newTVar 0
  msgSent <- newTVar 0
  msgRecv <- newTVar 0
  activeQueues <- newPeriodStats
  msgSentNtf <- newTVar 0
  msgRecvNtf <- newTVar 0
  activeQueuesNtf <- newPeriodStats
  qCount <- newTVar 0
  msgCount <- newTVar 0
  pure ServerStats {fromTime, qCreated, qSecured, qDeleted, msgSent, msgRecv, activeQueues, msgSentNtf, msgRecvNtf, activeQueuesNtf, qCount, msgCount}

getServerStatsData :: ServerStats -> STM ServerStatsData
getServerStatsData s = do
  _fromTime <- readTVar $ fromTime s
  _qCreated <- readTVar $ qCreated s
  _qSecured <- readTVar $ qSecured s
  _qDeleted <- readTVar $ qDeleted s
  _msgSent <- readTVar $ msgSent s
  _msgRecv <- readTVar $ msgRecv s
  _activeQueues <- getPeriodStatsData $ activeQueues s
  _msgSentNtf <- readTVar $ msgSentNtf s
  _msgRecvNtf <- readTVar $ msgRecvNtf s
  _activeQueuesNtf <- getPeriodStatsData $ activeQueuesNtf s
  _qCount <- readTVar $ qCount s
  _msgCount <- readTVar $ msgCount s
  pure ServerStatsData {_fromTime, _qCreated, _qSecured, _qDeleted, _msgSent, _msgRecv, _activeQueues, _msgSentNtf, _msgRecvNtf, _activeQueuesNtf, _qCount, _msgCount}

setServerStats :: ServerStats -> ServerStatsData -> STM ()
setServerStats s d = do
  writeTVar (fromTime s) $! _fromTime d
  writeTVar (qCreated s) $! _qCreated d
  writeTVar (qSecured s) $! _qSecured d
  writeTVar (qDeleted s) $! _qDeleted d
  writeTVar (msgSent s) $! _msgSent d
  writeTVar (msgRecv s) $! _msgRecv d
  setPeriodStats (activeQueues s) (_activeQueues d)
  writeTVar (msgSentNtf s) $! _msgSentNtf d
  writeTVar (msgRecvNtf s) $! _msgRecvNtf d
  setPeriodStats (activeQueuesNtf s) (_activeQueuesNtf d)
  writeTVar (qCount s) $! _qCount d
  writeTVar (msgCount s) $! _msgCount d

instance StrEncoding ServerStatsData where
  strEncode ServerStatsData {_fromTime, _qCreated, _qSecured, _qDeleted, _msgSent, _msgRecv, _msgSentNtf, _msgRecvNtf, _activeQueues, _activeQueuesNtf} =
    B.unlines
      [ "fromTime=" <> strEncode _fromTime,
        "qCreated=" <> strEncode _qCreated,
        "qSecured=" <> strEncode _qSecured,
        "qDeleted=" <> strEncode _qDeleted,
        "msgSent=" <> strEncode _msgSent,
        "msgRecv=" <> strEncode _msgRecv,
        "msgSentNtf=" <> strEncode _msgSentNtf,
        "msgRecvNtf=" <> strEncode _msgRecvNtf,
        "activeQueues:",
        strEncode _activeQueues,
        "activeQueuesNtf:",
        strEncode _activeQueuesNtf
      ]
  strP = do
    _fromTime <- "fromTime=" *> strP <* A.endOfLine
    _qCreated <- "qCreated=" *> strP <* A.endOfLine
    _qSecured <- "qSecured=" *> strP <* A.endOfLine
    _qDeleted <- "qDeleted=" *> strP <* A.endOfLine
    _msgSent <- "msgSent=" *> strP <* A.endOfLine
    _msgRecv <- "msgRecv=" *> strP <* A.endOfLine
    _msgSentNtf <- "msgSentNtf=" *> strP <* A.endOfLine <|> pure 0
    _msgRecvNtf <- "msgRecvNtf=" *> strP <* A.endOfLine <|> pure 0
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
    pure ServerStatsData {_fromTime, _qCreated, _qSecured, _qDeleted, _msgSent, _msgRecv, _msgSentNtf, _msgRecvNtf, _activeQueues, _activeQueuesNtf, _qCount = 0, _msgCount = 0}

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
