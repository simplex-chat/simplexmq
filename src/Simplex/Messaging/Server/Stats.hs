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
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Hashable (hash)
import Data.IORef
import Data.IntSet (IntSet)
import qualified Data.IntSet as IS
import Data.Set (Set)
import qualified Data.Set as S
import Data.Text (Text)
import Data.Time.Calendar.Month (pattern MonthDay)
import Data.Time.Calendar.OrdinalDate (mondayStartWeek)
import Data.Time.Clock (UTCTime (..))
import GHC.IORef (atomicSwapIORef)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (EntityId (..))
import Simplex.Messaging.Util (atomicModifyIORef'_, tshow, unlessM)

data ServerStats = ServerStats
  { fromTime :: IORef UTCTime,
    qCreated :: IORef Int,
    qSecured :: IORef Int,
    qDeletedAll :: IORef Int,
    qDeletedAllB :: IORef Int,
    qDeletedNew :: IORef Int,
    qDeletedSecured :: IORef Int,
    qBlocked :: IORef Int,
    qSub :: IORef Int, -- only includes subscriptions when there were pending messages
    -- qSubNoMsg :: IORef Int, -- this stat creates too many STM transactions
    qSubAllB :: IORef Int, -- count of all subscription batches (with and without pending messages)
    qSubAuth :: IORef Int,
    qSubDuplicate :: IORef Int,
    qSubProhibited :: IORef Int,
    qSubEnd :: IORef Int,
    qSubEndB :: IORef Int,
    ntfCreated :: IORef Int,
    ntfDeleted :: IORef Int,
    ntfDeletedB :: IORef Int,
    ntfSub :: IORef Int,
    ntfSubB :: IORef Int,
    ntfSubAuth :: IORef Int,
    ntfSubDuplicate :: IORef Int,
    msgSent :: IORef Int,
    msgSentAuth :: IORef Int,
    msgSentQuota :: IORef Int,
    msgSentLarge :: IORef Int,
    msgSentBlock :: IORef Int,
    msgRecv :: IORef Int,
    msgRecvGet :: IORef Int,
    msgGet :: IORef Int,
    msgGetNoMsg :: IORef Int,
    msgGetAuth :: IORef Int,
    msgGetDuplicate :: IORef Int,
    msgGetProhibited :: IORef Int,
    msgExpired :: IORef Int,
    activeQueues :: PeriodStats,
    -- subscribedQueues :: PeriodStats, -- this stat uses too much memory
    msgSentNtf :: IORef Int, -- sent messages with NTF flag
    msgRecvNtf :: IORef Int, -- received messages with NTF flag
    activeQueuesNtf :: PeriodStats,
    msgNtfs :: IORef Int, -- messages notications delivered to NTF server (<= msgSentNtf)
    msgNtfsB :: IORef Int, -- messages notication batches delivered to NTF server
    msgNtfNoSub :: IORef Int, -- no subscriber to notifications (e.g., NTF server not connected)
    msgNtfLost :: IORef Int, -- notification is lost because NTF delivery queue is full
    msgNtfExpired :: IORef Int, -- expired
    pRelays :: ProxyStats,
    pRelaysOwn :: ProxyStats,
    pMsgFwds :: ProxyStats,
    pMsgFwdsOwn :: ProxyStats,
    pMsgFwdsRecv :: IORef Int,
    rcvServices :: ServiceStats,
    ntfServices :: ServiceStats,
    qCount :: IORef Int,
    msgCount :: IORef Int,
    ntfCount :: IORef Int
  }

data ServerStatsData = ServerStatsData
  { _fromTime :: UTCTime,
    _qCreated :: Int,
    _qSecured :: Int,
    _qDeletedAll :: Int,
    _qDeletedAllB :: Int,
    _qDeletedNew :: Int,
    _qDeletedSecured :: Int,
    _qBlocked :: Int,
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
    _msgSentBlock :: Int,
    _msgRecv :: Int,
    _msgRecvGet :: Int,
    _msgGet :: Int,
    _msgGetNoMsg :: Int,
    _msgGetAuth :: Int,
    _msgGetDuplicate :: Int,
    _msgGetProhibited :: Int,
    _msgExpired :: Int,
    _activeQueues :: PeriodStatsData,
    _msgSentNtf :: Int,
    _msgRecvNtf :: Int,
    _activeQueuesNtf :: PeriodStatsData,
    _msgNtfs :: Int,
    _msgNtfsB :: Int,
    _msgNtfNoSub :: Int,
    _msgNtfLost :: Int,
    _msgNtfExpired :: Int,
    _pRelays :: ProxyStatsData,
    _pRelaysOwn :: ProxyStatsData,
    _pMsgFwds :: ProxyStatsData,
    _pMsgFwdsOwn :: ProxyStatsData,
    _pMsgFwdsRecv :: Int,
    _ntfServices :: ServiceStatsData,
    _rcvServices :: ServiceStatsData,
    _qCount :: Int,
    _msgCount :: Int,
    _ntfCount :: Int
  }
  deriving (Show)

newServerStats :: UTCTime -> IO ServerStats
newServerStats ts = do
  fromTime <- newIORef ts
  qCreated <- newIORef 0
  qSecured <- newIORef 0
  qDeletedAll <- newIORef 0
  qDeletedAllB <- newIORef 0
  qDeletedNew <- newIORef 0
  qDeletedSecured <- newIORef 0
  qBlocked <- newIORef 0
  qSub <- newIORef 0
  qSubAllB <- newIORef 0
  qSubAuth <- newIORef 0
  qSubDuplicate <- newIORef 0
  qSubProhibited <- newIORef 0
  qSubEnd <- newIORef 0
  qSubEndB <- newIORef 0
  ntfCreated <- newIORef 0
  ntfDeleted <- newIORef 0
  ntfDeletedB <- newIORef 0
  ntfSub <- newIORef 0
  ntfSubB <- newIORef 0
  ntfSubAuth <- newIORef 0
  ntfSubDuplicate <- newIORef 0
  msgSent <- newIORef 0
  msgSentAuth <- newIORef 0
  msgSentQuota <- newIORef 0
  msgSentLarge <- newIORef 0
  msgSentBlock <- newIORef 0
  msgRecv <- newIORef 0
  msgRecvGet <- newIORef 0
  msgGet <- newIORef 0
  msgGetNoMsg <- newIORef 0
  msgGetAuth <- newIORef 0
  msgGetDuplicate <- newIORef 0
  msgGetProhibited <- newIORef 0
  msgExpired <- newIORef 0
  activeQueues <- newPeriodStats
  msgSentNtf <- newIORef 0
  msgRecvNtf <- newIORef 0
  activeQueuesNtf <- newPeriodStats
  msgNtfs <- newIORef 0
  msgNtfsB <- newIORef 0
  msgNtfNoSub <- newIORef 0
  msgNtfLost <- newIORef 0
  msgNtfExpired <- newIORef 0
  pRelays <- newProxyStats
  pRelaysOwn <- newProxyStats
  pMsgFwds <- newProxyStats
  pMsgFwdsOwn <- newProxyStats
  pMsgFwdsRecv <- newIORef 0
  rcvServices <- newServiceStats
  ntfServices <- newServiceStats
  qCount <- newIORef 0
  msgCount <- newIORef 0
  ntfCount <- newIORef 0
  pure
    ServerStats
      { fromTime,
        qCreated,
        qSecured,
        qDeletedAll,
        qDeletedAllB,
        qDeletedNew,
        qDeletedSecured,
        qBlocked,
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
        msgSentBlock,
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
        msgNtfsB,
        msgNtfNoSub,
        msgNtfLost,
        msgNtfExpired,
        pRelays,
        pRelaysOwn,
        pMsgFwds,
        pMsgFwdsOwn,
        pMsgFwdsRecv,
        rcvServices,
        ntfServices,
        qCount,
        msgCount,
        ntfCount
      }

getServerStatsData :: ServerStats -> IO ServerStatsData
getServerStatsData s = do
  _fromTime <- readIORef $ fromTime s
  _qCreated <- readIORef $ qCreated s
  _qSecured <- readIORef $ qSecured s
  _qDeletedAll <- readIORef $ qDeletedAll s
  _qDeletedAllB <- readIORef $ qDeletedAllB s
  _qDeletedNew <- readIORef $ qDeletedNew s
  _qDeletedSecured <- readIORef $ qDeletedSecured s
  _qBlocked <- readIORef $ qBlocked s
  _qSub <- readIORef $ qSub s
  _qSubAllB <- readIORef $ qSubAllB s
  _qSubAuth <- readIORef $ qSubAuth s
  _qSubDuplicate <- readIORef $ qSubDuplicate s
  _qSubProhibited <- readIORef $ qSubProhibited s
  _qSubEnd <- readIORef $ qSubEnd s
  _qSubEndB <- readIORef $ qSubEndB s
  _ntfCreated <- readIORef $ ntfCreated s
  _ntfDeleted <- readIORef $ ntfDeleted s
  _ntfDeletedB <- readIORef $ ntfDeletedB s
  _ntfSub <- readIORef $ ntfSub s
  _ntfSubB <- readIORef $ ntfSubB s
  _ntfSubAuth <- readIORef $ ntfSubAuth s
  _ntfSubDuplicate <- readIORef $ ntfSubDuplicate s
  _msgSent <- readIORef $ msgSent s
  _msgSentAuth <- readIORef $ msgSentAuth s
  _msgSentQuota <- readIORef $ msgSentQuota s
  _msgSentLarge <- readIORef $ msgSentLarge s
  _msgSentBlock <- readIORef $ msgSentBlock s
  _msgRecv <- readIORef $ msgRecv s
  _msgRecvGet <- readIORef $ msgRecvGet s
  _msgGet <- readIORef $ msgGet s
  _msgGetNoMsg <- readIORef $ msgGetNoMsg s
  _msgGetAuth <- readIORef $ msgGetAuth s
  _msgGetDuplicate <- readIORef $ msgGetDuplicate s
  _msgGetProhibited <- readIORef $ msgGetProhibited s
  _msgExpired <- readIORef $ msgExpired s
  _activeQueues <- getPeriodStatsData $ activeQueues s
  _msgSentNtf <- readIORef $ msgSentNtf s
  _msgRecvNtf <- readIORef $ msgRecvNtf s
  _activeQueuesNtf <- getPeriodStatsData $ activeQueuesNtf s
  _msgNtfs <- readIORef $ msgNtfs s
  _msgNtfsB <- readIORef $ msgNtfsB s
  _msgNtfNoSub <- readIORef $ msgNtfNoSub s
  _msgNtfLost <- readIORef $ msgNtfLost s
  _msgNtfExpired <- readIORef $ msgNtfExpired s
  _pRelays <- getProxyStatsData $ pRelays s
  _pRelaysOwn <- getProxyStatsData $ pRelaysOwn s
  _pMsgFwds <- getProxyStatsData $ pMsgFwds s
  _pMsgFwdsOwn <- getProxyStatsData $ pMsgFwdsOwn s
  _pMsgFwdsRecv <- readIORef $ pMsgFwdsRecv s
  _rcvServices <- getServiceStatsData $ rcvServices s
  _ntfServices <- getServiceStatsData $ ntfServices s
  _qCount <- readIORef $ qCount s
  _msgCount <- readIORef $ msgCount s
  _ntfCount <- readIORef $ ntfCount s
  pure
    ServerStatsData
      { _fromTime,
        _qCreated,
        _qSecured,
        _qDeletedAll,
        _qDeletedAllB,
        _qDeletedNew,
        _qDeletedSecured,
        _qBlocked,
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
        _msgSentBlock,
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
        _msgNtfsB,
        _msgNtfNoSub,
        _msgNtfLost,
        _msgNtfExpired,
        _pRelays,
        _pRelaysOwn,
        _pMsgFwds,
        _pMsgFwdsOwn,
        _pMsgFwdsRecv,
        _rcvServices,
        _ntfServices,
        _qCount,
        _msgCount,
        _ntfCount
      }

-- this function is not thread safe, it is used on server start only
setServerStats :: ServerStats -> ServerStatsData -> IO ()
setServerStats s d = do
  writeIORef (fromTime s) $! _fromTime d
  writeIORef (qCreated s) $! _qCreated d
  writeIORef (qSecured s) $! _qSecured d
  writeIORef (qDeletedAll s) $! _qDeletedAll d
  writeIORef (qDeletedAllB s) $! _qDeletedAllB d
  writeIORef (qDeletedNew s) $! _qDeletedNew d
  writeIORef (qDeletedSecured s) $! _qDeletedSecured d
  writeIORef (qBlocked s) $! _qBlocked d
  writeIORef (qSub s) $! _qSub d
  writeIORef (qSubAllB s) $! _qSubAllB d
  writeIORef (qSubAuth s) $! _qSubAuth d
  writeIORef (qSubDuplicate s) $! _qSubDuplicate d
  writeIORef (qSubProhibited s) $! _qSubProhibited d
  writeIORef (qSubEnd s) $! _qSubEnd d
  writeIORef (qSubEndB s) $! _qSubEndB d
  writeIORef (ntfCreated s) $! _ntfCreated d
  writeIORef (ntfDeleted s) $! _ntfDeleted d
  writeIORef (ntfDeletedB s) $! _ntfDeletedB d
  writeIORef (ntfSub s) $! _ntfSub d
  writeIORef (ntfSubB s) $! _ntfSubB d
  writeIORef (ntfSubAuth s) $! _ntfSubAuth d
  writeIORef (ntfSubDuplicate s) $! _ntfSubDuplicate d
  writeIORef (msgSent s) $! _msgSent d
  writeIORef (msgSentAuth s) $! _msgSentAuth d
  writeIORef (msgSentQuota s) $! _msgSentQuota d
  writeIORef (msgSentLarge s) $! _msgSentLarge d
  writeIORef (msgSentBlock s) $! _msgSentBlock d
  writeIORef (msgRecv s) $! _msgRecv d
  writeIORef (msgRecvGet s) $! _msgRecvGet d
  writeIORef (msgGet s) $! _msgGet d
  writeIORef (msgGetNoMsg s) $! _msgGetNoMsg d
  writeIORef (msgGetAuth s) $! _msgGetAuth d
  writeIORef (msgGetDuplicate s) $! _msgGetDuplicate d
  writeIORef (msgGetProhibited s) $! _msgGetProhibited d
  writeIORef (msgExpired s) $! _msgExpired d
  setPeriodStats (activeQueues s) (_activeQueues d)
  writeIORef (msgSentNtf s) $! _msgSentNtf d
  writeIORef (msgRecvNtf s) $! _msgRecvNtf d
  setPeriodStats (activeQueuesNtf s) (_activeQueuesNtf d)
  writeIORef (msgNtfs s) $! _msgNtfs d
  writeIORef (msgNtfsB s) $! _msgNtfsB d
  writeIORef (msgNtfNoSub s) $! _msgNtfNoSub d
  writeIORef (msgNtfLost s) $! _msgNtfLost d
  writeIORef (msgNtfExpired s) $! _msgNtfExpired d
  setProxyStats (pRelays s) $! _pRelays d
  setProxyStats (pRelaysOwn s) $! _pRelaysOwn d
  setProxyStats (pMsgFwds s) $! _pMsgFwds d
  setProxyStats (pMsgFwdsOwn s) $! _pMsgFwdsOwn d
  writeIORef (pMsgFwdsRecv s) $! _pMsgFwdsRecv d
  setServiceStats (rcvServices s) $! _rcvServices d
  setServiceStats (ntfServices s) $! _ntfServices d
  writeIORef (qCount s) $! _qCount d
  writeIORef (msgCount s) $! _msgCount d
  writeIORef (ntfCount s) $! _ntfCount d

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
        "qBlocked=" <> strEncode (_qBlocked d),
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
        "msgSentBlock=" <> strEncode (_msgSentBlock d),
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
        "msgNtfsB=" <> strEncode (_msgNtfsB d),
        "msgNtfNoSub=" <> strEncode (_msgNtfNoSub d),
        "msgNtfLost=" <> strEncode (_msgNtfLost d),
        "msgNtfExpired=" <> strEncode (_msgNtfExpired d),
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
        "pMsgFwdsRecv=" <> strEncode (_pMsgFwdsRecv d),
        "rcvServices:",
        strEncode (_rcvServices d),
        "ntfServices:",
        strEncode (_ntfServices d)
      ]
  strP = do
    _fromTime <- "fromTime=" *> strP <* A.endOfLine
    _qCreated <- "qCreated=" *> strP <* A.endOfLine
    _qSecured <- "qSecured=" *> strP <* A.endOfLine
    (_qDeletedAll, _qDeletedNew, _qDeletedSecured) <-
      (,0,0) <$> ("qDeleted=" *> strP <* A.endOfLine)
        <|> ((,,) <$> ("qDeletedAll=" *> strP <* A.endOfLine) <*> ("qDeletedNew=" *> strP <* A.endOfLine) <*> ("qDeletedSecured=" *> strP <* A.endOfLine))
    _qDeletedAllB <- opt "qDeletedAllB="
    _qBlocked <- opt "qBlocked="
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
    _msgSentBlock <- opt "msgSentBlock="
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
    _msgNtfsB <- opt "msgNtfsB="
    _msgNtfNoSub <- opt "msgNtfNoSub="
    _msgNtfLost <- opt "msgNtfLost="
    _msgNtfExpired <- opt "msgNtfExpired="
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
        Just _ -> newPeriodStatsData <$ (strP @PeriodStatsData <* optional A.endOfLine)
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
    _rcvServices <- serviceStatsP "rcvServices:"
    _ntfServices <- serviceStatsP "ntfServices:"
    pure
      ServerStatsData
        { _fromTime,
          _qCreated,
          _qSecured,
          _qDeletedAll,
          _qDeletedAllB,
          _qDeletedNew,
          _qDeletedSecured,
          _qBlocked,
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
          _msgSentBlock,
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
          _msgNtfsB,
          _msgNtfNoSub,
          _msgNtfLost,
          _msgNtfExpired,
          _activeQueues,
          _activeQueuesNtf,
          _pRelays,
          _pRelaysOwn,
          _pMsgFwds,
          _pMsgFwdsOwn,
          _pMsgFwdsRecv,
          _rcvServices,
          _ntfServices,
          _qCount,
          _msgCount = 0,
          _ntfCount = 0
        }
    where
      opt s = A.string s *> strP <* A.endOfLine <|> pure 0
      skipInt s = (0 :: Int) <$ optional (A.string s *> strP @Int *> A.endOfLine)
      proxyStatsP key =
        optional (A.string key >> A.endOfLine) >>= \case
          Just _ -> strP <* optional A.endOfLine
          _ -> pure newProxyStatsData
      serviceStatsP key =
        optional (A.string key >> A.endOfLine) >>= \case
          Just _ -> strP <* optional A.endOfLine
          _ -> pure newServiceStatsData

