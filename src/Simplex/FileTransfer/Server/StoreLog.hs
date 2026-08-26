{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Server.StoreLog
  ( StoreLog,
    FileStoreLogRecord (..),
    closeStoreLog,
    readWriteFileStore,
    writeFileStore,
    logAddFile,
    logSetFileExpiration,
    logPutFile,
    logAddRecipients,
    logDeleteFile,
    logBlockFile,
    logAckFile,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent.STM
import Control.Monad.Except
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Composition ((.:))
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Simplex.FileTransfer.Protocol (FileInfo (..))
import Simplex.FileTransfer.Server.Store
import Simplex.FileTransfer.Transport (XFTPErrorType (..))
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (BlockingInfo, RcvPublicAuthKey, RecipientId, SenderId)
import Simplex.Messaging.Server.QueueStore (ServerEntityStatus (..))
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.Util (bshow)
import System.IO

data FileStoreLogRecord
  = AddFile SenderId FileInfo RoundedFileTime (Maybe RoundedFileTime) Bool ServerEntityStatus
  | PutFile SenderId FilePath
  | AddRecipients SenderId (NonEmpty FileRecipient)
  | DeleteFile SenderId
  | BlockFile SenderId BlockingInfo
  | AckFile RecipientId -- TODO add senderId as well?
  | SetFileExpiration SenderId (Maybe RoundedFileTime) Bool
  deriving (Show)

instance StrEncoding FileStoreLogRecord where
  strEncode = \case
    AddFile sId file createdAt expiresAt permanent status -> strEncode (Str "FNEW", sId, file, createdAt, status) <> permExpE permanent expiresAt
    PutFile sId path -> strEncode (Str "FPUT", sId, path)
    AddRecipients sId rcps -> strEncode (Str "FADD", sId, rcps)
    DeleteFile sId -> strEncode (Str "FDEL", sId)
    BlockFile sId info -> strEncode (Str "FBLK", sId, info)
    AckFile rId -> strEncode (Str "FACK", rId)
    SetFileExpiration sId expiresAt permanent -> strEncode (Str "FTTL", sId) <> permExpE permanent expiresAt
    where
      permExpE permanent expiresAt = " " <> (if permanent then "T" else "F") <> maybe "" ((" " <>) . strEncode) expiresAt
  strP =
    A.choice
      [ "FNEW " *> addFileP,
        "FPUT " *> (PutFile <$> strP_ <*> strP),
        "FADD " *> (AddRecipients <$> strP_ <*> strP),
        "FDEL " *> (DeleteFile <$> strP),
        "FBLK " *> (BlockFile <$> strP_ <*> strP),
        "FACK " *> (AckFile <$> strP),
        "FTTL " *> (setP <$> strP <*> permExpP)
      ]
    where
      addFileP = do
        sId <- strP_
        file <- strP_
        createdAt <- strP
        status <- _strP <|> pure EntityActive
        (expiresAt, permanent) <- permExpP
        pure $ AddFile sId file createdAt expiresAt permanent status
      setP sId (expiresAt, permanent) = SetFileExpiration sId expiresAt permanent
      permExpP = do
        permanent <- (A.space *> permP) <|> pure False
        expiresAt <- (A.space *> (Just <$> strP)) <|> pure Nothing
        pure (expiresAt, permanent)
      permP = (True <$ A.char 'T') <|> (False <$ A.char 'F')

logFileStoreRecord :: StoreLog 'WriteMode -> FileStoreLogRecord -> IO ()
logFileStoreRecord = writeStoreLogRecord

logAddFile :: StoreLog 'WriteMode -> SenderId -> FileInfo -> RoundedFileTime -> Maybe RoundedFileTime -> Bool -> ServerEntityStatus -> IO ()
logAddFile s sId file createdAt expiresAt permanent status = logFileStoreRecord s $ AddFile sId file createdAt expiresAt permanent status

logSetFileExpiration :: StoreLog 'WriteMode -> SenderId -> Maybe RoundedFileTime -> Bool -> IO ()
logSetFileExpiration s sId expiresAt permanent = logFileStoreRecord s $ SetFileExpiration sId expiresAt permanent

logPutFile :: StoreLog 'WriteMode -> SenderId -> FilePath -> IO ()
logPutFile s = logFileStoreRecord s .: PutFile

logAddRecipients :: StoreLog 'WriteMode -> SenderId -> NonEmpty FileRecipient -> IO ()
logAddRecipients s = logFileStoreRecord s .: AddRecipients

logDeleteFile :: StoreLog 'WriteMode -> SenderId -> IO ()
logDeleteFile s = logFileStoreRecord s . DeleteFile

logBlockFile :: StoreLog 'WriteMode -> SenderId -> BlockingInfo -> IO ()
logBlockFile s fId = logFileStoreRecord s . BlockFile fId

logAckFile :: StoreLog 'WriteMode -> RecipientId -> IO ()
logAckFile s = logFileStoreRecord s . AckFile

readWriteFileStore :: FilePath -> STMFileStore -> IO (StoreLog 'WriteMode)
readWriteFileStore = readWriteStoreLog readFileStore writeFileStore

readFileStore :: FilePath -> STMFileStore -> IO ()
readFileStore f st = mapM_ (addFileLogRecord . LB.toStrict) . LB.lines =<< LB.readFile f
  where
    addFileLogRecord s = case strDecode s of
      Left e -> B.putStrLn $ "Log parsing error (" <> B.pack e <> "): " <> B.take 100 s
      Right lr ->
        addToStore lr >>= \case
          Left e -> B.putStrLn $ "Log processing error (" <> bshow e <> "): " <> B.take 100 s
          _ -> pure ()
    addToStore = \case
      AddFile sId file createdAt expiresAt permanent status
        | size file > 0 -> addFile st sId file createdAt expiresAt permanent status
        | otherwise -> pure $ Left SIZE
      PutFile qId path -> setFilePath st qId path
      AddRecipients sId rcps -> runExceptT $ addRecipients sId rcps
      DeleteFile sId -> deleteFile st sId
      BlockFile sId info -> blockFile st sId info True
      AckFile rId -> ackFile st rId
      SetFileExpiration sId expiresAt permanent -> setFileExpiration st sId expiresAt permanent
    addRecipients sId rcps = mapM_ (ExceptT . addRecipient st sId) rcps

writeFileStore :: StoreLog 'WriteMode -> STMFileStore -> IO ()
writeFileStore s STMFileStore {files, recipients} = do
  allRcps <- readTVarIO recipients
  readTVarIO files >>= mapM_ (logFile allRcps)
  where
    logFile :: Map RecipientId (SenderId, RcvPublicAuthKey) -> FileRec -> IO ()
    logFile allRcps FileRec {senderId, fileInfo, filePath, recipientIds, createdAt, expiresAt, permanent, fileStatus} = do
      status <- readTVarIO fileStatus
      logAddFile s senderId fileInfo createdAt expiresAt permanent status
      (rcpErrs, rcps) <- M.mapEither getRcp . M.fromSet id <$> readTVarIO recipientIds
      mapM_ (logAddRecipients s senderId) $ L.nonEmpty $ M.elems rcps
      mapM_ (B.putStrLn . ("Error storing log: " <>)) rcpErrs
      readTVarIO filePath >>= mapM_ (logPutFile s senderId)
      where
        getRcp rId = case M.lookup rId allRcps of
          Just (sndId, rKey)
            | sndId == senderId -> Right $ FileRecipient rId rKey
            | otherwise -> Left $ "sender ID for recipient ID " <> bshow rId <> " does not match FileRec"
          Nothing -> Left $ "recipient ID " <> bshow rId <> " not found"
