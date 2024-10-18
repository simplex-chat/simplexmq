{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.Messaging.Server.MsgStore.Journal
  ( JournalMsgStore (msgQueues),
    JournalMsgQueue,
    JournalStoreConfig (..),
  )
where

import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (second)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Functor (($>))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import GHC.IO (catchAny)
import Simplex.Messaging.Agent.Client (getMapLock, withLockMap)
import Simplex.Messaging.Agent.Lock
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (Message (..), RecipientId)
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (ifM, tshow, ($>>=))
import System.Directory
import System.FilePath ((</>))
import System.IO (BufferMode (..), Handle, IOMode (..), SeekMode (..))
import qualified System.IO as IO
import System.Random (StdGen, genByteString, newStdGen)

data JournalMsgStore = JournalMsgStore
  { config :: JournalStoreConfig,
    random :: TVar StdGen,
    queueLocks :: TMap RecipientId Lock,
    msgQueues :: TMap RecipientId JournalMsgQueue
  }

data JournalStoreConfig = JournalStoreConfig
  { storePath :: FilePath,
    pathParts :: Int,
    quota :: Int,
    -- Max number of messages per journal file - ignored in STM store.
    -- When this limit is reached, the file will be changed.
    -- This number should be set bigger than queue quota.
    maxMsgCount :: Int
  }

data JournalMsgQueue = JournalMsgQueue
  { config :: JournalStoreConfig,
    queueDirectory :: FilePath,
    queueLock :: Lock,
    state :: TVar MsgQueueState,
    -- Last message and length incl. newline
    -- Nothing - unknown, Just Nothing - empty queue.
    -- This optimization  prevents reading each message at least twice,
    -- or reading it after it was just written.
    tipMsg :: TVar (Maybe (Maybe (Message, Int))),
    handles :: TVar (Maybe MsgQueueHandles),
    random :: TVar StdGen
  }

data MsgQueueState = MsgQueueState
  { writeState :: JournalState,
    readState :: JournalState,
    canWrite :: Bool,
    size :: Int
  }
  deriving (Show)

data MsgQueueHandles = MsgQueueHandles
  { stateHandle :: Handle, -- handle to queue state log file, rotates and removes old backups when server is restarted
    readHandle :: Handle,
    writeHandle :: Maybe Handle -- optional, used when write file is different from read file
  }

data JournalState = JournalState
  { journalId :: ByteString,
    msgPos :: Int,
    msgCount :: Int,
    bytePos :: Int
  }
  deriving (Show)

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

newtype NonAtomicIO a = NonAtomicIO (IO a)
  deriving newtype (Functor, Applicative, Monad)

instance MsgStoreClass JournalMsgStore where
  type StoreMonad JournalMsgStore = NonAtomicIO
  type MsgQueue JournalMsgStore = JournalMsgQueue
  type MsgStoreConfig JournalMsgStore = JournalStoreConfig

  newMsgStore :: JournalStoreConfig -> IO JournalMsgStore
  newMsgStore config = do
    random <- newTVarIO =<< newStdGen
    queueLocks <- TM.emptyIO
    msgQueues <- TM.emptyIO
    pure JournalMsgStore {config, random, queueLocks, msgQueues}

  closeMsgStore :: JournalMsgStore -> IO ()
  closeMsgStore st = readTVarIO (msgQueues st) >>= mapM_ closeMsgQueue_

  getMsgQueues :: JournalMsgStore -> IO (Map RecipientId JournalMsgQueue)
  getMsgQueues = readTVarIO . msgQueues

  getMsgQueueIds :: JournalMsgStore -> IO (Set RecipientId)
  getMsgQueueIds = fmap M.keysSet . readTVarIO . msgQueues

  getMsgQueue :: JournalMsgStore -> RecipientId -> IO JournalMsgQueue
  getMsgQueue store@JournalMsgStore {queueLocks, msgQueues, random, config} rId =
    withLockMap queueLocks rId "getMsgQueue" $
      TM.lookupIO rId msgQueues >>= maybe newQ pure
    where
      newQ = do
        let dir = msgQueueDirectory store rId
        q <- mkJournalQueue dir =<< ifM (doesDirectoryExist dir) (openQ dir) createQ
        atomically $ TM.insert rId q msgQueues
        pure q
        where
          openQ :: FilePath -> IO (MsgQueueState, Maybe MsgQueueHandles)
          openQ dir = do
            let statePath = dir </> (queueLogFileName <> logFileExt)
            st@MsgQueueState {readState, writeState} <- readWriteQueueState dir statePath
            sh <- openFile statePath AppendMode
            (rs', rh) <- openJournal dir readState
            (ws', wh_) <-
              if journalId readState == journalId writeState
                then pure (writeState, Nothing)
                else second Just <$> openJournal dir writeState
            let st' = st {readState = rs', writeState = ws'}
            let hs = MsgQueueHandles {stateHandle = sh, readHandle = rh, writeHandle = wh_}
            pure (st', Just hs)
          createQ :: IO (MsgQueueState, Maybe MsgQueueHandles)
          createQ = do
            -- folder and files are not created here,
            -- to avoid file IO for queues without messages during subscription
            journalId <- newJournalId random
            pure (newMsgQueueState journalId, Nothing)
          mkJournalQueue :: FilePath -> (MsgQueueState, Maybe MsgQueueHandles) -> IO JournalMsgQueue
          mkJournalQueue dir (st, hs_) = do
            state <- newTVarIO st
            tipMsg <- newTVarIO Nothing
            handles <- newTVarIO hs_
            -- using the same queue lock which is currently locked,
            -- to avoid map lookup on queue operations
            queueLock <- atomically $ getMapLock queueLocks rId
            pure
              JournalMsgQueue
                { config,
                  queueDirectory = dir,
                  queueLock,
                  state,
                  tipMsg,
                  handles,
                  random
                }

  delMsgQueue :: JournalMsgStore -> RecipientId -> IO ()
  delMsgQueue st rId = withLockMap (queueLocks st) rId "delMsgQueue" $ do
    void $ closeMsgQueue st rId
    removeQueueDirectory st rId

  delMsgQueueSize :: JournalMsgStore -> RecipientId -> IO Int
  delMsgQueueSize st rId = withLockMap (queueLocks st) rId "delMsgQueue" $ do
    state_ <- closeMsgQueue st rId
    sz <- maybe (pure $ -1) (fmap size . readTVarIO) state_
    removeQueueDirectory st rId
    pure sz

  writeMsg :: JournalMsgQueue -> Message -> IO (Maybe (Message, Bool))
  writeMsg JournalMsgQueue {queueDirectory, queueLock, state, tipMsg, handles, config, random} !msg =
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
      JournalStoreConfig {quota, maxMsgCount} = config
      msgQuota = MessageQuota {msgId = msgId msg, msgTs = msgTs msg}
      writeToJournal st@MsgQueueState {writeState, readState = rs, size} canWrt' msg' = do
        let msgStr = strEncode msg' `B.snoc` '\n'
            msgLen = B.length msgStr
        hs <- maybe createQueueDir pure =<< readTVarIO handles
        (ws, wh) <- case writeHandle hs of
          Nothing | msgCount writeState >= maxMsgCount -> switchWriteJournal hs
          wh_ -> pure (writeState, fromMaybe (readHandle hs) wh_)
        let msgCount' = msgCount ws + 1
            ws' = ws {msgPos = msgPos ws + 1, msgCount = msgCount', bytePos = bytePos ws + msgLen}
            rs' = if journalId ws == journalId rs then rs {msgCount = msgCount'} else rs
            !st' = st {writeState = ws', readState = rs', canWrite = canWrt', size = size + 1}
        atomically $ writeTVar state st'
        when (size == 0) $ atomically $ writeTVar tipMsg $ Just (Just (msg, msgLen))
        hAppend wh msgStr
        B.hPutStr (stateHandle hs) $ strEncode st' `B.snoc` '\n'
        where
          createQueueDir = do
            createDirectoryIfMissing True queueDirectory
            let statePath = queueDirectory </> (queueLogFileName <> logFileExt)
            sh <- openFile statePath AppendMode
            B.hPutStr sh ""
            rh <- createNewJournal queueDirectory $ journalId rs
            let hs = MsgQueueHandles {stateHandle = sh, readHandle = rh, writeHandle = Nothing}
            atomically $ writeTVar handles $ Just hs
            pure hs
          switchWriteJournal hs = do
            journalId <- newJournalId random
            wh <- createNewJournal queueDirectory journalId
            atomically $ writeTVar handles $ Just $ hs {writeHandle = Just wh}
            pure (newJournalState journalId, wh)

  getQueueSize :: JournalMsgQueue -> IO Int
  getQueueSize JournalMsgQueue {state} = size <$> readTVarIO state

  -- TODO optimize by having the message ready (set when journal is opened)
  tryPeekMsg_ :: JournalMsgQueue -> NonAtomicIO (Maybe Message)
  tryPeekMsg_ JournalMsgQueue {queueDirectory, state, tipMsg, handles} =
    NonAtomicIO $ readTVarIO handles $>>= chooseReadJournal $>>= peekMsg
    where
      chooseReadJournal hs = do
        st@MsgQueueState {writeState = ws, readState = rs} <- readTVarIO state
        case writeHandle hs of
          Just wh | msgPos rs >= msgCount rs && journalId rs /= journalId ws -> do
            -- switching to write journal
            atomically $ writeTVar handles $ Just hs {readHandle = wh, writeHandle = Nothing}
            hClose $ readHandle hs
            removeJournal queueDirectory rs
            let !rs' = (newJournalState $ journalId ws) {msgCount = msgCount ws}
                !st' = st {readState = rs'}
            atomically $ writeTVar state st'
            pure $ Just (rs', wh)
          _ | msgPos rs >= msgCount rs && journalId rs == journalId ws -> pure Nothing
          _ -> pure $ Just (rs, readHandle hs)
      peekMsg (rs, h) = readTVarIO tipMsg >>= maybe readMsg (pure . fmap fst)
        where
          readMsg = do
            -- TODO handle errors
            s <- hGetLineAt h $ bytePos rs
            -- TODO handle errors
            Right msg <- pure $ strDecode s
            atomically $ writeTVar tipMsg $ Just (Just (msg, B.length s + 1)) -- 1 is to account for new line
            pure $ Just msg

  tryDeleteMsg_ :: JournalMsgQueue -> NonAtomicIO ()
  tryDeleteMsg_ JournalMsgQueue {state, tipMsg, handles} = NonAtomicIO $ do
    void $
      readTVarIO tipMsg -- if there is no cached tipMsg, do nothing
        $>>= (pure . fmap snd)
        $>>= \len -> readTVarIO handles $>>= delMsg len
    where
      delMsg len hs =
        Just () <$ do
          st@MsgQueueState {readState = rs, size} <- readTVarIO state
          let JournalState {msgPos, bytePos} = rs
          let msgPos' = msgPos + 1
              rs' = rs {msgPos = msgPos', bytePos = bytePos + len}
              st' = st {readState = rs', size = size - 1}
          atomically $ writeTVar state $! st'
          B.hPutStr (stateHandle hs) $ strEncode st' `B.snoc` '\n'
          atomically $ writeTVar tipMsg Nothing

  atomicQueue :: JournalMsgQueue -> NonAtomicIO a -> IO a
  atomicQueue mq (NonAtomicIO a) = withLock' (queueLock mq) "atomicQueue" a

