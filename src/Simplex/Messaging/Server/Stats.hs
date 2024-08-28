{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

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
import Simplex.Messaging.Util (unlessM)
import UnliftIO.STM

data ServerStats = ServerStats
  { fromTime :: TVar UTCTime,
    qCreated :: TVar Int,
    qSecured :: TVar Int,
    qDeletedAll :: TVar Int,
    qDeletedAllB :: TVar Int,
    qDeletedNew :: TVar Int,
    qDeletedSecured :: TVar Int,
    qSub :: TVar Int, -- only includes subscriptions when there were pending messages
    -- qSubNoMsg :: TVar Int, -- this stat creates too many STM transactions
    qSubAllB :: TVar Int, -- count of all subscription batches (with and without pending messages)
    qSubAuth :: TVar Int,
    qSubDuplicate :: TVar Int,
    qSubProhibited :: TVar Int,
    qSubEnd :: TVar Int,
    qSubEndB :: TVar Int,
    ntfCreated :: TVar Int,
    ntfDeleted :: TVar Int,
    ntfDeletedB :: TVar Int,
    ntfSub :: TVar Int,
    ntfSubB :: TVar Int,
    ntfSubAuth :: TVar Int,
    ntfSubDuplicate :: TVar Int,
    msgSent :: TVar Int,
    msgSentAuth :: TVar Int,
    msgSentQuota :: TVar Int,
    msgSentLarge :: TVar Int,
    msgRecv :: TVar Int,
    msgRecvGet :: TVar Int,
    msgGet :: TVar Int,
    msgGetNoMsg :: TVar Int,
    msgGetAuth :: TVar Int,
    msgGetDuplicate :: TVar Int,
    msgGetProhibited :: TVar Int,
    msgExpired :: TVar Int,
    activeQueues :: PeriodStats RecipientId,
    -- subscribedQueues :: PeriodStats RecipientId, -- this stat uses too much memory
    msgSentNtf :: TVar Int, -- sent messages with NTF flag
    msgRecvNtf :: TVar Int, -- received messages with NTF flag
    activeQueuesNtf :: PeriodStats RecipientId,
    msgNtfs :: TVar Int, -- messages notications delivered to NTF server (<= msgSentNtf)
    msgNtfNoSub :: TVar Int, -- no subscriber to notifications (e.g., NTF server not connected)
    msgNtfLost :: TVar Int, -- notification is lost because NTF delivery queue is full
    pRelays :: ProxyStats,
    pRelaysOwn :: ProxyStats,
    pMsgFwds :: ProxyStats,
    pMsgFwdsOwn :: ProxyStats,
    pMsgFwdsRecv :: TVar Int,
    qCount :: TVar Int,
    msgCount :: TVar Int
  }

data ServerStatsData = ServerStatsData
  { _fromTime :: UTCTime,
    _qCreated :: Int,
    _qSecured :: Int,
    _qDeletedAll :: Int,
    _qDeletedAllB :: Int,
    _qDeletedNew :: Int,
    _qDeletedSecured :: Int,
    _qSub :: Int,
    _qSubAllB :: Int,
    _qSubAuth :: Int,
    _qSubDuplicate :: Int,
    _qSubProhibited :: Int,
    _qSubEnd :: Int,
    _qSubEndB :: Int,
    _ntfCreated :: Int,
    _ntfDeleted :: Int,
    _ntfDeletedB :: Int,
    _ntfSub :: Int,
    _ntfSubB :: Int,
    _ntfSubAuth :: Int,
    _ntfSubDuplicate :: Int,
    _msgSent :: Int,
    _msgSentAuth :: Int,
    _msgSentQuota :: Int,
    _msgSentLarge :: Int,
    _msgRecv :: Int,
    _msgRecvGet :: Int,
    _msgGet :: Int,
    _msgGetNoMsg :: Int,
    _msgGetAuth :: Int,
    _msgGetDuplicate :: Int,
    _msgGetProhibited :: Int,
    _msgExpired :: Int,
    _activeQueues :: PeriodStatsData RecipientId,
    _msgSentNtf :: Int,
    _msgRecvNtf :: Int,
    _activeQueuesNtf :: PeriodStatsData RecipientId,
    _msgNtfs :: Int,
    _msgNtfNoSub :: Int,
    _msgNtfLost :: Int,
    _pRelays :: ProxyStatsData,
    _pRelaysOwn :: ProxyStatsData,
    _pMsgFwds :: ProxyStatsData,
    _pMsgFwdsOwn :: ProxyStatsData,
    _pMsgFwdsRecv :: Int,
    _qCount :: Int,
    _msgCount :: Int
  }
  deriving (Show)

newServerStats :: UTCTime -> IO ServerStats
newServerStats ts = do
  fromTime <- newTVarIO ts
  qCreated <- newTVarIO 0
  qSecured <- newTVarIO 0
  qDeletedAll <- newTVarIO 0
  qDeletedAllB <- newTVarIO 0
  qDeletedNew <- newTVarIO 0
  qDeletedSecured <- newTVarIO 0
  qSub <- newTVarIO 0
  qSubAllB <- newTVarIO 0
  qSubAuth <- newTVarIO 0
  qSubDuplicate <- newTVarIO 0
  qSubProhibited <- newTVarIO 0
  qSubEnd <- newTVarIO 0
  qSubEndB <- newTVarIO 0
  ntfCreated <- newTVarIO 0
  ntfDeleted <- newTVarIO 0
  ntfDeletedB <- newTVarIO 0
  ntfSub <- newTVarIO 0
  ntfSubB <- newTVarIO 0
  ntfSubAuth <- newTVarIO 0
  ntfSubDuplicate <- newTVarIO 0
  msgSent <- newTVarIO 0
  msgSentAuth <- newTVarIO 0
  msgSentQuota <- newTVarIO 0
  msgSentLarge <- newTVarIO 0
  msgRecv <- newTVarIO 0
  msgRecvGet <- newTVarIO 0
  msgGet <- newTVarIO 0
  msgGetNoMsg <- newTVarIO 0
  msgGetAuth <- newTVarIO 0
  msgGetDuplicate <- newTVarIO 0
  msgGetProhibited <- newTVarIO 0
  msgExpired <- newTVarIO 0
  activeQueues <- newPeriodStats
  msgSentNtf <- newTVarIO 0
  msgRecvNtf <- newTVarIO 0
  activeQueuesNtf <- newPeriodStats
  msgNtfs <- newTVarIO 0
  msgNtfNoSub <- newTVarIO 0
  msgNtfLost <- newTVarIO 0
  pRelays <- newProxyStats
  pRelaysOwn <- newProxyStats
  pMsgFwds <- newProxyStats
  pMsgFwdsOwn <- newProxyStats
  pMsgFwdsRecv <- newTVarIO 0
  qCount <- newTVarIO 0
  msgCount <- newTVarIO 0
  pure
    ServerStats
      { fromTime,
        qCreated,
        qSecured,
        qDeletedAll,
        qDeletedAllB,
        qDeletedNew,
        qDeletedSecured,
        qSub,
        qSubAllB,
        qSubAuth,
        qSubDuplicate,
        qSubProhibited,
        qSubEnd,
        qSubEndB,
        ntfCreated,
        ntfDeleted,
        ntfDeletedB,
        ntfSub,
        ntfSubB,
        ntfSubAuth,
        ntfSubDuplicate,
        msgSent,
        msgSentAuth,
        msgSentQuota,
        msgSentLarge,
        msgRecv,
        msgRecvGet,
        msgGet,
        msgGetNoMsg,
        msgGetAuth,
        msgGetDuplicate,
        msgGetProhibited,
        msgExpired,
        activeQueues,
        msgSentNtf,
        msgRecvNtf,
        activeQueuesNtf,
        msgNtfs,
        msgNtfNoSub,
        msgNtfLost,
        pRelays,
        pRelaysOwn,
        pMsgFwds,
        pMsgFwdsOwn,
        pMsgFwdsRecv,
        qCount,
        msgCount
      }

getServerStatsData :: ServerStats -> IO ServerStatsData
getServerStatsData s = do
  _fromTime <- readTVarIO $ fromTime s
  _qCreated <- readTVarIO $ qCreated s
  _qSecured <- readTVarIO $ qSecured s
  _qDeletedAll <- readTVarIO $ qDeletedAll s
  _qDeletedAllB <- readTVarIO $ qDeletedAllB s
  _qDeletedNew <- readTVarIO $ qDeletedNew s
  _qDeletedSecured <- readTVarIO $ qDeletedSecured s
  _qSub <- readTVarIO $ qSub s
  _qSubAllB <- readTVarIO $ qSubAllB s
  _qSubAuth <- readTVarIO $ qSubAuth s
  _qSubDuplicate <- readTVarIO $ qSubDuplicate s
  _qSubProhibited <- readTVarIO $ qSubProhibited s
  _qSubEnd <- readTVarIO $ qSubEnd s
  _qSubEndB <- readTVarIO $ qSubEndB s
  _ntfCreated <- readTVarIO $ ntfCreated s
  _ntfDeleted <- readTVarIO $ ntfDeleted s
  _ntfDeletedB <- readTVarIO $ ntfDeletedB s
  _ntfSub <- readTVarIO $ ntfSub s
  _ntfSubB <- readTVarIO $ ntfSubB s
  _ntfSubAuth <- readTVarIO $ ntfSubAuth s
  _ntfSubDuplicate <- readTVarIO $ ntfSubDuplicate s
  _msgSent <- readTVarIO $ msgSent s
  _msgSentAuth <- readTVarIO $ msgSentAuth s
  _msgSentQuota <- readTVarIO $ msgSentQuota s
  _msgSentLarge <- readTVarIO $ msgSentLarge s
  _msgRecv <- readTVarIO $ msgRecv s
  _msgRecvGet <- readTVarIO $ msgRecvGet s
  _msgGet <- readTVarIO $ msgGet s
  _msgGetNoMsg <- readTVarIO $ msgGetNoMsg s
  _msgGetAuth <- readTVarIO $ msgGetAuth s
  _msgGetDuplicate <- readTVarIO $ msgGetDuplicate s
  _msgGetProhibited <- readTVarIO $ msgGetProhibited s
  _msgExpired <- readTVarIO $ msgExpired s
  _activeQueues <- getPeriodStatsData $ activeQueues s
  _msgSentNtf <- readTVarIO $ msgSentNtf s
  _msgRecvNtf <- readTVarIO $ msgRecvNtf s
  _activeQueuesNtf <- getPeriodStatsData $ activeQueuesNtf s
  _msgNtfs <- readTVarIO $ msgNtfs s
  _msgNtfNoSub <- readTVarIO $ msgNtfNoSub s
  _msgNtfLost <- readTVarIO $ msgNtfLost s
  _pRelays <- getProxyStatsData $ pRelays s
  _pRelaysOwn <- getProxyStatsData $ pRelaysOwn s
  _pMsgFwds <- getProxyStatsData $ pMsgFwds s
  _pMsgFwdsOwn <- getProxyStatsData $ pMsgFwdsOwn s
  _pMsgFwdsRecv <- readTVarIO $ pMsgFwdsRecv s
  _qCount <- readTVarIO $ qCount s
  _msgCount <- readTVarIO $ msgCount s
  pure
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
        _msgNtfNoSub,
        _msgNtfLost,
        _pRelays,
        _pRelaysOwn,
        _pMsgFwds,
        _pMsgFwdsOwn,
        _pMsgFwdsRecv,
        _qCount,
        _msgCount
      }

