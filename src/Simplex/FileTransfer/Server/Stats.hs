{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Server.Stats where

import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import Data.Int (Int64)
import Data.Time.Clock (UTCTime)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (SenderId)
import Simplex.Messaging.Server.Stats (PeriodStats, PeriodStatsData, getPeriodStatsData, newPeriodStats, setPeriodStats)
import UnliftIO.STM

data FileServerStats = FileServerStats
  { fromTime :: TVar UTCTime,
    filesCreated :: TVar Int,
    fileRecipients :: TVar Int,
    filesUploaded :: TVar Int,
    filesDeleted :: TVar Int,
    filesDownloaded :: PeriodStats SenderId,
    fileDownloads :: TVar Int,
    fileDownloadAcks :: TVar Int,
    filesCount :: TVar Int,
    filesSize :: TVar Int64
  }

data FileServerStatsData = FileServerStatsData
  { _fromTime :: UTCTime,
    _filesCreated :: Int,
    _fileRecipients :: Int,
    _filesUploaded :: Int,
    _filesDeleted :: Int,
    _filesDownloaded :: PeriodStatsData SenderId,
    _fileDownloads :: Int,
    _fileDownloadAcks :: Int,
    _filesCount :: Int,
    _filesSize :: Int64
  }
  deriving (Show)

newFileServerStats :: UTCTime -> STM FileServerStats
newFileServerStats ts = do
  fromTime <- newTVar ts
  filesCreated <- newTVar 0
  fileRecipients <- newTVar 0
  filesUploaded <- newTVar 0
  filesDeleted <- newTVar 0
  filesDownloaded <- newPeriodStats
  fileDownloads <- newTVar 0
  fileDownloadAcks <- newTVar 0
  filesCount <- newTVar 0
  filesSize <- newTVar 0
  pure FileServerStats {fromTime, filesCreated, fileRecipients, filesUploaded, filesDeleted, filesDownloaded, fileDownloads, fileDownloadAcks, filesCount, filesSize}

getFileServerStatsData :: FileServerStats -> STM FileServerStatsData
getFileServerStatsData s = do
  _fromTime <- readTVar $ fromTime (s :: FileServerStats)
  _filesCreated <- readTVar $ filesCreated s
  _fileRecipients <- readTVar $ fileRecipients s
  _filesUploaded <- readTVar $ filesUploaded s
  _filesDeleted <- readTVar $ filesDeleted s
  _filesDownloaded <- getPeriodStatsData $ filesDownloaded s
  _fileDownloads <- readTVar $ fileDownloads s
  _fileDownloadAcks <- readTVar $ fileDownloadAcks s
  _filesCount <- readTVar $ filesCount s
  _filesSize <- readTVar $ filesSize s
  pure FileServerStatsData {_fromTime, _filesCreated, _fileRecipients, _filesUploaded, _filesDeleted, _filesDownloaded, _fileDownloads, _fileDownloadAcks, _filesCount, _filesSize}

setFileServerStats :: FileServerStats -> FileServerStatsData -> STM ()
setFileServerStats s d = do
  writeTVar (fromTime (s :: FileServerStats)) $! _fromTime (d :: FileServerStatsData)
  writeTVar (filesCreated s) $! _filesCreated d
  writeTVar (fileRecipients s) $! _fileRecipients d
  writeTVar (filesUploaded s) $! _filesUploaded d
  writeTVar (filesDeleted s) $! _filesDeleted d
  setPeriodStats (filesDownloaded s) $! _filesDownloaded d
  writeTVar (fileDownloads s) $! _fileDownloads d
  writeTVar (fileDownloadAcks s) $! _fileDownloadAcks d
  writeTVar (filesCount s) $! _filesCount d
  writeTVar (filesSize s) $! _filesSize d

instance StrEncoding FileServerStatsData where
  strEncode FileServerStatsData {_fromTime, _filesCreated, _fileRecipients, _filesUploaded, _filesDeleted, _filesDownloaded, _fileDownloads, _fileDownloadAcks} =
    B.unlines
      [ "fromTime=" <> strEncode _fromTime,
        "filesCreated=" <> strEncode _filesCreated,
        "fileRecipients=" <> strEncode _fileRecipients,
        "filesUploaded=" <> strEncode _filesUploaded,
        "filesDeleted=" <> strEncode _filesDeleted,
        "filesDownloaded:",
        strEncode _filesDownloaded,
        "fileDownloads=" <> strEncode _fileDownloads,
        "fileDownloadAcks=" <> strEncode _fileDownloadAcks
      ]
  strP = do
    _fromTime <- "fromTime=" *> strP <* A.endOfLine
    _filesCreated <- "filesCreated=" *> strP <* A.endOfLine
    _fileRecipients <- "fileRecipients=" *> strP <* A.endOfLine
    _filesUploaded <- "filesUploaded=" *> strP <* A.endOfLine
    _filesDeleted <- "filesDeleted=" *> strP <* A.endOfLine
    _filesDownloaded <- "filesDownloaded:" *> A.endOfLine *> strP <* A.endOfLine
    _fileDownloads <- "fileDownloads=" *> strP <* A.endOfLine
    _fileDownloadAcks <- "fileDownloadAcks=" *> strP <* A.endOfLine
    pure FileServerStatsData {_fromTime, _filesCreated, _fileRecipients, _filesUploaded, _filesDeleted, _filesDownloaded, _fileDownloads, _fileDownloadAcks, _filesCount = 0, _filesSize = 0}