data PeriodStats = PeriodStats
  { day :: IORef IntSet,
    week :: IORef IntSet,
    month :: IORef IntSet
  }

newPeriodStats :: IO PeriodStats
newPeriodStats = do
  day <- newIORef IS.empty
  week <- newIORef IS.empty
  month <- newIORef IS.empty
  pure PeriodStats {day, week, month}

data PeriodStatsData = PeriodStatsData
  { _day :: IntSet,
    _week :: IntSet,
    _month :: IntSet
  }
  deriving (Show)

newPeriodStatsData :: PeriodStatsData
newPeriodStatsData = PeriodStatsData {_day = IS.empty, _week = IS.empty, _month = IS.empty}

getPeriodStatsData :: PeriodStats -> IO PeriodStatsData
getPeriodStatsData s = do
  _day <- readIORef $ day s
  _week <- readIORef $ week s
  _month <- readIORef $ month s
  pure PeriodStatsData {_day, _week, _month}

-- this function is not thread safe, it is used on server start only
setPeriodStats :: PeriodStats -> PeriodStatsData -> IO ()
setPeriodStats s d = do
  writeIORef (day s) $! _day d
  writeIORef (week s) $! _week d
  writeIORef (month s) $! _month d

instance StrEncoding PeriodStatsData where
  strEncode PeriodStatsData {_day, _week, _month} =
    "dayHashes=" <> strEncode _day <> "\nweekHashes=" <> strEncode _week <> "\nmonthHashes=" <> strEncode _month
  strP = do
    _day <- ("day=" *> bsSetP <|> "dayHashes=" *> strP) <* A.endOfLine
    _week <- ("week=" *> bsSetP <|> "weekHashes=" *> strP) <* A.endOfLine
    _month <- "month=" *> bsSetP <|> "monthHashes=" *> strP
    pure PeriodStatsData {_day, _week, _month}
    where
      bsSetP = S.foldl' (\s -> (`IS.insert` s) . hash) IS.empty <$> strP @(Set ByteString)

