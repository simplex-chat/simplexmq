{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.Messaging.Server.MsgStore.Journal
  ( JournalMsgStore (msgQueues, random),
    JournalMsgQueue (queue),
    JMQueue (queueDirectory, statePath),
    JournalStoreConfig (..),
    getQueueMessages,
    closeMsgQueue,
    -- below are exported for tests
    MsgQueueState (..),
    JournalState (..),
    SJournalType (..),
    msgQueueDirectory,
    readWriteQueueState,
    newMsgQueueState,
    newJournalId,
    appendState,
    queueLogFileName,
    logFileExt,
  )
where

import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Trans.Except
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Functor (($>))
import Data.Int (Int64)
import Data.Maybe (catMaybes, fromMaybe)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import GHC.IO (catchAny)
import Simplex.Messaging.Agent.Client (getMapLock, withLockMap)
import Simplex.Messaging.Agent.Lock
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (ErrorType (..), Message (..), RecipientId)
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (ifM, tshow, ($>>=))
import System.Directory
import System.Exit
import System.FilePath ((</>))
import System.IO (BufferMode (..), Handle, IOMode (..), SeekMode (..), stdout)
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
    maxMsgCount :: Int,
    maxStateLines :: Int
  }

data JMQueue = JMQueue
  { queueDirectory :: FilePath,
    queueLock :: Lock,
    statePath :: FilePath
  }

data JournalMsgQueue = JournalMsgQueue
  { queue :: JMQueue,
    state :: TVar MsgQueueState,
    -- tipMsg contains last message and length incl. newline
    -- Nothing - unknown, Just Nothing - empty queue.
    -- It  prevents reading each message twice,
    -- and reading it after it was just written.
    tipMsg :: TVar (Maybe (Maybe (Message, Int64))),
    handles :: TVar (Maybe MsgQueueHandles)
  }

data MsgQueueState = MsgQueueState
  { readState :: JournalState 'JTRead,
    writeState :: JournalState 'JTWrite,
    canWrite :: Bool,
    size :: Int
  }
  deriving (Show)

data MsgQueueHandles = MsgQueueHandles
  { stateHandle :: Handle, -- handle to queue state log file, rotates and removes old backups when server is restarted
    readHandle :: Handle,
    writeHandle :: Maybe Handle -- optional, used when write file is different from read file
  }

data JournalState t = JournalState
  { journalType :: SJournalType t,
    journalId :: ByteString,
    msgPos :: Int,
    msgCount :: Int,
    bytePos :: Int64,
    byteCount :: Int64
  }
  deriving (Show)

data JournalType = JTRead | JTWrite

data SJournalType (t :: JournalType) where
  SJTRead :: SJournalType 'JTRead
  SJTWrite :: SJournalType 'JTWrite

class JournalTypeI t where sJournalType :: SJournalType t

instance JournalTypeI 'JTRead where sJournalType = SJTRead

instance JournalTypeI 'JTWrite where sJournalType = SJTWrite

deriving instance Show (SJournalType t)

newMsgQueueState :: ByteString -> MsgQueueState
newMsgQueueState journalId =
  MsgQueueState
    { writeState = newJournalState journalId,
      readState = newJournalState journalId,
      canWrite = True,
      size = 0
    }

newJournalState :: JournalTypeI t => ByteString -> JournalState t
newJournalState journalId = JournalState sJournalType journalId 0 0 0 0

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

instance JournalTypeI t => StrEncoding (JournalState t) where
  strEncode JournalState {journalId, msgPos, msgCount, bytePos, byteCount} =
    B.intercalate "," [journalId, e msgPos, e msgCount, e bytePos, e byteCount]
    where
      e :: StrEncoding a => a -> ByteString
      e = strEncode
  strP = do
    journalId <- A.takeTill (== ',')
    JournalState sJournalType journalId <$> i <*> i <*> i <*> i
    where
      i :: Integral a => A.Parser a
      i = A.char ',' *> A.decimal

queueLogFileName :: String
queueLogFileName = "queue_state"

msgLogFileName :: String
msgLogFileName = "messages"

logFileExt :: String
logFileExt = ".log"

newtype StoreIO a = StoreIO (IO a)
  deriving newtype (Functor, Applicative, Monad)

