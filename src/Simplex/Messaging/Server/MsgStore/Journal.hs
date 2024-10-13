{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.Messaging.Server.MsgStore.Journal where

import Control.Concurrent.STM
import Crypto.Random (ChaChaDRG)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Set (Set)
import Simplex.Messaging.Agent.Lock
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (Message (..), MsgId, RecipientId)
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (ifM)
import System.Directory
import System.FilePath ((</>))
import System.IO (Handle, IOMode (..), SeekMode (..), openFile, hSeek)

data JournalMsgStore = JournalMsgStore
  { storePath :: FilePath,
    pathParts :: Int,
    random :: TVar ChaChaDRG,
    msgQueues :: TMap RecipientId (TMVar JournalMsgQueue)
  }

data JournalMsgQueue = JournalMsgQueue
  { queueDirectory :: FilePath,
    queueLock :: Lock,
    writeJournal :: TVar (JournalFile 'WriteMode),
    readJournal :: TVar (JournalFile 'ReadMode),
    -- path and handle queue state log file,
    -- it rotates and removes old backups when server is restarted
    statePath :: FilePath,
    stateHandle :: Handle,
    quota :: Int,
    canWrite :: TVar Bool,
    size :: TVar Int
  }

data JournalFile a = JournalFile
  { mode :: JFMode a,
    path :: FilePath,
    journalId :: ByteString,
    handle :: Handle,
    msgPos :: Int,
    msgCount :: Int,
    bytePos :: Int
  }

data JFMode (a :: IOMode) where
  JFReadMode :: JFMode 'ReadMode
  JFWriteMode :: JFMode 'WriteMode

data MsgQueueState = MsgQueueState
  { writeState :: JournalState,
    readState :: JournalState
  }

data JournalState = JournalState
  { journalId :: ByteString,
    msgPos :: Int,
    msgCount :: Int,
    bytePos :: Int
  }

newJournalMsgStore :: FilePath -> Int -> TVar ChaChaDRG -> IO JournalMsgStore
newJournalMsgStore storePath pathParts random = do
  msgQueues <- TM.emptyIO
  pure JournalMsgStore {storePath, pathParts, random, msgQueues}

emptyMsgQueueState :: ByteString -> MsgQueueState
emptyMsgQueueState journalId =
  let st = JournalState {journalId, msgPos = 0, msgCount = 0, bytePos = 0}
   in MsgQueueState {writeState = st, readState = st}

journalFilePath :: FilePath -> ByteString -> FilePath
journalFilePath dir journalId = dir </> (msgLogFileName <> "." <> B.unpack journalId <> logFileExt)

instance StrEncoding JournalState where
  strEncode JournalState {journalId, msgPos, msgCount, bytePos} = strEncode (journalId, msgPos, msgCount, bytePos)
  strP = do
    (journalId, msgPos, msgCount, bytePos) <- strP
    pure JournalState {journalId, msgPos, msgCount, bytePos}

queueLogFileName :: String
queueLogFileName = "queue_state"

msgLogFileName :: String
msgLogFileName = "messages"

logFileExt :: String
logFileExt = ".log"

instance MsgStoreClass JournalMsgStore where
  type MessageQueue JournalMsgStore = JournalMsgQueue
  getMsgQueueIds :: JournalMsgStore -> IO (Set RecipientId)
  getMsgQueueIds = fmap M.keysSet . readTVarIO . msgQueues

  getMsgQueue :: JournalMsgStore -> RecipientId -> Int -> IO JournalMsgQueue
  getMsgQueue st@JournalMsgStore {msgQueues, random = g} rId quota =
    TM.lookupIO rId msgQueues >>= maybe maybeNewIO (atomically . readTMVar)
    where
      maybeNewIO :: IO JournalMsgQueue
      maybeNewIO = atomically maybeNew >>= either newQ (atomically . readTMVar)
      maybeNew :: STM (Either (TMVar JournalMsgQueue) (TMVar JournalMsgQueue))
      maybeNew =
        TM.lookup rId msgQueues >>= \case
          Just v -> pure $ Right v
          Nothing -> newEmptyTMVar >>= \v -> TM.insert rId v msgQueues $> Left v
      newQ v = do
        let dir = msgQueueDirectory st rId
            sp = dir </> (queueLogFileName <> logFileExt)
        q <- mkJournalQueue dir sp =<< ifM (doesDirectoryExist dir) (openQ dir sp) (createQ dir sp)
        atomically $ writeTMVar v q
        pure q
        where
          openQ dir statePath = do
            st <- readWriteQueueState dir statePath
            sh <- openFile statePath AppendMode
            wj <- openWriteJournal dir $ writeState st
            rj <- openReadJournal dir $ readState st
            pure (sh, wj, rj, st)
          createQ dir statePath = do
            createDirectoryIfMissing True dir
            putStrLn "createQ 1"
            sh <- openFile statePath AppendMode
            B.hPutStr sh ""
            putStrLn "createQ 2"
            wj@JournalFile {journalId} <- createNewWriteJournal g dir
            putStrLn "createQ 3"
            rj <- openNewReadJournal wj
            putStrLn "createQ 4"
            pure (sh, wj, rj, emptyMsgQueueState journalId)
          mkJournalQueue dir statePath (stateHandle, wj, rj, st) = do
            writeJournal <- newTVarIO wj
            readJournal <- newTVarIO rj
            queueLock <- createLockIO
            let !size' = msgQueueSize st
            canWrite <- newTVarIO $! quota > size'
            size <- newTVarIO size'
            pure
              JournalMsgQueue
                { queueDirectory = dir,
                  queueLock,
                  readJournal,
                  writeJournal,
                  statePath,
                  stateHandle,
                  quota,
                  canWrite,
                  size
                }

  delMsgQueue :: JournalMsgStore -> RecipientId -> IO ()
  delMsgQueue st rId = undefined

  delMsgQueueSize :: JournalMsgStore -> RecipientId -> IO Int
  delMsgQueueSize st rId = undefined

instance MsgQueueClass JournalMsgQueue where 
  writeMsg :: JournalMsgQueue -> Message -> IO (Maybe (Message, Bool))
  writeMsg mq msg = undefined

  tryPeekMsg :: JournalMsgQueue -> IO (Maybe Message)
  tryPeekMsg mq = undefined

  tryDelMsg :: JournalMsgQueue -> MsgId -> IO (Maybe Message)
  tryDelMsg mq msgId' = undefined

  tryDelPeekMsg :: JournalMsgQueue -> MsgId -> IO (Maybe Message, Maybe Message)
  tryDelPeekMsg mq msgId' = undefined

  deleteExpiredMsgs :: JournalMsgQueue -> Int64 -> IO Int
  deleteExpiredMsgs mq old = undefined

  getQueueSize :: JournalMsgQueue -> IO Int
  getQueueSize mq = undefined

msgQueueDirectory :: JournalMsgStore -> RecipientId -> FilePath
msgQueueDirectory JournalMsgStore {storePath, pathParts} rId =
  storePath </> B.unpack (B.intercalate "/" $ splitSegments pathParts $ strEncode rId)
  where
    splitSegments _ "" = []
    splitSegments 0 s = [s]
    splitSegments n s =
      let (seg, s') = B.splitAt 2 s
       in seg : splitSegments (n - 1) s'

createNewWriteJournal :: TVar ChaChaDRG -> FilePath -> IO (JournalFile 'WriteMode)
createNewWriteJournal g dir = do
  journalId <- strEncode <$> atomically (C.randomBytes 12 g)
  let path = journalFilePath dir journalId -- TODO retry if file exists
  handle <- openFile path AppendMode
  B.hPutStr handle ""
  pure JournalFile {mode = JFWriteMode, path, journalId, handle, msgPos = 0, msgCount = 0, bytePos = 0}

openNewReadJournal :: JournalFile 'WriteMode -> IO (JournalFile 'ReadMode)
openNewReadJournal JournalFile {path, journalId} = do
  handle <- openFile path ReadMode
  pure JournalFile {mode = JFReadMode, path, journalId, handle, msgPos = 0, msgCount = 0, bytePos = 0}

openWriteJournal :: FilePath -> JournalState -> IO (JournalFile 'WriteMode)
openWriteJournal dir JournalState {journalId, msgPos, msgCount, bytePos} = do
  let path = journalFilePath dir journalId
  handle <- openFile path AppendMode
  -- TODO verify that file exists, what to do if it's not, or if its state diverges
  -- TODO check current position matches state, fix if not
  pure JournalFile {mode = JFWriteMode, path, journalId, handle, msgPos, msgCount, bytePos}
  

openReadJournal :: FilePath -> JournalState -> IO (JournalFile 'ReadMode)
openReadJournal dir JournalState {journalId, msgPos, msgCount, bytePos} = do
  let path = journalFilePath dir journalId
  handle <- openFile path ReadMode
  -- TODO verify that file exists, what to do if it's not, or if its state diverges
  -- TODO check current position matches state, fix if not
  hSeek handle AbsoluteSeek $ fromIntegral bytePos
  pure JournalFile {mode = JFReadMode, path, journalId, handle, msgPos, msgCount, bytePos}

readWriteQueueState :: FilePath -> FilePath -> IO MsgQueueState
readWriteQueueState dir statePath = undefined
-- TODO this function should read the last queue state, ignoring the last line if it's broken,
-- write it to the new file,
-- make backup of the old file (with timestamp),
-- remove "old" backups (maybe only during storage validation?)
--
-- state_ <- withFile statePath ReadMode $ \h -> getLastState Nothing h
-- (state, stateHandle) <- case state_ of
--   Nothing -> (emptyState,) <$> openFile statePath AppendMode -- no or empty state file
--   Just (Right state) -> do
--     ts <- getCurrentTime
--     renameFile statePath $ dir </> (queueLogFileName <> "." <> show ts <> logFileExt)
--     -- TODO remove old logs, possibly when validating storage
--     (state,) <$> openFile statePath AppendMode
--   Just (Left e) -> do
--     logError $ "Error restoring msg queue state: "
--     ts <- getCurrentTime
--     renameFile statePath $ dir </> (queueLogFileName <> "." <> show ts <> logFileExt)
--     -- TODO remove old logs, possibly when validating storage
--     pure emptyState

msgQueueSize :: MsgQueueState -> Int
msgQueueSize MsgQueueState {writeState, readState} =
  let JournalState {journalId = wId, msgPos = wPos} = writeState
      JournalState {journalId = rId, msgPos = rPos, msgCount = rCount} = readState
   in if wId == rId then wPos - rPos else rCount + wPos - rPos
