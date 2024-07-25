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
    qSub :: TVar Int,
    qSubNoMsg :: TVar Int,
    qSubAuth :: TVar Int,
    qSubDuplicate :: TVar Int,
    qSubProhibited :: TVar Int,
    ntfCreated :: TVar Int,
    ntfDeleted :: TVar Int,
    ntfSub :: TVar Int,
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
    subscribedQueues :: PeriodStats RecipientId,
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
    _qDeletedNew :: Int,
    _qDeletedSecured :: Int,
    _qSub :: Int,
    _qSubNoMsg :: Int,
    _qSubAuth :: Int,
    _qSubDuplicate :: Int,
    _qSubProhibited :: Int,
    _ntfCreated :: Int,
    _ntfDeleted :: Int,
    _ntfSub :: Int,
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
    _subscribedQueues :: PeriodStatsData RecipientId,
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

newServerStats :: UTCTime -> STM ServerStats
newServerStats ts = do
  fromTime <- newTVar ts
  qCreated <- newTVar 0
  qSecured <- newTVar 0
  qDeletedAll <- newTVar 0
  qDeletedNew <- newTVar 0
  qDeletedSecured <- newTVar 0
  qSub <- newTVar 0
  qSubNoMsg <- newTVar 0
  qSubAuth <- newTVar 0
  qSubDuplicate <- newTVar 0
  qSubProhibited <- newTVar 0
  ntfCreated <- newTVar 0
  ntfDeleted <- newTVar 0
  ntfSub <- newTVar 0
  ntfSubAuth <- newTVar 0
  ntfSubDuplicate <- newTVar 0
  msgSent <- newTVar 0
  msgSentAuth <- newTVar 0
  msgSentQuota <- newTVar 0
  msgSentLarge <- newTVar 0
  msgRecv <- newTVar 0
  msgRecvGet <- newTVar 0
  msgGet <- newTVar 0
  msgGetNoMsg <- newTVar 0
  msgGetAuth <- newTVar 0
  msgGetDuplicate <- newTVar 0
  msgGetProhibited <- newTVar 0
  msgExpired <- newTVar 0
  activeQueues <- newPeriodStats
  subscribedQueues <- newPeriodStats
  msgSentNtf <- newTVar 0
  msgRecvNtf <- newTVar 0
  activeQueuesNtf <- newPeriodStats
  msgNtfs <- newTVar 0
  msgNtfNoSub <- newTVar 0
  msgNtfLost <- newTVar 0
  pRelays <- newProxyStats
  pRelaysOwn <- newProxyStats
  pMsgFwds <- newProxyStats
  pMsgFwdsOwn <- newProxyStats
  pMsgFwdsRecv <- newTVar 0
  qCount <- newTVar 0
  msgCount <- newTVar 0
  pure
    ServerStats
      { fromTime,
        qCreated,
        qSecured,
        qDeletedAll,
        qDeletedNew,
        qDeletedSecured,
        qSub,
        qSubNoMsg,
        qSubAuth,
        qSubDuplicate,
        qSubProhibited,
        ntfCreated,
        ntfDeleted,
        ntfSub,
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
        subscribedQueues,
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

getServerStatsData :: ServerStats -> STM ServerStatsData
getServerStatsData s = do
  _fromTime <- readTVar $ fromTime s
  _qCreated <- readTVar $ qCreated s
  _qSecured <- readTVar $ qSecured s
  _qDeletedAll <- readTVar $ qDeletedAll s
  _qDeletedNew <- readTVar $ qDeletedNew s
  _qDeletedSecured <- readTVar $ qDeletedSecured s
  _qSub <- readTVar $ qSub s
  _qSubNoMsg <- readTVar $ qSubNoMsg s
  _qSubAuth <- readTVar $ qSubAuth s
  _qSubDuplicate <- readTVar $ qSubDuplicate s
  _qSubProhibited <- readTVar $ qSubProhibited s
  _ntfCreated <- readTVar $ ntfCreated s
  _ntfDeleted <- readTVar $ ntfDeleted s
  _ntfSub <- readTVar $ ntfSub s
  _ntfSubAuth <- readTVar $ ntfSubAuth s
  _ntfSubDuplicate <- readTVar $ ntfSubDuplicate s
  _msgSent <- readTVar $ msgSent s
  _msgSentAuth <- readTVar $ msgSentAuth s
  _msgSentQuota <- readTVar $ msgSentQuota s
  _msgSentLarge <- readTVar $ msgSentLarge s
  _msgRecv <- readTVar $ msgRecv s
  _msgRecvGet <- readTVar $ msgRecvGet s
  _msgGet <- readTVar $ msgGet s
  _msgGetNoMsg <- readTVar $ msgGetNoMsg s
  _msgGetAuth <- readTVar $ msgGetAuth s
  _msgGetDuplicate <- readTVar $ msgGetDuplicate s
  _msgGetProhibited <- readTVar $ msgGetProhibited s
  _msgExpired <- readTVar $ msgExpired s
  _activeQueues <- getPeriodStatsData $ activeQueues s
  _subscribedQueues <- getPeriodStatsData $ subscribedQueues s
  _msgSentNtf <- readTVar $ msgSentNtf s
  _msgRecvNtf <- readTVar $ msgRecvNtf s
  _activeQueuesNtf <- getPeriodStatsData $ activeQueuesNtf s
  _msgNtfs <- readTVar $ msgNtfs s
  _msgNtfNoSub <- readTVar $ msgNtfNoSub s
  _msgNtfLost <- readTVar $ msgNtfLost s
  _pRelays <- getProxyStatsData $ pRelays s
  _pRelaysOwn <- getProxyStatsData $ pRelaysOwn s
  _pMsgFwds <- getProxyStatsData $ pMsgFwds s
  _pMsgFwdsOwn <- getProxyStatsData $ pMsgFwdsOwn s
  _pMsgFwdsRecv <- readTVar $ pMsgFwdsRecv s
  _qCount <- readTVar $ qCount s
  _msgCount <- readTVar $ msgCount s
  pure
    ServerStatsData
      { _fromTime,
        _qCreated,
        _qSecured,
        _qDeletedAll,
        _qDeletedNew,
        _qDeletedSecured,
        _qSub,
        _qSubNoMsg,
        _qSubAuth,
        _qSubDuplicate,
        _qSubProhibited,
        _ntfCreated,
        _ntfDeleted,
        _ntfSub,
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
        _subscribedQueues,
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

setServerStats :: ServerStats -> ServerStatsData -> STM ()
setServerStats s d = do
  writeTVar (fromTime s) $! _fromTime d
  writeTVar (qCreated s) $! _qCreated d
  writeTVar (qSecured s) $! _qSecured d
  writeTVar (qDeletedAll s) $! _qDeletedAll d
  writeTVar (qDeletedNew s) $! _qDeletedNew d
  writeTVar (qDeletedSecured s) $! _qDeletedSecured d
  writeTVar (qSub s) $! _qSub d
  writeTVar (qSubNoMsg s) $! _qSubNoMsg d
  writeTVar (qSubAuth s) $! _qSubAuth d
  writeTVar (qSubDuplicate s) $! _qSubDuplicate d
  writeTVar (qSubProhibited s) $! _qSubProhibited d
  writeTVar (ntfCreated s) $! _ntfCreated d
  writeTVar (ntfDeleted s) $! _ntfDeleted d
  writeTVar (ntfSub s) $! _ntfSub d
  writeTVar (ntfSubAuth s) $! _ntfSubAuth d
  writeTVar (ntfSubDuplicate s) $! _ntfSubDuplicate d
  writeTVar (msgSent s) $! _msgSent d
  writeTVar (msgSentAuth s) $! _msgSentAuth d
  writeTVar (msgSentQuota s) $! _msgSentQuota d
  writeTVar (msgSentLarge s) $! _msgSentLarge d
  writeTVar (msgRecv s) $! _msgRecv d
  writeTVar (msgRecvGet s) $! _msgRecvGet d
  writeTVar (msgGet s) $! _msgGet d
  writeTVar (msgGetNoMsg s) $! _msgGetNoMsg d
  writeTVar (msgGetAuth s) $! _msgGetAuth d
  writeTVar (msgGetDuplicate s) $! _msgGetDuplicate d
  writeTVar (msgGetProhibited s) $! _msgGetProhibited d
  writeTVar (msgExpired s) $! _msgExpired d
  setPeriodStats (activeQueues s) (_activeQueues d)
  setPeriodStats (subscribedQueues s) (_subscribedQueues d)
  writeTVar (msgSentNtf s) $! _msgSentNtf d
  writeTVar (msgRecvNtf s) $! _msgRecvNtf d
  setPeriodStats (activeQueuesNtf s) (_activeQueuesNtf d)
  writeTVar (msgNtfs s) $! _msgNtfs d
  writeTVar (msgNtfNoSub s) $! _msgNtfNoSub d
  writeTVar (msgNtfLost s) $! _msgNtfLost d
  setProxyStats (pRelays s) $! _pRelays d
  setProxyStats (pRelaysOwn s) $! _pRelaysOwn d
  setProxyStats (pMsgFwds s) $! _pMsgFwds d
  setProxyStats (pMsgFwdsOwn s) $! _pMsgFwdsOwn d
  writeTVar (pMsgFwdsRecv s) $! _pMsgFwdsRecv d
  writeTVar (qCount s) $! _qCount d
  writeTVar (msgCount s) $! _msgCount d

instance StrEncoding ServerStatsData where
  strEncode d =
    B.unlines
      [ "fromTime=" <> strEncode (_fromTime d),
        "qCreated=" <> strEncode (_qCreated d),
        "qSecured=" <> strEncode (_qSecured d),
        "qDeletedAll=" <> strEncode (_qDeletedAll d),
        "qDeletedNew=" <> strEncode (_qDeletedNew d),
        "qDeletedSecured=" <> strEncode (_qDeletedSecured d),
        "qCount=" <> strEncode (_qCount d),
        "qSub=" <> strEncode (_qSub d),
        "qSubNoMsg=" <> strEncode (_qSubNoMsg d),
        "qSubAuth=" <> strEncode (_qSubAuth d),
        "qSubDuplicate=" <> strEncode (_qSubDuplicate d),
        "qSubProhibited=" <> strEncode (_qSubProhibited d),
        "ntfCreated=" <> strEncode (_ntfCreated d),
        "ntfDeleted=" <> strEncode (_ntfDeleted d),
        "ntfSub=" <> strEncode (_ntfSub d),
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
        "subscribedQueues:",
        strEncode (_subscribedQueues d),
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
    _qCount <- opt "qCount="
    _qSub <- opt "qSub="
    _qSubNoMsg <- opt "qSubNoMsg="
    _qSubAuth <- opt "qSubAuth="
    _qSubDuplicate <- opt "qSubDuplicate="
    _qSubProhibited <- opt "qSubProhibited="
    _ntfCreated <- opt "ntfCreated="
    _ntfDeleted <- opt "ntfDeleted="
    _ntfSub <- opt "ntfSub="
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
        Just _ -> strP <* optional A.endOfLine
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
          _qDeletedNew,
          _qDeletedSecured,
          _qSub,
          _qSubNoMsg,
          _qSubAuth,
          _qSubDuplicate,
          _qSubProhibited,
          _ntfCreated,
          _ntfDeleted,
          _ntfSub,
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
          _subscribedQueues,
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
      proxyStatsP key =
        optional (A.string key >> A.endOfLine) >>= \case
          Just _ -> strP <* optional A.endOfLine
          _ -> pure newProxyStatsData

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

data ProxyStats = ProxyStats
  { pRequests :: TVar Int,
    pSuccesses :: TVar Int, -- includes destination server error responses that will be forwarded to the client
    pErrorsConnect :: TVar Int,
    pErrorsCompat :: TVar Int,
    pErrorsOther :: TVar Int
  }

newProxyStats :: STM ProxyStats
newProxyStats = do
  pRequests <- newTVar 0
  pSuccesses <- newTVar 0
  pErrorsConnect <- newTVar 0
  pErrorsCompat <- newTVar 0
  pErrorsOther <- newTVar 0
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

getProxyStatsData :: ProxyStats -> STM ProxyStatsData
getProxyStatsData s = do
  _pRequests <- readTVar $ pRequests s
  _pSuccesses <- readTVar $ pSuccesses s
  _pErrorsConnect <- readTVar $ pErrorsConnect s
  _pErrorsCompat <- readTVar $ pErrorsCompat s
  _pErrorsOther <- readTVar $ pErrorsOther s
  pure ProxyStatsData {_pRequests, _pSuccesses, _pErrorsConnect, _pErrorsCompat, _pErrorsOther}

getResetProxyStatsData :: ProxyStats -> STM ProxyStatsData
getResetProxyStatsData s = do
  _pRequests <- swapTVar (pRequests s) 0
  _pSuccesses <- swapTVar (pSuccesses s) 0
  _pErrorsConnect <- swapTVar (pErrorsConnect s) 0
  _pErrorsCompat <- swapTVar (pErrorsCompat s) 0
  _pErrorsOther <- swapTVar (pErrorsOther s) 0
  pure ProxyStatsData {_pRequests, _pSuccesses, _pErrorsConnect, _pErrorsCompat, _pErrorsOther}

setProxyStats :: ProxyStats -> ProxyStatsData -> STM ()
setProxyStats s d = do
  writeTVar (pRequests s) $! _pRequests d
  writeTVar (pSuccesses s) $! _pSuccesses d
  writeTVar (pErrorsConnect s) $! _pErrorsConnect d
  writeTVar (pErrorsCompat s) $! _pErrorsCompat d
  writeTVar (pErrorsOther s) $! _pErrorsOther d

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