data PeriodStatCounts = PeriodStatCounts
  { dayCount :: Text,
    weekCount :: Text,
    monthCount :: Text
  }

periodStatDataCounts :: PeriodStatsData -> PeriodStatCounts
periodStatDataCounts PeriodStatsData {_day, _week, _month} =
  PeriodStatCounts
    { dayCount = tshow $ IS.size _day,
      weekCount = tshow $ IS.size _week,
      monthCount = tshow $ IS.size _month
    }

periodStatCounts :: PeriodStats -> UTCTime -> IO PeriodStatCounts
periodStatCounts ps ts = do
  let d = utctDay ts
      (_, wDay) = mondayStartWeek d
      MonthDay _ mDay = d
  dayCount <- periodCount 1 $ day ps
  weekCount <- periodCount wDay $ week ps
  monthCount <- periodCount mDay $ month ps
  pure PeriodStatCounts {dayCount, weekCount, monthCount}
  where
    periodCount :: Int -> IORef IntSet -> IO Text
    periodCount 1 ref = tshow . IS.size <$> atomicSwapIORef ref IS.empty
    periodCount _ _ = pure ""

updatePeriodStats :: PeriodStats -> EntityId -> IO ()
updatePeriodStats ps (EntityId pId) = do
  updatePeriod $ day ps
  updatePeriod $ week ps
  updatePeriod $ month ps
  where
    ph = hash pId
    updatePeriod ref = unlessM (IS.member ph <$> readIORef ref) $ atomicModifyIORef'_ ref $ IS.insert ph

