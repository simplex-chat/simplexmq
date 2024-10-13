{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.Messaging.Server.MsgStore.Journal where

import Control.Concurrent.STM
import Crypto.Random (ChaChaDRG)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (second)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
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
import System.IO (BufferMode (..), Handle, IOMode (..), SeekMode (..))
import qualified System.IO as IO

data JournalMsgStore = JournalMsgStore
  { storePath :: FilePath,
    pathParts :: Int,
    random :: TVar ChaChaDRG,
    msgQueues :: TMap RecipientId (TMVar JournalMsgQueue)
  }

data JournalMsgQueue = JournalMsgQueue
  { queueDirectory :: FilePath,
    queueLock :: Lock,
    -- path and handle queue state log file,
    -- it rotates and removes old backups when server is restarted
    statePath :: FilePath,
    stateHandle :: Handle,
    state :: TVar MsgQueueState,
    -- second handle is optional,
    -- it is used when write file is different from read file
    handles :: TVar (Handle, Maybe Handle),
    quota :: Int
  }

data MsgQueueState = MsgQueueState
  { writeState :: JournalState,
    readState :: JournalState,
    canWrite :: Bool,
    size :: Int
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
  let st = emptyJournalState journalId
   in MsgQueueState {writeState = st, readState = st, canWrite = True, size = 0}

emptyJournalState :: ByteString -> JournalState
emptyJournalState journalId = JournalState {journalId, msgPos = 0, msgCount = 0, bytePos = 0}

journalFilePath :: FilePath -> ByteString -> FilePath
journalFilePath dir journalId = dir </> (msgLogFileName <> "." <> B.unpack journalId <> logFileExt)

instance StrEncoding MsgQueueState where
  strEncode MsgQueueState {writeState, readState, canWrite, size} =
    B.unwords
      [ "write=" <> strEncode writeState,
        "read=" <> strEncode readState,
        "canWrite=" <> strEncode canWrite,
        "size=" <> strEncode size
      ]
  strP = do
    writeState <- "write=" *> strP
    readState <- " read=" *> strP
    canWrite <- " canWrite=" *> strP
    size <- " size=" *> strP
    pure MsgQueueState {writeState, readState, canWrite, size}

instance StrEncoding JournalState where
  strEncode JournalState {journalId, msgPos, msgCount, bytePos} =
    B.intercalate "," [journalId, strEncode msgPos, strEncode msgCount, strEncode bytePos]
  strP = do
    journalId <- A.takeTill (== ',')
    msgPos <- A.char ',' *> strP
    msgCount <- A.char ',' *> strP
    bytePos <- A.char ',' *> strP
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
          openQ :: FilePath -> FilePath -> IO (MsgQueueState, Handle, (Handle, Maybe Handle))
          openQ dir statePath = do
            st@MsgQueueState {readState, writeState} <- readWriteQueueState dir statePath
            sh <- openFile statePath AppendMode
            (rs', rh) <- openJournal dir readState
            (ws', wh_) <-
              if journalId readState == journalId writeState
                then pure (writeState, Nothing)
                else second Just <$> openJournal dir writeState
            let st' = st {readState = rs', writeState = ws'}
            pure (st', sh, (rh, wh_))
          createQ :: FilePath -> FilePath -> IO (MsgQueueState, Handle, (Handle, Maybe Handle))
          createQ dir statePath = do
            createDirectoryIfMissing True dir
            sh <- openFile statePath AppendMode
            B.hPutStr sh ""
            (journalId, rh) <- createNewJournal g dir
            pure (emptyMsgQueueState journalId, sh, (rh, Nothing))
          mkJournalQueue :: FilePath -> FilePath -> (MsgQueueState, Handle, (Handle, Maybe Handle)) -> IO JournalMsgQueue
          mkJournalQueue dir statePath (st, stateHandle, hs) = do
            state <- newTVarIO st
            handles <- newTVarIO hs
            queueLock <- createLockIO
            pure
              JournalMsgQueue
                { queueDirectory = dir,
                  queueLock,
                  statePath,
                  stateHandle,
                  state,
                  handles,
                  quota
                }

  delMsgQueue :: JournalMsgStore -> RecipientId -> IO ()
  delMsgQueue st rId = undefined

  delMsgQueueSize :: JournalMsgStore -> RecipientId -> IO Int
  delMsgQueueSize st rId = undefined

maxMsgCount :: Int
maxMsgCount = 1024

instance MsgQueueClass JournalMsgQueue where 
  writeMsg :: JournalMsgQueue -> Message -> IO (Maybe (Message, Bool))
  writeMsg mq@JournalMsgQueue {queueDirectory, queueLock, stateHandle = sh, state, handles, quota} !msg =
    withLock' queueLock "writeMsg" $ do
      st@MsgQueueState {canWrite, size} <- readTVarIO state
      let empty = size == 0
      if canWrite || empty
        then do
          let canWrt' = quota > size
          if canWrt'
            then writeToJournal st canWrt' msg $> Just (msg, empty)
            else writeToJournal st canWrt' msgQuota $> Nothing
        else pure Nothing
    where
      msgQuota = MessageQuota {msgId = msgId msg, msgTs = msgTs msg}
      writeToJournal st@MsgQueueState {writeState, readState, canWrite, size} canWrt' msg' = do
        let msgStr = strEncode msg' `B.snoc` '\n'
            msgLen = B.length msgStr
        hs <- readTVarIO handles
        (ws, wh) <- case hs of
          (h, Nothing) | msgCount writeState >= maxMsgCount -> do
            g <- C.newRandom -- TODO get from store
            (journalId, wh) <- createNewJournal g queueDirectory
            atomically $ writeTVar handles $! (h, Just wh)
            pure (emptyJournalState journalId, wh)
          (h, wh_) -> pure (writeState, fromMaybe h wh_)
        let !ws' = ws {msgPos = msgPos ws + 1, msgCount = msgCount ws + 1, bytePos = bytePos ws + msgLen}
            !st' = st {writeState = ws', canWrite = canWrt', size = size + 1}
        atomically $ writeTVar state st'
        hAppend wh msgStr
        B.hPutStr sh $ strEncode st' `B.snoc` '\n'

    -- if write_msg >= max_file_messages: // queue file rotation
    --     create messages.efgh.log // efgh is some random string
    --     update queue state: write_file=efgh write_msg=0 // read file remains the same as it was
    --     append updated queue state to queue.log
    --     copy queue.log to queue.timestamp.log
    --     // `old` needs to be defined to limit the number and storage duration,
    --     // preserving not more than N files, and not more than M days files, "and then some"
    --     // (that is if the queue has high churn, we have file from M days before in any case, for any debugging).
    --     delete `old` `queue.timestamp.log` files
    --     write one line queue state to queue.log // compaction

    -- add message to write_file
    -- update queue state: write_msg += 1
    -- append updated queue state to queue.log

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

createNewJournal :: TVar ChaChaDRG -> FilePath -> IO (ByteString, Handle)
createNewJournal g dir = do
  journalId <- strEncode <$> atomically (C.randomBytes 12 g)
  let path = journalFilePath dir journalId -- TODO retry if file exists
  h <- openFile path ReadWriteMode
  B.hPutStr h ""
  pure (journalId, h)

openJournal :: FilePath -> JournalState -> IO (JournalState, Handle)
openJournal dir st@JournalState {journalId} = do
  let path = journalFilePath dir journalId
  -- TODO verify that file exists, what to do if it's not, or if its state diverges
  -- TODO check current position matches state, fix if not
  h <- openFile path ReadWriteMode
  pure (st, h)
  
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

hAppend :: Handle -> ByteString -> IO ()
hAppend h s = IO.hSeek h SeekFromEnd 0 >> B.hPutStr h s

openFile :: FilePath -> IOMode -> IO Handle
openFile f mode = do
  h <- IO.openFile f mode
  IO.hSetBuffering h LineBuffering
  pure h

msgQueueSize :: MsgQueueState -> Int
msgQueueSize MsgQueueState {writeState, readState} =
  let JournalState {journalId = wId, msgPos = wPos} = writeState
      JournalState {journalId = rId, msgPos = rPos, msgCount = rCount} = readState
   in if wId == rId then wPos - rPos else rCount + wPos - rPos
