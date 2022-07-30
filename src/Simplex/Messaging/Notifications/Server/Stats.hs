{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Server.Stats where

import Control.Applicative (optional)
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import Data.Set (Set)
import qualified Data.Set as S
import Data.Time.Clock (UTCTime)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol (NtfTokenId)
import Simplex.Messaging.Protocol (NotifierId)
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
    dayTokens :: TVar (Set NtfTokenId),
    weekTokens :: TVar (Set NtfTokenId),
    monthTokens :: TVar (Set NtfTokenId),
    daySubs :: TVar (Set NotifierId),
    weekSubs :: TVar (Set NotifierId),
    monthSubs :: TVar (Set NotifierId)
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
    _dayTokens :: Set NtfTokenId,
    _weekTokens :: Set NtfTokenId,
    _monthTokens :: Set NtfTokenId,
    _daySubs :: Set NotifierId,
    _weekSubs :: Set NotifierId,
    _monthSubs :: Set NotifierId
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
  dayTokens <- newTVar S.empty
  weekTokens <- newTVar S.empty
  monthTokens <- newTVar S.empty
  daySubs <- newTVar S.empty
  weekSubs <- newTVar S.empty
  monthSubs <- newTVar S.empty
  pure NtfServerStats {fromTime, tknCreated, tknVerified, tknDeleted, subCreated, subDeleted, ntfReceived, ntfDelivered, dayTokens, weekTokens, monthTokens, daySubs, weekSubs, monthSubs}

getNtfServerStatsData :: NtfServerStats -> STM NtfServerStatsData
getNtfServerStatsData s = do
  _fromTime <- readTVar $ fromTime s
  _tknCreated <- readTVar $ tknCreated s
  _tknVerified <- readTVar $ tknVerified s
  _tknDeleted <- readTVar $ tknDeleted s
  _subCreated <- readTVar $ subCreated s
  _subDeleted <- readTVar $ subDeleted s
  _ntfReceived <- readTVar $ ntfReceived s
  _ntfDelivered <- readTVar $ ntfDelivered s
  _dayTokens <- readTVar $ dayTokens s
  _weekTokens <- readTVar $ weekTokens s
  _monthTokens <- readTVar $ monthTokens s
  _daySubs <- readTVar $ daySubs s
  _weekSubs <- readTVar $ weekSubs s
  _monthSubs <- readTVar $ monthSubs s
  pure NtfServerStatsData {_fromTime, _tknCreated, _tknVerified, _tknDeleted, _subCreated, _subDeleted, _ntfReceived, _ntfDelivered, _dayTokens, _weekTokens, _monthTokens, _daySubs, _weekSubs, _monthSubs}

setNtfServerStatsData :: NtfServerStats -> NtfServerStatsData -> STM ()
setNtfServerStatsData s d = do
  writeTVar (fromTime s) (_fromTime d)
  writeTVar (tknCreated s) (_tknCreated d)
  writeTVar (tknVerified s) (_tknVerified d)
  writeTVar (tknDeleted s) (_tknDeleted d)
  writeTVar (subCreated s) (_subCreated d)
  writeTVar (subDeleted s) (_subDeleted d)
  writeTVar (ntfReceived s) (_ntfReceived d)
  writeTVar (ntfDelivered s) (_ntfDelivered d)
  writeTVar (dayTokens s) (_dayTokens d)
  writeTVar (weekTokens s) (_weekTokens d)
  writeTVar (monthTokens s) (_monthTokens d)
  writeTVar (daySubs s) (_daySubs d)
  writeTVar (weekSubs s) (_weekSubs d)
  writeTVar (monthSubs s) (_monthSubs d)

instance StrEncoding NtfServerStatsData where
  strEncode NtfServerStatsData {_fromTime, _tknCreated, _tknVerified, _tknDeleted, _subCreated, _subDeleted, _ntfReceived, _ntfDelivered, _dayTokens, _weekTokens, _monthTokens, _daySubs, _weekSubs, _monthSubs} =
    B.unlines
      [ "fromTime=" <> strEncode _fromTime,
        "tknCreated=" <> strEncode _tknCreated,
        "tknVerified=" <> strEncode _tknVerified,
        "tknDeleted=" <> strEncode _tknDeleted,
        "subCreated=" <> strEncode _subCreated,
        "subDeleted=" <> strEncode _subDeleted,
        "ntfReceived=" <> strEncode _ntfReceived,
        "ntfDelivered=" <> strEncode _ntfDelivered,
        "dayTokens=" <> strEncode _dayTokens,
        "weekTokens=" <> strEncode _weekTokens,
        "monthTokens=" <> strEncode _monthTokens,
        "daySubs=" <> strEncode _daySubs,
        "weekSubs=" <> strEncode _weekSubs,
        "monthSubs=" <> strEncode _monthSubs
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
    _dayTokens <- "dayTokens=" *> strP <* A.endOfLine
    _weekTokens <- "weekTokens=" *> strP <* A.endOfLine
    _monthTokens <- "monthTokens=" *> strP <* A.endOfLine
    _daySubs <- "daySubs=" *> strP <* A.endOfLine
    _weekSubs <- "weekSubs=" *> strP <* A.endOfLine
    _monthSubs <- "monthSubs=" *> strP <* optional A.endOfLine
    pure NtfServerStatsData {_fromTime, _tknCreated, _tknVerified, _tknDeleted, _subCreated, _subDeleted, _ntfReceived, _ntfDelivered, _dayTokens, _weekTokens, _monthTokens, _daySubs, _weekSubs, _monthSubs}
