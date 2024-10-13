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

newMsgQueueState :: ByteString -> MsgQueueState
newMsgQueueState journalId =
  let st = newJournalState journalId
   in MsgQueueState {writeState = st, readState = st, canWrite = True, size = 0}

newJournalState :: ByteString -> JournalState
newJournalState journalId = JournalState {journalId, msgPos = 0, msgCount = 0, bytePos = 0}

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
            pure (newMsgQueueState journalId, sh, (rh, Nothing))
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
      writeToJournal st@MsgQueueState {writeState, readState = rs, canWrite, size} canWrt' msg' = do
        let msgStr = strEncode msg' `B.snoc` '\n'
            msgLen = B.length msgStr
        hs <- readTVarIO handles
        (ws, wh) <- case hs of
          (h, Nothing) | msgCount writeState >= maxMsgCount -> do
            g <- C.newRandom -- TODO get from store
            (journalId, wh) <- createNewJournal g queueDirectory
            atomically $ writeTVar handles $! (h, Just wh)
            pure (newJournalState journalId, wh)
          (h, wh_) -> pure (writeState, fromMaybe h wh_)
        let !msgCount' = msgCount ws + 1
            !ws' = ws {msgPos = msgPos ws + 1, msgCount = msgCount', bytePos = bytePos ws + msgLen}
            !rs' = if journalId ws == journalId rs then rs {msgCount = msgCount'} else rs
            !st' = st {writeState = ws', readState = rs', canWrite = canWrt', size = size + 1}
        atomically $ writeTVar state st'
        hAppend wh msgStr
        B.hPutStr sh $ strEncode st' `B.snoc` '\n'

  -- TODO optimize by having the message ready (set when journal is opened)
  tryPeekMsg :: JournalMsgQueue -> IO (Maybe Message)
  tryPeekMsg mq = withLock' (queueLock mq) "tryPeekMsg" $ tryPeekMsg_ mq

  tryDelMsg :: JournalMsgQueue -> MsgId -> IO (Maybe Message)
  tryDelMsg mq msgId' =
    withLock' (queueLock mq) "tryDelMsg" $
      tryPeekMsg_ mq >>= \case
        msg_@(Just msg) | msgId msg == msgId' || B.null msgId' ->
          tryDeleteMsg_ mq >> pure msg_
        _ -> pure Nothing

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

tryPeekMsg_ :: JournalMsgQueue -> IO (Maybe Message)
tryPeekMsg_ JournalMsgQueue {state, handles} = do
  MsgQueueState {readState = JournalState {bytePos}} <- readTVarIO state
  (h, _) <- readTVarIO handles
  s <- hGetLineAt h bytePos -- won't be needed when message is cached
  -- TODO handle errors
  Right msg <- pure $ strDecode s
  pure msg

tryDeleteMsg_ :: JournalMsgQueue -> IO ()
tryDeleteMsg_ JournalMsgQueue {stateHandle = sh, state, handles} = do
  st@MsgQueueState {readState = rs, writeState = ws, size} <- readTVarIO state
  let JournalState {msgPos, bytePos} = rs
  (h, wh_) <- readTVarIO handles
  s <- hGetLineAt h bytePos -- won't be needed when message is cached
  let !msgPos' = msgPos + 1
  !rs' <- case wh_ of
    Just wh | msgPos' == msgCount rs && journalId rs /= journalId ws -> do
      -- switch to reading from write journal
      atomically $ writeTVar handles $! (wh, Nothing)
      pure (newJournalState $ journalId ws) {msgCount = msgCount ws}
    _ -> pure rs {msgPos = msgPos', bytePos = bytePos + B.length s + 1} -- 1 is for newline
  let !st' = st {readState = rs', size = size - 1}
  atomically $ writeTVar state st'
  B.hPutStr sh $ strEncode st' `B.snoc` '\n'
    
hAppend :: Handle -> ByteString -> IO ()
hAppend h s = IO.hSeek h SeekFromEnd 0 >> B.hPutStr h s

hGetLineAt :: Handle -> Int -> IO ByteString
hGetLineAt h pos = IO.hSeek h AbsoluteSeek (fromIntegral pos) >> B.hGetLine h

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