setServerStats :: ServerStats -> ServerStatsData -> IO ()
setServerStats s d = do
  atomically $ writeTVar (fromTime s) $! _fromTime d
  atomically $ writeTVar (qCreated s) $! _qCreated d
  atomically $ writeTVar (qSecured s) $! _qSecured d
  atomically $ writeTVar (qDeletedAll s) $! _qDeletedAll d
  atomically $ writeTVar (qDeletedAllB s) $! _qDeletedAllB d
  atomically $ writeTVar (qDeletedNew s) $! _qDeletedNew d
  atomically $ writeTVar (qDeletedSecured s) $! _qDeletedSecured d
  atomically $ writeTVar (qSub s) $! _qSub d
  atomically $ writeTVar (qSubAllB s) $! _qSubAllB d
  atomically $ writeTVar (qSubAuth s) $! _qSubAuth d
  atomically $ writeTVar (qSubDuplicate s) $! _qSubDuplicate d
  atomically $ writeTVar (qSubProhibited s) $! _qSubProhibited d
  atomically $ writeTVar (qSubEnd s) $! _qSubEnd d
  atomically $ writeTVar (qSubEndB s) $! _qSubEndB d
  atomically $ writeTVar (ntfCreated s) $! _ntfCreated d
  atomically $ writeTVar (ntfDeleted s) $! _ntfDeleted d
  atomically $ writeTVar (ntfDeletedB s) $! _ntfDeletedB d
  atomically $ writeTVar (ntfSub s) $! _ntfSub d
  atomically $ writeTVar (ntfSubB s) $! _ntfSubB d
  atomically $ writeTVar (ntfSubAuth s) $! _ntfSubAuth d
  atomically $ writeTVar (ntfSubDuplicate s) $! _ntfSubDuplicate d
  atomically $ writeTVar (msgSent s) $! _msgSent d
  atomically $ writeTVar (msgSentAuth s) $! _msgSentAuth d
  atomically $ writeTVar (msgSentQuota s) $! _msgSentQuota d
  atomically $ writeTVar (msgSentLarge s) $! _msgSentLarge d
  atomically $ writeTVar (msgRecv s) $! _msgRecv d
  atomically $ writeTVar (msgRecvGet s) $! _msgRecvGet d
  atomically $ writeTVar (msgGet s) $! _msgGet d
  atomically $ writeTVar (msgGetNoMsg s) $! _msgGetNoMsg d
  atomically $ writeTVar (msgGetAuth s) $! _msgGetAuth d
  atomically $ writeTVar (msgGetDuplicate s) $! _msgGetDuplicate d
  atomically $ writeTVar (msgGetProhibited s) $! _msgGetProhibited d
  atomically $ writeTVar (msgExpired s) $! _msgExpired d
  setPeriodStats (activeQueues s) (_activeQueues d)
  atomically $ writeTVar (msgSentNtf s) $! _msgSentNtf d
  atomically $ writeTVar (msgRecvNtf s) $! _msgRecvNtf d
  setPeriodStats (activeQueuesNtf s) (_activeQueuesNtf d)
  atomically $ writeTVar (msgNtfs s) $! _msgNtfs d
  atomically $ writeTVar (msgNtfNoSub s) $! _msgNtfNoSub d
  atomically $ writeTVar (msgNtfLost s) $! _msgNtfLost d
  setProxyStats (pRelays s) $! _pRelays d
  setProxyStats (pRelaysOwn s) $! _pRelaysOwn d
  setProxyStats (pMsgFwds s) $! _pMsgFwds d
  setProxyStats (pMsgFwdsOwn s) $! _pMsgFwdsOwn d
  atomically $ writeTVar (pMsgFwdsRecv s) $! _pMsgFwdsRecv d
  atomically $ writeTVar (qCount s) $! _qCount d
  atomically $ writeTVar (msgCount s) $! _msgCount d