instance MsgStoreClass JournalMsgStore where
  type StoreMonad JournalMsgStore = StoreIO
  type MsgQueue JournalMsgStore = JournalMsgQueue
  type MsgStoreConfig JournalMsgStore = JournalStoreConfig

  newMsgStore :: JournalStoreConfig -> IO JournalMsgStore
  newMsgStore config = do
    random <- newTVarIO =<< newStdGen
    queueLocks <- TM.emptyIO
    msgQueues <- TM.emptyIO
    pure JournalMsgStore {config, random, queueLocks, msgQueues}

  closeMsgStore st = readTVarIO (msgQueues st) >>= mapM_ closeMsgQueue

  activeMsgQueues = msgQueues
  {-# INLINE activeMsgQueues #-}

  -- This function is a "foldr" that opens and closes all queues, processes them as defined by action and accumulates the result.
  -- It is used to export storage to a single file and also to expire messages and validate all queues when server is started.
  -- TODO this function requires case-sensitive file system, because it uses queue directory as recipient ID.
  -- It can be made to support case-insensite FS by supporting more than one queue per directory, by getting recipient ID from state file name.
  withAllMsgQueues :: JournalMsgStore -> (RecipientId -> JournalMsgQueue -> a -> IO a) -> a -> IO a
  withAllMsgQueues ms@JournalMsgStore {config} action res = ifM (doesDirectoryExist storePath) processStore (pure res)
    where
      processStore = do
        closeMsgStore ms
        lock <- createLockIO -- the same lock is used for all queues
        dirs <- zip [0..] <$> listQueueDirs 0 ("", storePath)
        let count = length dirs
        res' <- foldM (processQueue lock count) res dirs
        progress count count
        putStrLn ""
        pure res'
      JournalStoreConfig {storePath, pathParts} = config
      processQueue queueLock count acc (i :: Int, (queueId, dir)) = do
        when (i `mod` 100 == 0) $ progress i count
        let statePath = dir </> queueLogFileName <> "." <> queueId <> logFileExt
            queue = JMQueue {queueDirectory = dir, queueLock, statePath}
        q <- openMsgQueue ms queue
        acc' <- case strDecode $ B.pack queueId of
          Right rId -> action rId q acc
          Left e -> do
            putStrLn ("Error: message queue directory " <> dir <> " is invalid: " <> e)
            exitFailure
        closeMsgQueue q
        pure acc'
      progress i count = do
        putStr $ "Processed: " <> show i <> "/" <> show count <> " queues\r"
        IO.hFlush stdout
      listQueueDirs depth (queueId, path)
        | depth == pathParts - 1 = listDirs
        | otherwise = fmap concat . mapM (listQueueDirs (depth + 1)) =<< listDirs
        where
          listDirs = fmap catMaybes . mapM queuePath =<< listDirectory path
          queuePath dir = do
            let path' = path </> dir
            ifM
              (doesDirectoryExist path')
              (pure $ Just (queueId <> dir, path'))
              (Nothing <$ putStrLn ("Error: path " <> path' <> " is not a directory, skipping"))

  logQueueStates :: JournalMsgStore -> IO ()
  logQueueStates ms = withActiveMsgQueues ms (\_ q _ -> logQueueState q) ()

  logQueueState :: JournalMsgQueue -> IO ()
  logQueueState q = 
    readTVarIO (handles q)
      >>= maybe (pure ()) (\hs -> readTVarIO (state q) >>= appendState (stateHandle hs))

  getMsgQueue :: JournalMsgStore -> RecipientId -> ExceptT ErrorType IO JournalMsgQueue
  getMsgQueue ms@JournalMsgStore {queueLocks, msgQueues, random} rId =
    tryStore "getMsgQueue" $ withLockMap queueLocks rId "getMsgQueue" $
      TM.lookupIO rId msgQueues >>= maybe newQ pure
    where
      newQ = do
        queueLock <- atomically $ getMapLock queueLocks rId
        let dir = msgQueueDirectory ms rId
            statePath = dir </> (queueLogFileName <> "." <> B.unpack (strEncode rId) <> logFileExt)
            queue = JMQueue {queueDirectory = dir, queueLock, statePath}
        q <- ifM (doesDirectoryExist dir) (openMsgQueue ms queue) (createQ queue)
        atomically $ TM.insert rId q msgQueues
        pure q
        where
          createQ :: JMQueue -> IO JournalMsgQueue
          createQ queue = do
            -- folder and files are not created here,
            -- to avoid file IO for queues without messages during subscription
            journalId <- newJournalId random
            mkJournalQueue queue (newMsgQueueState journalId, Nothing)

  delMsgQueue :: JournalMsgStore -> RecipientId -> IO ()
  delMsgQueue ms rId = withLockMap (queueLocks ms) rId "delMsgQueue" $ do
    void $ deleteMsgQueue_ ms rId
    removeQueueDirectory ms rId

  delMsgQueueSize :: JournalMsgStore -> RecipientId -> IO Int
  delMsgQueueSize ms rId = withLockMap (queueLocks ms) rId "delMsgQueue" $ do
    state_ <- deleteMsgQueue_ ms rId
    sz <- maybe (pure $ -1) (fmap size . readTVarIO) state_
    removeQueueDirectory ms rId
    pure sz

  getQueueMessages :: Bool -> JournalMsgQueue -> IO [Message]
  getQueueMessages drainMsgs q = readTVarIO (handles q) >>= maybe (pure []) (getMsg [])
    where
      getMsg msgs hs = chooseReadJournal q drainMsgs hs >>= maybe (pure msgs) readMsg
        where
          readMsg (rs, h) = do
            (msg, len) <- hGetMsgAt h $ bytePos rs
            updateReadPos q drainMsgs len hs
            (msg :) <$> getMsg msgs hs

  writeMsg :: JournalMsgStore -> JournalMsgQueue -> Bool -> Message -> ExceptT ErrorType IO (Maybe (Message, Bool))
  writeMsg ms q@JournalMsgQueue {queue = JMQueue {queueDirectory, queueLock, statePath}, handles} logState msg =
    tryStore "writeMsg" $ withLock' queueLock "writeMsg" $ do
      st@MsgQueueState {canWrite, size} <- readTVarIO (state q)
      let empty = size == 0
      if canWrite || empty
        then do
          let canWrt' = quota > size
          if canWrt'
            then writeToJournal st canWrt' msg $> Just (msg, empty)
            else writeToJournal st canWrt' msgQuota $> Nothing
        else pure Nothing
    where
      JournalStoreConfig {quota, maxMsgCount} = config ms
      msgQuota = MessageQuota {msgId = msgId msg, msgTs = msgTs msg}
      writeToJournal st@MsgQueueState {writeState, readState = rs, size} canWrt' !msg' = do
        let msgStr = strEncode msg' `B.snoc` '\n'
            msgLen = fromIntegral $ B.length msgStr
        hs <- maybe createQueueDir pure =<< readTVarIO handles
        (ws, wh) <- case writeHandle hs of
          Nothing | msgCount writeState >= maxMsgCount -> switchWriteJournal hs
          wh_ -> pure (writeState, fromMaybe (readHandle hs) wh_)
        let msgPos' = msgPos ws + 1
            bytePos' = bytePos ws + msgLen
            ws' = ws {msgPos = msgPos', msgCount = msgPos', bytePos = bytePos', byteCount = bytePos'}
            rs' = if journalId ws == journalId rs then rs {msgCount = msgPos', byteCount = bytePos'} else rs
            !st' = st {writeState = ws', readState = rs', canWrite = canWrt', size = size + 1}
        when (size == 0) $ atomically $ writeTVar (tipMsg q) $ Just (Just (msg, msgLen))
        hAppend wh (bytePos ws) msgStr
        updateQueueState q logState hs st'
        where
          createQueueDir = do
            createDirectoryIfMissing True queueDirectory
            sh <- openFile statePath AppendMode
            B.hPutStr sh ""
            rh <- createNewJournal queueDirectory $ journalId rs
            let hs = MsgQueueHandles {stateHandle = sh, readHandle = rh, writeHandle = Nothing}
            atomically $ writeTVar handles $ Just hs
            pure hs
          switchWriteJournal hs = do
            journalId <- newJournalId $ random ms
            wh <- createNewJournal queueDirectory journalId
            atomically $ writeTVar handles $ Just $ hs {writeHandle = Just wh}
            pure (newJournalState journalId, wh)

  -- can ONLY be used while restoring messages, not while server running
  setOverQuota_ :: JournalMsgQueue -> IO ()
  setOverQuota_ JournalMsgQueue {state} = atomically $ modifyTVar' state $ \st -> st {canWrite = False}

  getQueueSize :: JournalMsgQueue -> IO Int
  getQueueSize JournalMsgQueue {state} = size <$> readTVarIO state

  tryPeekMsg_ :: JournalMsgQueue -> StoreIO (Maybe Message)
  tryPeekMsg_ q@JournalMsgQueue {tipMsg, handles} =
    StoreIO $ readTVarIO handles $>>= chooseReadJournal q True $>>= peekMsg
    where
      peekMsg (rs, h) = readTVarIO tipMsg >>= maybe readMsg (pure . fmap fst)
        where
          readMsg = do
            ml@(msg, _) <- hGetMsgAt h $ bytePos rs
            atomically $ writeTVar tipMsg $ Just (Just ml)
            pure $ Just msg

  tryDeleteMsg_ :: JournalMsgQueue -> Bool -> StoreIO ()
  tryDeleteMsg_ q@JournalMsgQueue {tipMsg, handles} logState = StoreIO $
    void $
      readTVarIO tipMsg -- if there is no cached tipMsg, do nothing
        $>>= (pure . fmap snd)
        $>>= \len -> readTVarIO handles
        $>>= \hs -> updateReadPos q logState len hs $> Just ()

  isolateQueue :: JournalMsgQueue -> String -> StoreIO a -> ExceptT ErrorType IO a
  isolateQueue q op (StoreIO a) = tryStore op $ withLock' (queueLock $ queue q) op $ a

tryStore :: String -> IO a -> ExceptT ErrorType IO a
tryStore op a =
  ExceptT $
    (Right <$> a) `catchAny` \e ->
      let e' = op <> " " <> show e
       in logError ("STORE " <> T.pack e') $> Left (STORE e')

openMsgQueue :: JournalMsgStore -> JMQueue -> IO JournalMsgQueue
openMsgQueue ms q@JMQueue {queueDirectory = dir, statePath} = do
  (st, sh) <- readWriteQueueState ms statePath
  (st', rh, wh_) <- openJournals dir st
  let hs = MsgQueueHandles {stateHandle = sh, readHandle = rh, writeHandle = wh_}
  mkJournalQueue q (st', Just hs)

mkJournalQueue :: JMQueue -> (MsgQueueState, Maybe MsgQueueHandles) -> IO JournalMsgQueue
mkJournalQueue queue (st, hs_) = do
  state <- newTVarIO st
  tipMsg <- newTVarIO Nothing
  handles <- newTVarIO hs_
  -- using the same queue lock which is currently locked,
  -- to avoid map lookup on queue operations
  pure JournalMsgQueue {queue, state, tipMsg, handles}

chooseReadJournal :: JournalMsgQueue -> Bool -> MsgQueueHandles -> IO (Maybe (JournalState 'JTRead, Handle))
chooseReadJournal q log' hs = do
  st@MsgQueueState {writeState = ws, readState = rs} <- readTVarIO (state q)
  case writeHandle hs of
    Just wh | msgPos rs >= msgCount rs && journalId rs /= journalId ws -> do
      -- switching to write journal
      atomically $ writeTVar (handles q) $ Just hs {readHandle = wh, writeHandle = Nothing}
      hClose $ readHandle hs
      removeJournal (queueDirectory $ queue q) rs
      let !rs' = (newJournalState $ journalId ws) {msgCount = msgCount ws, byteCount = byteCount ws}
          !st' = st {readState = rs'}
      updateQueueState q log' hs st'
      pure $ Just (rs', wh)
    _ | msgPos rs >= msgCount rs && journalId rs == journalId ws -> pure Nothing
    _ -> pure $ Just (rs, readHandle hs)

updateQueueState :: JournalMsgQueue -> Bool -> MsgQueueHandles -> MsgQueueState -> IO ()
updateQueueState q log' hs st = do
  unless (validQueueState st) $ E.throwIO $ userError $ "updateQueueState, updating to invalid state, " <> show st
  when log' $ appendState (stateHandle hs) st
  atomically $ writeTVar (state q) st

appendState :: Handle -> MsgQueueState -> IO ()
appendState h st = B.hPutStr h $ strEncode st `B.snoc` '\n'

updateReadPos :: JournalMsgQueue -> Bool -> Int64 -> MsgQueueHandles -> IO ()
updateReadPos q log' len hs = do
  st@MsgQueueState {readState = rs, size} <- readTVarIO (state q)
  let JournalState {msgPos, bytePos} = rs
  let msgPos' = msgPos + 1
      rs' = rs {msgPos = msgPos', bytePos = bytePos + len}
      st' = st {readState = rs', size = size - 1}
  updateQueueState q log' hs st'              
  atomically $ writeTVar (tipMsg q) Nothing

msgQueueDirectory :: JournalMsgStore -> RecipientId -> FilePath
msgQueueDirectory JournalMsgStore {config = JournalStoreConfig {storePath, pathParts}} rId =
  storePath </> B.unpack (B.intercalate "/" $ splitSegments pathParts $ strEncode rId)
  where
    splitSegments _ "" = []
    splitSegments 1 s = [s]
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

openJournals :: FilePath -> MsgQueueState -> IO (MsgQueueState, Handle, Maybe Handle)
openJournals dir st@MsgQueueState {readState = rs, writeState = ws} = do
  -- TODO verify that file exists, what to do if it's not, or if its state diverges
  -- TODO check current position matches state, fix if not
  let rjId = journalId rs
      wjId = journalId ws
  openJournal rs >>= \case
    Left path -> do
      logError $ "STORE openJournals, no read file " <> T.pack path <> ", creating new file"
      rh <- createNewJournal dir rjId
      let st' = newMsgQueueState rjId
      pure (st', rh, Nothing)
    Right rh
      | rjId == wjId -> do
          fixFileSize rh $ bytePos ws
          pure (st, rh, Nothing)
      | otherwise -> do
          fixFileSize rh $ byteCount rs
          openJournal ws >>= \case
            Left path -> do
              logError $ "STORE openJournals, no write file " <> T.pack path <> ", creating new file"
              wh <- createNewJournal dir wjId
              let size' = msgCount rs - msgPos rs
                  st' = st {writeState = newJournalState wjId, size = size'} -- we don't amend canWrite to trigger QCONT
              pure (st', rh, Just wh)
            Right wh -> do
              fixFileSize wh $ bytePos ws
              pure (st, rh, Just wh)
  where
    openJournal :: JournalState t -> IO (Either FilePath Handle)
    openJournal JournalState {journalId} =
      let path = journalFilePath dir journalId
       in ifM (doesFileExist path) (Right <$> openFile path ReadWriteMode) (pure $ Left path)
    -- do that for all append operations

fixFileSize :: Handle -> Int64 -> IO ()
fixFileSize h pos = do
  let pos' = fromIntegral pos
  size <- IO.hFileSize h
  if
    | size > pos' -> do
        logWarn $ "STORE fixFileSize, truncating from " <> tshow size <> " to " <> tshow pos
        IO.hSetFileSize h pos'
    | size < pos' ->
        -- From code logic this can't happen.
        E.throwIO $ userError $ "fixFileSize, file size " <> show size <> " is smaller than position " <> show pos
    | otherwise -> pure ()

removeJournal :: FilePath -> JournalState t -> IO ()
removeJournal dir JournalState {journalId} = do
  let path = journalFilePath dir journalId
  removeFile path `catchAny` (\e -> logError $ "STORE removeJournal, " <> T.pack path <> ", " <> tshow e)

-- This function is supposed to be resilient to crashes while updating state files,
-- and also resilient to crashes during its execution.
readWriteQueueState :: JournalMsgStore -> FilePath -> IO (MsgQueueState, Handle)
readWriteQueueState JournalMsgStore {random, config} statePath =
  ifM
    (doesFileExist tempBackup)
    (renameFile tempBackup statePath >> readQueueState)
    (ifM (doesFileExist statePath) readQueueState writeNewQueueState)
  where
    tempBackup = statePath <> ".bak"
    readQueueState = do
      ls <- LB.lines <$> LB.readFile statePath
      case ls of
        [] -> writeNewQueueState
        _ -> do
          r@(st, _) <- useLastLine (length ls) True ls
          unless (validQueueState st) $ E.throwIO $ userError $ "readWriteQueueState, read invalid invalid, " <> show st
          pure r
    writeNewQueueState = do
      logWarn $ "STORE readWriteQueueState, empty queue state in " <> T.pack statePath <> ", initialized"
      st <- newMsgQueueState <$> newJournalId random
      writeQueueState st
    useLastLine len isLastLine ls = case strDecode $ LB.toStrict $ last ls of
      Right st
        | len > maxStateLines config || not isLastLine ->
            backupWriteQueueState st
        | otherwise -> do
            -- when state file has fewer than maxStateLines, we don't compact it
            sh <- openFile statePath AppendMode
            pure (st, sh)
      Left e -- if the last line failed to parse
        | isLastLine -> case init ls of -- or use the previous line
            [] -> do
              logWarn $ "STORE readWriteQueueState, invalid 1-line queue state " <> T.pack statePath <> ", initialized"
              st <- newMsgQueueState <$> newJournalId random
              backupWriteQueueState st
            ls' -> do
              logWarn $ "STORE readWriteQueueState, invalid last line in queue state " <> T.pack statePath <> ", using the previous line"
              useLastLine len False ls'
        | otherwise -> E.throwIO $ userError $ "readWriteQueueState, reading queue state " <> statePath <> ", " <> show e
    backupWriteQueueState st = do
      -- State backup is made in two steps to mitigate the crash during the backup.
      -- Temporary backup file will be used when it is present.
      renameFile statePath tempBackup -- 1) temp backup
      r <- writeQueueState st -- 2) save state
      ts <- getCurrentTime
      renameFile tempBackup (statePath <> "." <> iso8601Show ts <> ".bak") -- 3) timed backup
      pure r
    writeQueueState st = do
      sh <- openFile statePath AppendMode
      appendState sh st
      pure (st, sh)

validQueueState :: MsgQueueState -> Bool
validQueueState MsgQueueState {readState = rs, writeState = ws, size}
  | journalId rs == journalId ws =
      alwaysValid
        && msgPos rs <= msgPos ws
        && msgCount rs == msgCount ws
        && bytePos rs <= bytePos ws
        && byteCount rs == byteCount ws
        && size == msgCount rs - msgPos rs
  | otherwise =
      alwaysValid
        && size == msgCount ws + msgCount rs - msgPos rs
  where
    alwaysValid =
      msgPos rs <= msgCount rs
        && bytePos rs <= byteCount rs
        && msgPos ws == msgCount ws
        && bytePos ws == byteCount ws

deleteMsgQueue_ :: JournalMsgStore -> RecipientId -> IO (Maybe (TVar MsgQueueState))
deleteMsgQueue_ st rId =
  atomically (TM.lookupDelete rId (msgQueues st))
    >>= mapM (\q -> closeMsgQueue q $> state q)

closeMsgQueue :: JournalMsgQueue -> IO ()
closeMsgQueue q = readTVarIO (handles q) >>= mapM_ closeHandles
  where
    closeHandles (MsgQueueHandles sh rh wh_) = do
      hClose sh
      hClose rh
      mapM_ hClose wh_

removeQueueDirectory :: JournalMsgStore -> RecipientId -> IO ()
removeQueueDirectory st rId =
  let dir = msgQueueDirectory st rId
   in removePathForcibly dir `catchAny` (\e -> logError $ "STORE removeQueueDirectory, " <> T.pack dir <> ", " <> tshow e)

hAppend :: Handle -> Int64 -> ByteString -> IO ()
hAppend h pos s = do
  fixFileSize h pos
  IO.hSeek h SeekFromEnd 0
  B.hPutStr h s

hGetMsgAt :: Handle -> Int64 -> IO (Message, Int64)
hGetMsgAt h pos = do
  IO.hSeek h AbsoluteSeek $ fromIntegral pos
  s <- B.hGetLine h
  case strDecode s of
    Right !msg ->
      let !len = fromIntegral (B.length s) + 1
       in pure (msg, len)
    Left e -> E.throwIO $ userError $ "hGetMsgAt, error parsing message, " <> e

openFile :: FilePath -> IOMode -> IO Handle
openFile f mode = do
  h <- IO.openFile f mode
  IO.hSetBuffering h LineBuffering
  pure h

hClose :: Handle -> IO ()
hClose h = IO.hClose h `catchAny` (\e -> logError $ "Error closing file" <> tshow e)