data ProxyStats = ProxyStats
  { pRequests :: IORef Int,
    pSuccesses :: IORef Int, -- includes destination server error responses that will be forwarded to the client
    pErrorsConnect :: IORef Int,
    pErrorsCompat :: IORef Int,
    pErrorsOther :: IORef Int
  }

newProxyStats :: IO ProxyStats
newProxyStats = do
  pRequests <- newIORef 0
  pSuccesses <- newIORef 0
  pErrorsConnect <- newIORef 0
  pErrorsCompat <- newIORef 0
  pErrorsOther <- newIORef 0
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
  _pRequests <- readIORef $ pRequests s
  _pSuccesses <- readIORef $ pSuccesses s
  _pErrorsConnect <- readIORef $ pErrorsConnect s
  _pErrorsCompat <- readIORef $ pErrorsCompat s
  _pErrorsOther <- readIORef $ pErrorsOther s
  pure ProxyStatsData {_pRequests, _pSuccesses, _pErrorsConnect, _pErrorsCompat, _pErrorsOther}

getResetProxyStatsData :: ProxyStats -> IO ProxyStatsData
getResetProxyStatsData s = do
  _pRequests <- atomicSwapIORef (pRequests s) 0
  _pSuccesses <- atomicSwapIORef (pSuccesses s) 0
  _pErrorsConnect <- atomicSwapIORef (pErrorsConnect s) 0
  _pErrorsCompat <- atomicSwapIORef (pErrorsCompat s) 0
  _pErrorsOther <- atomicSwapIORef (pErrorsOther s) 0
  pure ProxyStatsData {_pRequests, _pSuccesses, _pErrorsConnect, _pErrorsCompat, _pErrorsOther}

