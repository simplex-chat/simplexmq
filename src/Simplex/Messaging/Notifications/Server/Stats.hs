{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Server.Stats
  ( NtfServerStats (..),
    NtfServerStatsData (..),
    StatsByServer,
    StatsByServerData (..),
    newNtfServerStats,
    getNtfServerStatsData,
    setNtfServerStats,
    getStatsByServer,
    setStatsByServer,
    incServerStat,
  )
where

import Control.Applicative (optional, (<|>))
import Control.Concurrent.STM
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import Data.IORef
import qualified Data.Map.Strict as M
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Server.Stats
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM

data NtfServerStats = NtfServerStats
  { fromTime :: IORef UTCTime,
    tknCreated :: IORef Int,
    tknVerified :: IORef Int,
    tknDeleted :: IORef Int,
    tknReplaced :: IORef Int,
    subCreated :: IORef Int,
    subDeleted :: IORef Int,
    ntfReceived :: IORef Int,
    ntfReceivedAuth :: IORef Int,
    ntfDelivered :: IORef Int,
    ntfFailed :: IORef Int,
    ntfReceivedOwn :: StatsByServer,
    ntfReceivedAuthOwn :: StatsByServer,
    ntfDeliveredOwn :: StatsByServer,
    ntfFailedOwn :: StatsByServer,
    ntfCronDelivered :: IORef Int,
    ntfCronFailed :: IORef Int,
    ntfVrfQueued :: IORef Int,
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
    _tknReplaced :: Int,
    _subCreated :: Int,
    _subDeleted :: Int,
    _ntfReceived :: Int,
    _ntfReceivedAuth :: Int,
    _ntfDelivered :: Int,
    _ntfFailed :: Int,
    _ntfReceivedOwn :: StatsByServerData,
    _ntfReceivedAuthOwn :: StatsByServerData,
    _ntfDeliveredOwn :: StatsByServerData,
    _ntfFailedOwn :: StatsByServerData,
    _ntfCronDelivered :: Int,
    _ntfCronFailed :: Int,
    _ntfVrfQueued :: Int,
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
  tknReplaced <- newIORef 0
  subCreated <- newIORef 0
  subDeleted <- newIORef 0
  ntfReceived <- newIORef 0
  ntfReceivedAuth <- newIORef 0
  ntfDelivered <- newIORef 0
  ntfFailed <- newIORef 0
  ntfReceivedOwn <- TM.emptyIO
  ntfReceivedAuthOwn <- TM.emptyIO
  ntfDeliveredOwn <- TM.emptyIO
  ntfFailedOwn <- TM.emptyIO
  ntfCronDelivered <- newIORef 0
  ntfCronFailed <- newIORef 0
  ntfVrfQueued <- newIORef 0
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
        tknReplaced,
        subCreated,
        subDeleted,
        ntfReceived,
        ntfReceivedAuth,
        ntfDelivered,
        ntfFailed,
        ntfReceivedOwn,
        ntfReceivedAuthOwn,
        ntfDeliveredOwn,
        ntfFailedOwn,
        ntfCronDelivered,
        ntfCronFailed,
        ntfVrfQueued,
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
  _tknReplaced <- readIORef $ tknReplaced s
  _subCreated <- readIORef $ subCreated s
  _subDeleted <- readIORef $ subDeleted s
  _ntfReceived <- readIORef $ ntfReceived s
  _ntfReceivedAuth <- readIORef $ ntfReceivedAuth s
  _ntfDelivered <- readIORef $ ntfDelivered s
  _ntfFailed <- readIORef $ ntfFailed s
  _ntfReceivedOwn <- getStatsByServer $ ntfReceivedOwn s
  _ntfReceivedAuthOwn <- getStatsByServer $ ntfReceivedAuthOwn s
  _ntfDeliveredOwn <- getStatsByServer $ ntfDeliveredOwn s
  _ntfFailedOwn <- getStatsByServer $ ntfFailedOwn s
  _ntfCronDelivered <- readIORef $ ntfCronDelivered s
  _ntfCronFailed <- readIORef $ ntfCronFailed s
  _ntfVrfQueued <- readIORef $ ntfVrfQueued s
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
        _tknReplaced,
        _subCreated,
        _subDeleted,
        _ntfReceived,
        _ntfReceivedAuth,
        _ntfDelivered,
        _ntfFailed,
        _ntfReceivedOwn,
        _ntfReceivedAuthOwn,
        _ntfDeliveredOwn,
        _ntfFailedOwn,
        _ntfCronDelivered,
        _ntfCronFailed,
        _ntfVrfQueued,
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
  writeIORef (tknReplaced s) $! _tknReplaced d
  writeIORef (subCreated s) $! _subCreated d
  writeIORef (subDeleted s) $! _subDeleted d
  writeIORef (ntfReceived s) $! _ntfReceived d
  writeIORef (ntfReceivedAuth s) $! _ntfReceivedAuth d
  writeIORef (ntfDelivered s) $! _ntfDelivered d
  writeIORef (ntfFailed s) $! _ntfFailed d
  setStatsByServer (ntfReceivedOwn s) $! _ntfReceivedOwn d
  setStatsByServer (ntfReceivedAuthOwn s) $! _ntfReceivedAuthOwn d
  setStatsByServer (ntfDeliveredOwn s) $! _ntfDeliveredOwn d
  setStatsByServer (ntfFailedOwn s) $! _ntfFailedOwn d
  writeIORef (ntfCronDelivered s) $! _ntfCronDelivered d
  writeIORef (ntfCronFailed s) $! _ntfCronFailed d
  writeIORef (ntfVrfQueued s) $! _ntfVrfQueued d
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
        _tknReplaced,
        _subCreated,
        _subDeleted,
        _ntfReceived,
        _ntfReceivedAuth,
        _ntfDelivered,
        _ntfFailed,
        _ntfReceivedOwn,
        _ntfReceivedAuthOwn,
        _ntfDeliveredOwn,
        _ntfFailedOwn,
        _ntfCronDelivered,
        _ntfCronFailed,
        _ntfVrfQueued,
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
        "tknReplaced=" <> strEncode _tknReplaced,
        "subCreated=" <> strEncode _subCreated,
        "subDeleted=" <> strEncode _subDeleted,
        "ntfReceived=" <> strEncode _ntfReceived,
        "ntfReceivedAuth=" <> strEncode _ntfReceivedAuth,
        "ntfDelivered=" <> strEncode _ntfDelivered,
        "ntfFailed=" <> strEncode _ntfFailed,
        "ntfReceivedOwn=" <> strEncode _ntfReceivedOwn,
        "ntfReceivedAuthOwn=" <> strEncode _ntfReceivedAuthOwn,
        "ntfDeliveredOwn=" <> strEncode _ntfDeliveredOwn,
        "ntfFailedOwn=" <> strEncode _ntfFailedOwn,
        "ntfCronDelivered=" <> strEncode _ntfCronDelivered,
        "ntfCronFailed=" <> strEncode _ntfCronFailed,
        "ntfVrfQueued=" <> strEncode _ntfVrfQueued,
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
    _tknReplaced <- opt "tknReplaced="
    _subCreated <- "subCreated=" *> strP <* A.endOfLine
    _subDeleted <- "subDeleted=" *> strP <* A.endOfLine
    _ntfReceived <- "ntfReceived=" *> strP <* A.endOfLine
    _ntfReceivedAuth <- opt "ntfReceivedAuth="
    _ntfDelivered <- "ntfDelivered=" *> strP <* A.endOfLine
    _ntfFailed <- opt "ntfFailed="
    _ntfReceivedOwn <- statByServerP "ntfReceivedOwn="
    _ntfReceivedAuthOwn <- statByServerP "ntfReceivedAuthOwn="
    _ntfDeliveredOwn <- statByServerP "ntfDeliveredOwn="
    _ntfFailedOwn <- statByServerP "ntfFailedOwn="
    _ntfCronDelivered <- opt "ntfCronDelivered="
    _ntfCronFailed <- opt "ntfCronFailed="
    _ntfVrfQueued <- opt "ntfVrfQueued="
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
          _tknReplaced,
          _subCreated,
          _subDeleted,
          _ntfReceived,
          _ntfReceivedAuth,
          _ntfDelivered,
          _ntfFailed,
          _ntfReceivedOwn,
          _ntfReceivedAuthOwn,
          _ntfDeliveredOwn,
          _ntfFailedOwn,
          _ntfCronDelivered,
          _ntfCronFailed,
          _ntfVrfQueued,
          _ntfVrfDelivered,
          _ntfVrfFailed,
          _ntfVrfInvalidTkn,
          _activeTokens,
          _activeSubs
        }
    where
      opt s = A.string s *> strP <* A.endOfLine <|> pure 0
      statByServerP s = A.string s *> strP <* A.endOfLine <|> pure (StatsByServerData [])

type StatsByServer = TMap Text (TVar Int)

newtype StatsByServerData = StatsByServerData [(Text, Int)]

instance StrEncoding StatsByServerData where
  strEncode (StatsByServerData d) = strEncodeList d
  strP = StatsByServerData <$> serverP `A.sepBy'` A.char ','
    where
      serverP = (,) <$> strP_ <*> A.decimal

getStatsByServer :: TMap Text (TVar Int) -> IO StatsByServerData
getStatsByServer s = readTVarIO s >>= fmap (StatsByServerData . M.toList) . mapM readTVarIO

setStatsByServer :: TMap Text (TVar Int) -> StatsByServerData -> IO ()
setStatsByServer s (StatsByServerData d) = mapM newTVarIO (M.fromList d) >>= atomically . writeTVar s

-- double lookup avoids STM transaction with a shared map in most cases
incServerStat :: Text -> TMap Text (TVar Int) -> IO ()
incServerStat h s = TM.lookupIO h s >>= atomically . maybe newServerStat (`modifyTVar'` (+ 1))
  where
    newServerStat = TM.lookup h s >>= maybe (TM.insertM h (newTVar 1) s) (`modifyTVar'` (+ 1))
