{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Server.Stats where

import Control.Applicative ((<|>))
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import Data.IORef
import Data.Int (Int64)
import Data.Time.Clock (UTCTime)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Server.Stats (PeriodStats, PeriodStatsData, getPeriodStatsData, newPeriodStats, setPeriodStats)

data FileServerStats = FileServerStats
  { fromTime :: IORef UTCTime,
    filesCreated :: IORef Int,
    fileRecipients :: IORef Int,
    filesUploaded :: IORef Int,
    filesExpired :: IORef Int,
    filesDeleted :: IORef Int,
    filesBlocked :: IORef Int,
    filesDownloaded :: PeriodStats,
    fileDownloads :: IORef Int,
    fileDownloadAcks :: IORef Int,
    filesCount :: IORef Int,
    filesSize :: IORef Int64
  }

data FileServerStatsData = FileServerStatsData
  { _fromTime :: UTCTime,
    _filesCreated :: Int,
    _fileRecipients :: Int,
    _filesUploaded :: Int,
    _filesExpired :: Int,
    _filesDeleted :: Int,
    _filesBlocked :: Int,
    _filesDownloaded :: PeriodStatsData,
    _fileDownloads :: Int,
    _fileDownloadAcks :: Int,
    _filesCount :: Int,
    _filesSize :: Int64
  }
  deriving (Show)

newFileServerStats :: UTCTime -> IO FileServerStats
newFileServerStats ts = do
  fromTime <- newIORef ts
  filesCreated <- newIORef 0
  fileRecipients <- newIORef 0
  filesUploaded <- newIORef 0
  filesExpired <- newIORef 0
  filesDeleted <- newIORef 0
  filesBlocked <- newIORef 0
  filesDownloaded <- newPeriodStats
  fileDownloads <- newIORef 0
  fileDownloadAcks <- newIORef 0
  filesCount <- newIORef 0
  filesSize <- newIORef 0
  pure FileServerStats {fromTime, filesCreated, fileRecipients, filesUploaded, filesExpired, filesDeleted, filesBlocked, filesDownloaded, fileDownloads, fileDownloadAcks, filesCount, filesSize}

getFileServerStatsData :: FileServerStats -> IO FileServerStatsData
getFileServerStatsData s = do
  _fromTime <- readIORef $ fromTime (s :: FileServerStats)
  _filesCreated <- readIORef $ filesCreated s
  _fileRecipients <- readIORef $ fileRecipients s
  _filesUploaded <- readIORef $ filesUploaded s
  _filesExpired <- readIORef $ filesExpired s
  _filesDeleted <- readIORef $ filesDeleted s
  _filesBlocked <- readIORef $ filesBlocked s
  _filesDownloaded <- getPeriodStatsData $ filesDownloaded s
  _fileDownloads <- readIORef $ fileDownloads s
  _fileDownloadAcks <- readIORef $ fileDownloadAcks s
  _filesCount <- readIORef $ filesCount s
  _filesSize <- readIORef $ filesSize s
  pure FileServerStatsData {_fromTime, _filesCreated, _fileRecipients, _filesUploaded, _filesExpired, _filesDeleted, _filesBlocked, _filesDownloaded, _fileDownloads, _fileDownloadAcks, _filesCount, _filesSize}

-- this function is not thread safe, it is used on server start only
setFileServerStats :: FileServerStats -> FileServerStatsData -> IO ()
setFileServerStats s d = do
  writeIORef (fromTime (s :: FileServerStats)) $! _fromTime (d :: FileServerStatsData)
  writeIORef (filesCreated s) $! _filesCreated d
  writeIORef (fileRecipients s) $! _fileRecipients d
  writeIORef (filesUploaded s) $! _filesUploaded d
  writeIORef (filesExpired s) $! _filesExpired d
  writeIORef (filesDeleted s) $! _filesDeleted d
  writeIORef (filesBlocked s) $! _filesBlocked d
  setPeriodStats (filesDownloaded s) $! _filesDownloaded d
  writeIORef (fileDownloads s) $! _fileDownloads d
  writeIORef (fileDownloadAcks s) $! _fileDownloadAcks d
  writeIORef (filesCount s) $! _filesCount d
  writeIORef (filesSize s) $! _filesSize d

instance StrEncoding FileServerStatsData where
  strEncode FileServerStatsData {_fromTime, _filesCreated, _fileRecipients, _filesUploaded, _filesExpired, _filesDeleted, _filesBlocked, _filesDownloaded, _fileDownloads, _fileDownloadAcks, _filesCount, _filesSize} =
    B.unlines
      [ "fromTime=" <> strEncode _fromTime,
        "filesCreated=" <> strEncode _filesCreated,
        "fileRecipients=" <> strEncode _fileRecipients,
        "filesUploaded=" <> strEncode _filesUploaded,
        "filesExpired=" <> strEncode _filesExpired,
        "filesDeleted=" <> strEncode _filesDeleted,
        "filesBlocked=" <> strEncode _filesBlocked,
        "filesCount=" <> strEncode _filesCount,
        "filesSize=" <> strEncode _filesSize,
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
    _filesExpired <- "filesExpired=" *> strP <* A.endOfLine <|> pure 0
    _filesDeleted <- "filesDeleted=" *> strP <* A.endOfLine
    _filesBlocked <- opt "filesBlocked="
    _filesCount <- "filesCount=" *> strP <* A.endOfLine <|> pure 0
    _filesSize <- "filesSize=" *> strP <* A.endOfLine <|> pure 0
    _filesDownloaded <- "filesDownloaded:" *> A.endOfLine *> strP <* A.endOfLine
    _fileDownloads <- "fileDownloads=" *> strP <* A.endOfLine
    _fileDownloadAcks <- "fileDownloadAcks=" *> strP <* A.endOfLine
    pure FileServerStatsData {_fromTime, _filesCreated, _fileRecipients, _filesUploaded, _filesExpired, _filesDeleted, _filesBlocked, _filesDownloaded, _fileDownloads, _fileDownloadAcks, _filesCount, _filesSize}
    where
      opt s = A.string s *> strP <* A.endOfLine <|> pure 0