-- this function is not thread safe, it is used on server start only
setProxyStats :: ProxyStats -> ProxyStatsData -> IO ()
setProxyStats s d = do
  writeIORef (pRequests s) $! _pRequests d
  writeIORef (pSuccesses s) $! _pSuccesses d
  writeIORef (pErrorsConnect s) $! _pErrorsConnect d
  writeIORef (pErrorsCompat s) $! _pErrorsCompat d
  writeIORef (pErrorsOther s) $! _pErrorsOther d

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

data ServiceStats = ServiceStats
  { srvAssocNew :: IORef Int,
    srvAssocDuplicate :: IORef Int,
    srvAssocUpdated :: IORef Int,
    srvAssocRemoved :: IORef Int,
    srvSubCount :: IORef Int,
    srvSubDuplicate :: IORef Int,
    srvSubQueues :: IORef Int,
    srvSubEnd :: IORef Int
  }

data ServiceStatsData = ServiceStatsData
  { _srvAssocNew :: Int,
    _srvAssocDuplicate :: Int,
    _srvAssocUpdated :: Int,
    _srvAssocRemoved :: Int,
    _srvSubCount :: Int,
    _srvSubDuplicate :: Int,
    _srvSubQueues :: Int,
    _srvSubEnd :: Int
  }
  deriving (Show)