instance StrEncoding ServerStatsData where
  strEncode d =
    B.unlines
      [ "fromTime=" <> strEncode (_fromTime d),
        "qCreated=" <> strEncode (_qCreated d),
        "qSecured=" <> strEncode (_qSecured d),
        "qDeletedAll=" <> strEncode (_qDeletedAll d),
        "qDeletedNew=" <> strEncode (_qDeletedNew d),
        "qDeletedSecured=" <> strEncode (_qDeletedSecured d),
        "qDeletedAllB=" <> strEncode (_qDeletedAllB d),
        "qCount=" <> strEncode (_qCount d),
        "qSub=" <> strEncode (_qSub d),
        "qSubAllB=" <> strEncode (_qSubAllB d),
        "qSubAuth=" <> strEncode (_qSubAuth d),
        "qSubDuplicate=" <> strEncode (_qSubDuplicate d),
        "qSubProhibited=" <> strEncode (_qSubProhibited d),
        "qSubEnd=" <> strEncode (_qSubEnd d),
        "qSubEndB=" <> strEncode (_qSubEndB d),
        "ntfCreated=" <> strEncode (_ntfCreated d),
        "ntfDeleted=" <> strEncode (_ntfDeleted d),
        "ntfDeletedB=" <> strEncode (_ntfDeletedB d),
        "ntfSub=" <> strEncode (_ntfSub d),
        "ntfSubB=" <> strEncode (_ntfSubB d),
        "ntfSubAuth=" <> strEncode (_ntfSubAuth d),
        "ntfSubDuplicate=" <> strEncode (_ntfSubDuplicate d),
        "msgSent=" <> strEncode (_msgSent d),
        "msgSentAuth=" <> strEncode (_msgSentAuth d),
        "msgSentQuota=" <> strEncode (_msgSentQuota d),
        "msgSentLarge=" <> strEncode (_msgSentLarge d),
        "msgRecv=" <> strEncode (_msgRecv d),
        "msgRecvGet=" <> strEncode (_msgRecvGet d),
        "msgGet=" <> strEncode (_msgGet d),
        "msgGetNoMsg=" <> strEncode (_msgGetNoMsg d),
        "msgGetAuth=" <> strEncode (_msgGetAuth d),
        "msgGetDuplicate=" <> strEncode (_msgGetDuplicate d),
        "msgGetProhibited=" <> strEncode (_msgGetProhibited d),
        "msgExpired=" <> strEncode (_msgExpired d),
        "msgSentNtf=" <> strEncode (_msgSentNtf d),
        "msgRecvNtf=" <> strEncode (_msgRecvNtf d),
        "msgNtfs=" <> strEncode (_msgNtfs d),
        "msgNtfNoSub=" <> strEncode (_msgNtfNoSub d),
        "msgNtfLost=" <> strEncode (_msgNtfLost d),
        "activeQueues:",
        strEncode (_activeQueues d),
        "activeQueuesNtf:",
        strEncode (_activeQueuesNtf d),
        "pRelays:",
        strEncode (_pRelays d),
        "pRelaysOwn:",
        strEncode (_pRelaysOwn d),
        "pMsgFwds:",
        strEncode (_pMsgFwds d),
        "pMsgFwdsOwn:",
        strEncode (_pMsgFwdsOwn d),
        "pMsgFwdsRecv=" <> strEncode (_pMsgFwdsRecv d)
      ]
  strP = do
    _fromTime <- "fromTime=" *> strP <* A.endOfLine
    _qCreated <- "qCreated=" *> strP <* A.endOfLine
    _qSecured <- "qSecured=" *> strP <* A.endOfLine
    (_qDeletedAll, _qDeletedNew, _qDeletedSecured) <-
      (,0,0) <$> ("qDeleted=" *> strP <* A.endOfLine)
        <|> ((,,) <$> ("qDeletedAll=" *> strP <* A.endOfLine) <*> ("qDeletedNew=" *> strP <* A.endOfLine) <*> ("qDeletedSecured=" *> strP <* A.endOfLine))
    _qDeletedAllB <- opt "qDeletedAllB="
    _qCount <- opt "qCount="
    _qSub <- opt "qSub="
    _qSubNoMsg <- skipInt "qSubNoMsg=" -- skipping it for backward compatibility
    _qSubAllB <- opt "qSubAllB="
    _qSubAuth <- opt "qSubAuth="
    _qSubDuplicate <- opt "qSubDuplicate="
    _qSubProhibited <- opt "qSubProhibited="
    _qSubEnd <- opt "qSubEnd="
    _qSubEndB <- opt "qSubEndB="
    _ntfCreated <- opt "ntfCreated="
    _ntfDeleted <- opt "ntfDeleted="
    _ntfDeletedB <- opt "ntfDeletedB="
    _ntfSub <- opt "ntfSub="
    _ntfSubB <- opt "ntfSubB="
    _ntfSubAuth <- opt "ntfSubAuth="
    _ntfSubDuplicate <- opt "ntfSubDuplicate="
    _msgSent <- "msgSent=" *> strP <* A.endOfLine
    _msgSentAuth <- opt "msgSentAuth="
    _msgSentQuota <- opt "msgSentQuota="
    _msgSentLarge <- opt "msgSentLarge="
    _msgRecv <- "msgRecv=" *> strP <* A.endOfLine
    _msgRecvGet <- opt "msgRecvGet="
    _msgGet <- opt "msgGet="
    _msgGetNoMsg <- opt "msgGetNoMsg="
    _msgGetAuth <- opt "msgGetAuth="
    _msgGetDuplicate <- opt "msgGetDuplicate="
    _msgGetProhibited <- opt "msgGetProhibited="
    _msgExpired <- opt "msgExpired="
    _msgSentNtf <- opt "msgSentNtf="
    _msgRecvNtf <- opt "msgRecvNtf="
    _msgNtfs <- opt "msgNtfs="
    _msgNtfNoSub <- opt "msgNtfNoSub="
    _msgNtfLost <- opt "msgNtfLost="
    _activeQueues <-
      optional ("activeQueues:" <* A.endOfLine) >>= \case
        Just _ -> strP <* optional A.endOfLine
        _ -> do
          _day <- "dayMsgQueues=" *> strP <* A.endOfLine
          _week <- "weekMsgQueues=" *> strP <* A.endOfLine
          _month <- "monthMsgQueues=" *> strP <* optional A.endOfLine
          pure PeriodStatsData {_day, _week, _month}
    _subscribedQueues <-
      optional ("subscribedQueues:" <* A.endOfLine) >>= \case
        Just _ -> newPeriodStatsData <$ (strP @(PeriodStatsData RecipientId) <* optional A.endOfLine)
        _ -> pure newPeriodStatsData
    _activeQueuesNtf <-
      optional ("activeQueuesNtf:" <* A.endOfLine) >>= \case
        Just _ -> strP <* optional A.endOfLine
        _ -> pure newPeriodStatsData
    _pRelays <- proxyStatsP "pRelays:"
    _pRelaysOwn <- proxyStatsP "pRelaysOwn:"
    _pMsgFwds <- proxyStatsP "pMsgFwds:"
    _pMsgFwdsOwn <- proxyStatsP "pMsgFwdsOwn:"
    _pMsgFwdsRecv <- opt "pMsgFwdsRecv="
    pure
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
          _msgSentNtf,
          _msgRecvNtf,
          _msgNtfs,
          _msgNtfNoSub,
          _msgNtfLost,
          _activeQueues,
          _activeQueuesNtf,
          _pRelays,
          _pRelaysOwn,
          _pMsgFwds,
          _pMsgFwdsOwn,
          _pMsgFwdsRecv,
          _qCount,
          _msgCount = 0
        }
    where
      opt s = A.string s *> strP <* A.endOfLine <|> pure 0
      skipInt s = (0 :: Int) <$ optional (A.string s *> strP @Int *> A.endOfLine)
      proxyStatsP key =
        optional (A.string key >> A.endOfLine) >>= \case
          Just _ -> strP <* optional A.endOfLine
          _ -> pure newProxyStatsData

