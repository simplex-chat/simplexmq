{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Server.Stats where

import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import Data.Time.Clock (UTCTime)
import Simplex.Messaging.Encoding.String
import UnliftIO.STM

data FileServerStats = FileServerStats
  { fromTime :: TVar UTCTime,
    fileCreated :: TVar Int,
    recipientAdded :: TVar Int,
    fileUploaded :: TVar Int,
    fileDeleted :: TVar Int,
    fileDownloaded :: TVar Int,
    ackCalled :: TVar Int
  }

data FileServerStatsData = FileServerStatsData
  { _fromTime :: UTCTime,
    _fileCreated :: Int,
    _recipientAdded :: Int,
    _fileUploaded :: Int,
    _fileDeleted :: Int,
    _fileDownloaded :: Int,
    _ackCalled :: Int
  }

newFileServerStats :: UTCTime -> STM FileServerStats
newFileServerStats ts = do
  fromTime <- newTVar ts
  fileCreated <- newTVar 0
  recipientAdded <- newTVar 0
  fileUploaded <- newTVar 0
  fileDeleted <- newTVar 0
  fileDownloaded <- newTVar 0
  ackCalled <- newTVar 0
  pure FileServerStats {fromTime, fileCreated, recipientAdded, fileUploaded, fileDeleted, fileDownloaded, ackCalled}

getFileServerStatsData :: FileServerStats -> STM FileServerStatsData
getFileServerStatsData s = do
  _fromTime <- readTVar $ fromTime (s :: FileServerStats)
  _fileCreated <- readTVar $ fileCreated s
  _recipientAdded <- readTVar $ recipientAdded s
  _fileUploaded <- readTVar $ fileUploaded s
  _fileDeleted <- readTVar $ fileDeleted s
  _fileDownloaded <- readTVar $ fileDownloaded s
  _ackCalled <- readTVar $ ackCalled s
  pure FileServerStatsData {_fromTime, _fileCreated, _recipientAdded, _fileUploaded, _fileDeleted, _fileDownloaded, _ackCalled}

setFileServerStats :: FileServerStats -> FileServerStatsData -> STM ()
setFileServerStats s d = do
  writeTVar (fromTime (s :: FileServerStats)) (_fromTime (d :: FileServerStatsData))
  writeTVar (fileCreated s) (_fileCreated d)
  writeTVar (recipientAdded s) (_recipientAdded d)
  writeTVar (fileUploaded s) (_fileUploaded d)
  writeTVar (fileDeleted s) (_fileDeleted d)
  writeTVar (fileDownloaded s) (_fileDownloaded d)
  writeTVar (ackCalled s) (_ackCalled d)

instance StrEncoding FileServerStatsData where
  strEncode FileServerStatsData {_fromTime, _fileCreated, _recipientAdded, _fileUploaded, _fileDeleted, _fileDownloaded, _ackCalled} =
    B.unlines
      [ "fromTime=" <> strEncode _fromTime,
        "fileCreated=" <> strEncode _fileCreated,
        "recipientAdded=" <> strEncode _recipientAdded,
        "fileUploaded=" <> strEncode _fileUploaded,
        "fileDeleted=" <> strEncode _fileDeleted,
        "fileDownloaded=" <> strEncode _fileDownloaded,
        "ackCalled=" <> strEncode _ackCalled
      ]
  strP = do
    _fromTime <- "fromTime=" *> strP <* A.endOfLine
    _fileCreated <- "fileCreated=" *> strP <* A.endOfLine
    _recipientAdded <- "recipientAdded=" *> strP <* A.endOfLine
    _fileUploaded <- "fileUploaded=" *> strP <* A.endOfLine
    _fileDeleted <- "fileDeleted=" *> strP <* A.endOfLine
    _fileDownloaded <- "fileDownloaded=" *> strP <* A.endOfLine
    _ackCalled <- "ackCalled=" *> strP <* A.endOfLine
    pure FileServerStatsData {_fromTime, _fileCreated, _recipientAdded, _fileUploaded, _fileDeleted, _fileDownloaded, _ackCalled}