newServiceStatsData :: ServiceStatsData
newServiceStatsData =
  ServiceStatsData
    { _srvAssocNew = 0,
      _srvAssocDuplicate = 0,
      _srvAssocUpdated = 0,
      _srvAssocRemoved = 0,
      _srvSubCount = 0,
      _srvSubDuplicate = 0,
      _srvSubQueues = 0,
      _srvSubEnd = 0
    }

newServiceStats :: IO ServiceStats
newServiceStats = do
  srvAssocNew <- newIORef 0
  srvAssocDuplicate <- newIORef 0
  srvAssocUpdated <- newIORef 0
  srvAssocRemoved <- newIORef 0
  srvSubCount <- newIORef 0
  srvSubDuplicate <- newIORef 0
  srvSubQueues <- newIORef 0
  srvSubEnd <- newIORef 0
  pure
    ServiceStats
      { srvAssocNew,
        srvAssocDuplicate,
        srvAssocUpdated,
        srvAssocRemoved,
        srvSubCount,
        srvSubDuplicate,
        srvSubQueues,
        srvSubEnd
      }

getServiceStatsData :: ServiceStats -> IO ServiceStatsData
getServiceStatsData s = do
  _srvAssocNew <- readIORef $ srvAssocNew s
  _srvAssocDuplicate <- readIORef $ srvAssocDuplicate s
  _srvAssocUpdated <- readIORef $ srvAssocUpdated s
  _srvAssocRemoved <- readIORef $ srvAssocRemoved s
  _srvSubCount <- readIORef $ srvSubCount s
  _srvSubDuplicate <- readIORef $ srvSubDuplicate s
  _srvSubQueues <- readIORef $ srvSubQueues s
  _srvSubEnd <- readIORef $ srvSubEnd s
  pure
    ServiceStatsData
      { _srvAssocNew,
        _srvAssocDuplicate,
        _srvAssocUpdated,
        _srvAssocRemoved,
        _srvSubCount,
        _srvSubDuplicate,
        _srvSubQueues,
        _srvSubEnd
      }