data PeriodStats a = PeriodStats
  { day :: TVar (Set a),
    week :: TVar (Set a),
    month :: TVar (Set a)
  }

newPeriodStats :: IO (PeriodStats a)
newPeriodStats = do
  day <- newTVarIO S.empty
  week <- newTVarIO S.empty
  month <- newTVarIO S.empty
  pure PeriodStats {day, week, month}

data PeriodStatsData a = PeriodStatsData
  { _day :: Set a,
    _week :: Set a,
    _month :: Set a
  }
  deriving (Show)

newPeriodStatsData :: PeriodStatsData a
newPeriodStatsData = PeriodStatsData {_day = S.empty, _week = S.empty, _month = S.empty}

getPeriodStatsData :: PeriodStats a -> IO (PeriodStatsData a)
getPeriodStatsData s = do
  _day <- readTVarIO $ day s
  _week <- readTVarIO $ week s
  _month <- readTVarIO $ month s
  pure PeriodStatsData {_day, _week, _month}

setPeriodStats :: PeriodStats a -> PeriodStatsData a -> IO ()
setPeriodStats s d = do
  atomically $ writeTVar (day s) $! _day d
  atomically $ writeTVar (week s) $! _week d
  atomically $ writeTVar (month s) $! _month d

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

periodStatCounts :: forall a. PeriodStats a -> UTCTime -> IO PeriodStatCounts
periodStatCounts ps ts = do
  let d = utctDay ts
      (_, wDay) = mondayStartWeek d
      MonthDay _ mDay = d
  dayCount <- periodCount 1 $ day ps
  weekCount <- periodCount wDay $ week ps
  monthCount <- periodCount mDay $ month ps
  pure PeriodStatCounts {dayCount, weekCount, monthCount}
  where
    periodCount :: Int -> TVar (Set a) -> IO String
    periodCount 1 pVar = atomically $ show . S.size <$> swapTVar pVar S.empty
    periodCount _ _ = pure ""

