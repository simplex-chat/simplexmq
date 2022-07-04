{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.Stats where

import Control.Applicative (optional)
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import Data.Set (Set)
import qualified Data.Set as S
import Data.Time.Clock (UTCTime)
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
    dayMsgQueues :: TVar (Set RecipientId),
    weekMsgQueues :: TVar (Set RecipientId),
    monthMsgQueues :: TVar (Set RecipientId)
  }

data ServerStatsData = ServerStatsData
  { _fromTime :: UTCTime,
    _qCreated :: Int,
    _qSecured :: Int,
    _qDeleted :: Int,
    _msgSent :: Int,
    _msgRecv :: Int,
    _dayMsgQueues :: Set RecipientId,
    _weekMsgQueues :: Set RecipientId,
    _monthMsgQueues :: Set RecipientId
  }

newServerStats :: UTCTime -> STM ServerStats
newServerStats ts = do
  fromTime <- newTVar ts
  qCreated <- newTVar 0
  qSecured <- newTVar 0
  qDeleted <- newTVar 0
  msgSent <- newTVar 0
  msgRecv <- newTVar 0
  dayMsgQueues <- newTVar S.empty
  weekMsgQueues <- newTVar S.empty
  monthMsgQueues <- newTVar S.empty
  pure ServerStats {fromTime, qCreated, qSecured, qDeleted, msgSent, msgRecv, dayMsgQueues, weekMsgQueues, monthMsgQueues}

getServerStatsData :: ServerStats -> STM ServerStatsData
getServerStatsData s = do
  _fromTime <- readTVar $ fromTime s
  _qCreated <- readTVar $ qCreated s
  _qSecured <- readTVar $ qSecured s
  _qDeleted <- readTVar $ qDeleted s
  _msgSent <- readTVar $ msgSent s
  _msgRecv <- readTVar $ msgRecv s
  _dayMsgQueues <- readTVar $ dayMsgQueues s
  _weekMsgQueues <- readTVar $ weekMsgQueues s
  _monthMsgQueues <- readTVar $ monthMsgQueues s
  pure ServerStatsData {_fromTime, _qCreated, _qSecured, _qDeleted, _msgSent, _msgRecv, _dayMsgQueues, _weekMsgQueues, _monthMsgQueues}

setServerStatsData :: ServerStats -> ServerStatsData -> STM ()
setServerStatsData s d = do
  writeTVar (fromTime s) (_fromTime d)
  writeTVar (qCreated s) (_qCreated d)
  writeTVar (qSecured s) (_qSecured d)
  writeTVar (qDeleted s) (_qDeleted d)
  writeTVar (msgSent s) (_msgSent d)
  writeTVar (msgRecv s) (_msgRecv d)
  writeTVar (dayMsgQueues s) (_dayMsgQueues d)
  writeTVar (weekMsgQueues s) (_weekMsgQueues d)
  writeTVar (monthMsgQueues s) (_monthMsgQueues d)

instance StrEncoding ServerStatsData where
  strEncode ServerStatsData {_fromTime, _qCreated, _qSecured, _qDeleted, _msgSent, _msgRecv, _dayMsgQueues, _weekMsgQueues, _monthMsgQueues} =
    B.unlines
      [ "fromTime=" <> strEncode _fromTime,
        "qCreated=" <> strEncode _qCreated,
        "qSecured=" <> strEncode _qSecured,
        "qDeleted=" <> strEncode _qDeleted,
        "msgSent=" <> strEncode _msgSent,
        "msgRecv=" <> strEncode _msgRecv,
        "dayMsgQueues=" <> strEncode _dayMsgQueues,
        "weekMsgQueues=" <> strEncode _weekMsgQueues,
        "monthMsgQueues=" <> strEncode _monthMsgQueues
      ]
  strP = do
    _fromTime <- "fromTime=" *> strP <* A.endOfLine
    _qCreated <- "qCreated=" *> strP <* A.endOfLine
    _qSecured <- "qSecured=" *> strP <* A.endOfLine
    _qDeleted <- "qDeleted=" *> strP <* A.endOfLine
    _msgSent <- "msgSent=" *> strP <* A.endOfLine
    _msgRecv <- "msgRecv=" *> strP <* A.endOfLine
    _dayMsgQueues <- "dayMsgQueues=" *> strP <* A.endOfLine
    _weekMsgQueues <- "weekMsgQueues=" *> strP <* A.endOfLine
    _monthMsgQueues <- "monthMsgQueues=" *> strP <* optional A.endOfLine
    pure ServerStatsData {_fromTime, _qCreated, _qSecured, _qDeleted, _msgSent, _msgRecv, _dayMsgQueues, _weekMsgQueues, _monthMsgQueues}