msgQueueDirectory :: JournalMsgStore -> RecipientId -> FilePath
msgQueueDirectory JournalMsgStore {config = JournalStoreConfig {storePath, pathParts}} rId =
  storePath </> B.unpack (B.intercalate "/" $ splitSegments pathParts $ strEncode rId)
  where
    splitSegments _ "" = []
    splitSegments 0 s = [s]
    splitSegments n s =
      let (seg, s') = B.splitAt 2 s
       in seg : splitSegments (n - 1) s'

createNewJournal :: FilePath -> ByteString -> IO Handle
createNewJournal dir journalId = do
  let path = journalFilePath dir journalId -- TODO retry if file exists
  h <- openFile path ReadWriteMode
  B.hPutStr h ""
  pure h

newJournalId :: TVar StdGen -> IO ByteString
newJournalId g = strEncode <$> atomically (stateTVar g $ genByteString 12)

openJournal :: FilePath -> JournalState -> IO (JournalState, Handle)
openJournal dir st@JournalState {journalId} = do
  let path = journalFilePath dir journalId
  -- TODO verify that file exists, what to do if it's not, or if its state diverges
  -- TODO check current position matches state, fix if not
  h <- openFile path ReadWriteMode
  pure (st, h)

removeJournal :: FilePath -> JournalState -> IO ()
removeJournal dir JournalState {journalId} = do
  let path = journalFilePath dir journalId
  removeFile path `catchAny` (\e -> logError $ "Error removing file " <> T.pack path <> ": " <> tshow e)

readWriteQueueState :: FilePath -> FilePath -> IO MsgQueueState
readWriteQueueState dir statePath = do
  Right state <- strDecode . LB.toStrict . last . LB.lines <$> LB.readFile statePath `catchAny` (\e -> print e >> E.throwIO e)
  ts <- getCurrentTime
  renameFile statePath $ dir </> (queueLogFileName <> "." <> show ts <> logFileExt)
  pure state

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

closeMsgQueue :: JournalMsgStore -> RecipientId -> IO (Maybe (TVar MsgQueueState))
closeMsgQueue JournalMsgStore {msgQueues} rId =
  atomically (TM.lookupDelete rId msgQueues)
    >>= mapM (\q -> closeMsgQueue_ q $> state q)

closeMsgQueue_ :: JournalMsgQueue -> IO ()
closeMsgQueue_ q = readTVarIO (handles q) >>= mapM_ closeHandles
  where
    closeHandles (MsgQueueHandles sh rh wh_) = do
      hClose sh
      hClose rh
      mapM_ hClose wh_

removeQueueDirectory :: JournalMsgStore -> RecipientId -> IO ()
removeQueueDirectory st rId =
  let dir = msgQueueDirectory st rId
   in removePathForcibly dir `catchAny` (\e -> logError $ "Error removing queue directory " <> T.pack dir <> ": " <> tshow e)

hAppend :: Handle -> ByteString -> IO ()
hAppend h s = IO.hSeek h SeekFromEnd 0 >> B.hPutStr h s

hGetLineAt :: Handle -> Int -> IO ByteString
hGetLineAt h pos = IO.hSeek h AbsoluteSeek (fromIntegral pos) >> B.hGetLine h

openFile :: FilePath -> IOMode -> IO Handle
openFile f mode = do
  h <- IO.openFile f mode
  IO.hSetBuffering h LineBuffering
  pure h

hClose :: Handle -> IO ()
hClose h = IO.hClose h `catchAny` (\e -> logError $ "Error closing file" <> tshow e)

msgQueueSize :: MsgQueueState -> Int
msgQueueSize MsgQueueState {writeState, readState} =
  let JournalState {journalId = wId, msgPos = wPos} = writeState
      JournalState {journalId = rId, msgPos = rPos, msgCount = rCount} = readState
   in if wId == rId then wPos - rPos else rCount + wPos - rPos