updatePeriodStats :: Ord a => PeriodStats a -> a -> IO ()
updatePeriodStats ps pId = do
  updatePeriod $ day ps
  updatePeriod $ week ps
  updatePeriod $ month ps
  where
    updatePeriod pVar = unlessM (S.member pId <$> readTVarIO pVar) $ atomically $ modifyTVar' pVar (S.insert pId)

data ProxyStats = ProxyStats
  { pRequests :: TVar Int,
    pSuccesses :: TVar Int, -- includes destination server error responses that will be forwarded to the client
    pErrorsConnect :: TVar Int,
    pErrorsCompat :: TVar Int,
    pErrorsOther :: TVar Int
  }

newProxyStats :: IO ProxyStats
newProxyStats = do
  pRequests <- newTVarIO 0
  pSuccesses <- newTVarIO 0
  pErrorsConnect <- newTVarIO 0
  pErrorsCompat <- newTVarIO 0
  pErrorsOther <- newTVarIO 0
  pure ProxyStats {pRequests, pSuccesses, pErrorsConnect, pErrorsCompat, pErrorsOther}

data ProxyStatsData = ProxyStatsData
  { _pRequests :: Int,
    _pSuccesses :: Int,
    _pErrorsConnect :: Int,
    _pErrorsCompat :: Int,
    _pErrorsOther :: Int
  }
  deriving (Show)