getResetServiceStatsData :: ServiceStats -> IO ServiceStatsData
getResetServiceStatsData s = do
  _srvAssocNew <- atomicSwapIORef (srvAssocNew s) 0
  _srvAssocDuplicate <- atomicSwapIORef (srvAssocDuplicate s) 0
  _srvAssocUpdated <- atomicSwapIORef (srvAssocUpdated s) 0
  _srvAssocRemoved <- atomicSwapIORef (srvAssocRemoved s) 0
  _srvSubCount <- atomicSwapIORef (srvSubCount s) 0
  _srvSubDuplicate <- atomicSwapIORef (srvSubDuplicate s) 0
  _srvSubQueues <- atomicSwapIORef (srvSubQueues s) 0
  _srvSubEnd <- atomicSwapIORef (srvSubEnd s) 0
  pure
    ServiceStatsData
      { _srvAssocNew,
        _srvAssocDuplicate,
        _srvAssocUpdated,
        _srvAssocRemoved,
        _srvSubCount,
        _srvSubDuplicate,
        _srvSubQueues,
        _srvSubEnd
      }

-- this function is not thread safe, it is used on server start only
setServiceStats :: ServiceStats -> ServiceStatsData -> IO ()
setServiceStats s d = do
  writeIORef (srvAssocNew s) $! _srvAssocNew d
  writeIORef (srvAssocDuplicate s) $! _srvAssocDuplicate d
  writeIORef (srvAssocUpdated s) $! _srvAssocUpdated d
  writeIORef (srvAssocRemoved s) $! _srvAssocRemoved d
  writeIORef (srvSubCount s) $! _srvSubCount d
  writeIORef (srvSubDuplicate s) $! _srvSubDuplicate d
  writeIORef (srvSubQueues s) $! _srvSubQueues d
  writeIORef (srvSubEnd s) $! _srvSubEnd d