newProxyStatsData :: ProxyStatsData
newProxyStatsData = ProxyStatsData {_pRequests = 0, _pSuccesses = 0, _pErrorsConnect = 0, _pErrorsCompat = 0, _pErrorsOther = 0}

getProxyStatsData :: ProxyStats -> IO ProxyStatsData
getProxyStatsData s = do
  _pRequests <- readTVarIO $ pRequests s
  _pSuccesses <- readTVarIO $ pSuccesses s
  _pErrorsConnect <- readTVarIO $ pErrorsConnect s
  _pErrorsCompat <- readTVarIO $ pErrorsCompat s
  _pErrorsOther <- readTVarIO $ pErrorsOther s
  pure ProxyStatsData {_pRequests, _pSuccesses, _pErrorsConnect, _pErrorsCompat, _pErrorsOther}

getResetProxyStatsData :: ProxyStats -> IO ProxyStatsData
getResetProxyStatsData s = do
  _pRequests <- atomically $ swapTVar (pRequests s) 0
  _pSuccesses <- atomically $ swapTVar (pSuccesses s) 0
  _pErrorsConnect <- atomically $ swapTVar (pErrorsConnect s) 0
  _pErrorsCompat <- atomically $ swapTVar (pErrorsCompat s) 0
  _pErrorsOther <- atomically $ swapTVar (pErrorsOther s) 0
  pure ProxyStatsData {_pRequests, _pSuccesses, _pErrorsConnect, _pErrorsCompat, _pErrorsOther}

setProxyStats :: ProxyStats -> ProxyStatsData -> IO ()
setProxyStats s d = do
  atomically $ writeTVar (pRequests s) $! _pRequests d
  atomically $ writeTVar (pSuccesses s) $! _pSuccesses d
  atomically $ writeTVar (pErrorsConnect s) $! _pErrorsConnect d
  atomically $ writeTVar (pErrorsCompat s) $! _pErrorsCompat d
  atomically $ writeTVar (pErrorsOther s) $! _pErrorsOther d

instance StrEncoding ProxyStatsData where
  strEncode ProxyStatsData {_pRequests, _pSuccesses, _pErrorsConnect, _pErrorsCompat, _pErrorsOther} =
    "requests="
      <> strEncode _pRequests
      <> "\nsuccesses="
      <> strEncode _pSuccesses
      <> "\nerrorsConnect="
      <> strEncode _pErrorsConnect
      <> "\nerrorsCompat="
      <> strEncode _pErrorsCompat
      <> "\nerrorsOther="
      <> strEncode _pErrorsOther
  strP = do
    _pRequests <- "requests=" *> strP <* A.endOfLine
    _pSuccesses <- "successes=" *> strP <* A.endOfLine
    _pErrorsConnect <- "errorsConnect=" *> strP <* A.endOfLine
    _pErrorsCompat <- "errorsCompat=" *> strP <* A.endOfLine
    _pErrorsOther <- "errorsOther=" *> strP
    pure ProxyStatsData {_pRequests, _pSuccesses, _pErrorsConnect, _pErrorsCompat, _pErrorsOther}