instance StrEncoding ServiceStatsData where
  strEncode ServiceStatsData {_srvAssocNew, _srvAssocDuplicate, _srvAssocUpdated, _srvAssocRemoved, _srvSubCount, _srvSubDuplicate, _srvSubQueues, _srvSubEnd} =
    "assocNew="
      <> strEncode _srvAssocNew
      <> "\nassocDuplicate="
      <> strEncode _srvAssocDuplicate
      <> "\nassocUpdatedt="
      <> strEncode _srvAssocUpdated
      <> "\nassocRemoved="
      <> strEncode _srvAssocRemoved
      <> "\nsubCount="
      <> strEncode _srvSubCount
      <> "\nsubDuplicate="
      <> strEncode _srvSubDuplicate
      <> "\nsubQueues="
      <> strEncode _srvSubQueues
      <> "\nsubEnd="
      <> strEncode _srvSubEnd
  strP = do
    _srvAssocNew <- "assocNew=" *> strP <* A.endOfLine
    _srvAssocDuplicate <- "assocDuplicate=" *> strP <* A.endOfLine
    _srvAssocUpdated <- "assocUpdatedt=" *> strP <* A.endOfLine
    _srvAssocRemoved <- "assocRemoved=" *> strP <* A.endOfLine
    _srvSubCount <- "subCount=" *> strP <* A.endOfLine
    _srvSubDuplicate <- "subDuplicate=" *> strP <* A.endOfLine
    _srvSubQueues <- "subQueues=" *> strP <* A.endOfLine
    _srvSubEnd <- "subEnd=" *> strP
    pure
      ServiceStatsData
        { _srvAssocNew,
          _srvAssocDuplicate,
          _srvAssocUpdated,
          _srvAssocRemoved,
          _srvSubCount,
          _srvSubDuplicate,
          _srvSubQueues,
          _srvSubEnd
        }
