{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
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
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Server.MsgStore.Journal
  ( JournalMsgStore (queueStore, random),
    JournalQueue (queueDirectory),
    JournalMsgQueue (state),
    JournalStoreConfig (..),
    closeMsgQueue,
    closeMsgQueueHandles,
    -- below are exported for tests
    MsgQueueState (..),
    JournalState (..),
    SJournalType (..),
    msgQueueDirectory,
    msgQueueStatePath,
    readWriteQueueState,
    newMsgQueueState,
    newJournalId,
    appendState,
    queueLogFileName,
    journalFilePath,
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
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import GHC.IO (catchAny)
import Simplex.Messaging.Agent.Client (getMapLock, withLockMap)
import Simplex.Messaging.Agent.Lock
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.STM
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.Util (anyM, ifM, tshow, ($>>=), (<$$>))
import System.Directory
import System.Exit
import System.FilePath ((</>))
import System.IO (BufferMode (..), Handle, IOMode (..), SeekMode (..), stdout)
import qualified System.IO as IO
import System.Random (StdGen, genByteString, newStdGen)

data JournalMsgStore s = JournalMsgStore
  { config :: JournalStoreConfig s,
    random :: TVar StdGen,
    queueLocks :: TMap RecipientId Lock,
    queueStore :: QueueStore s
  }

data QueueStore (s :: MSType) where
  MQStore ::
    { queues :: TMap RecipientId (JournalQueue 'MSMemory),
      senders :: TMap SenderId RecipientId,
      notifiers :: TMap NotifierId RecipientId,
      storeLog :: TVar (Maybe (StoreLog 'WriteMode))
    } -> QueueStore 'MSMemory
  -- maps store cached queues
  -- Nothing in map indicates that the queue doesn't exist
  JQStore ::
    { queues_ :: TMap RecipientId (Maybe (JournalQueue 'MSJournal)),
      senders_ :: TMap SenderId (Maybe RecipientId),
      notifiers_ :: TMap NotifierId (Maybe RecipientId)
    } -> QueueStore 'MSJournal

data JournalStoreConfig s = JournalStoreConfig
  { storePath :: FilePath,
    pathParts :: Int,
    queueStoreType :: SMSType s,
    quota :: Int,
    -- Max number of messages per journal file - ignored in STM store.
    -- When this limit is reached, the file will be changed.
    -- This number should be set bigger than queue quota.
    maxMsgCount :: Int,
    maxStateLines :: Int,
    stateTailSize :: Int,
    -- time in seconds after which the queue will be closed after message expiration
    idleInterval :: Int64
  }

data JournalQueue (s :: MSType) = JournalQueue
  { recipientId :: RecipientId,
    queueLock :: Lock,
    -- To avoid race conditions and errors when restoring queues,
    -- Nothing is written to TVar when queue is deleted.
    queueRec :: TVar (Maybe QueueRec),
    msgQueue_ :: TVar (Maybe (JournalMsgQueue s)),
    -- system time in seconds since epoch
    activeAt :: TVar Int64,
    -- Just True - empty, Just False - non-empty, Nothing - unknown
    isEmpty :: TVar (Maybe Bool),
    queueDirectory :: FilePath
  }

data JournalMsgQueue (s :: MSType) = JournalMsgQueue
  { state :: TVar MsgQueueState,
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

queueRecFileName :: String
queueRecFileName = "queue_rec"

msgLogFileName :: String
msgLogFileName = "messages"

logFileExt :: String
logFileExt = ".log"

newtype StoreIO (s :: MSType) a = StoreIO {unStoreIO :: IO a}
  deriving newtype (Functor, Applicative, Monad)

instance STMQueueStore (JournalMsgStore 'MSMemory) where
  queues' = queues . queueStore
  senders' = senders . queueStore
  notifiers' = notifiers . queueStore
  storeLog' = storeLog . queueStore
  mkQueue st rId qr = do
    lock <- atomically $ getMapLock (queueLocks st) rId
    makeQueue st lock rId qr

makeQueue :: JournalMsgStore s -> Lock -> RecipientId -> QueueRec -> IO (JournalQueue s)
makeQueue st queueLock rId qr = do
  queueRec <- newTVarIO $ Just qr
  msgQueue_ <- newTVarIO Nothing
  activeAt <- newTVarIO 0
  isEmpty <- newTVarIO Nothing
  pure
    JournalQueue
      { recipientId = rId,
        queueLock,
        queueRec,
        msgQueue_,
        activeAt,
        isEmpty,
        queueDirectory = msgQueueDirectory st rId
      }

instance MsgStoreClass (JournalMsgStore s) where
  type StoreMonad (JournalMsgStore s) = StoreIO s
  type StoreQueue (JournalMsgStore s) = JournalQueue s
  type MsgQueue (JournalMsgStore s) = JournalMsgQueue s
  type MsgStoreConfig (JournalMsgStore s) = (JournalStoreConfig s)

  newMsgStore :: JournalStoreConfig s -> IO (JournalMsgStore s)
  newMsgStore config = do
    random <- newTVarIO =<< newStdGen
    queueLocks :: TMap RecipientId Lock <- TM.emptyIO
    case queueStoreType config of
      SMSMemory -> do
        queues <- TM.emptyIO
        senders <- TM.emptyIO
        notifiers <- TM.emptyIO
        storeLog <- newTVarIO Nothing
        let queueStore = MQStore {queues, senders, notifiers, storeLog}
        pure JournalMsgStore {config, random, queueLocks, queueStore}
      SMSJournal -> do
        queues_ <- TM.emptyIO
        senders_ <- TM.emptyIO
        notifiers_ <- TM.emptyIO
        let queueStore = JQStore {queues_, senders_, notifiers_}
        pure JournalMsgStore {config, random, queueLocks, queueStore}

  setStoreLog :: JournalMsgStore s -> StoreLog 'WriteMode -> IO ()
  setStoreLog st sl = case queueStore st of
    MQStore {storeLog} -> atomically $ writeTVar storeLog (Just sl)
    JQStore {} -> undefined

  closeMsgStore st = case queueStore st of
    MQStore {queues, storeLog} -> do
      readTVarIO storeLog >>= mapM_ closeStoreLog
      readTVarIO queues >>= mapM_ closeMsgQueue
    JQStore {queues_} ->
      readTVarIO queues_ >>= mapM_ (mapM closeMsgQueue)

  activeMsgQueues st = case queueStore st of
    MQStore {queues} -> queues
    JQStore {} -> undefined

  -- This function is a "foldr" that opens and closes all queues, processes them as defined by action and accumulates the result.
  -- It is used to export storage to a single file and also to expire messages and validate all queues when server is started.
  -- TODO this function requires case-sensitive file system, because it uses queue directory as recipient ID.
  -- It can be made to support case-insensite FS by supporting more than one queue per directory, by getting recipient ID from state file name.
  withAllMsgQueues :: forall a. Monoid a => Bool -> JournalMsgStore s -> (JournalQueue s -> IO a) -> IO a
  withAllMsgQueues tty ms@JournalMsgStore {config} action = ifM (doesDirectoryExist storePath) processStore (pure mempty)
    where
      processStore = do
        (!count, !res) <- foldQueues 0 processQueue (0, mempty) ("", storePath)
        putStrLn $ progress count
        pure res
      JournalStoreConfig {storePath, pathParts} = config
      processQueue :: (Int, a) -> (String, FilePath) -> IO (Int, a)
      processQueue (!i, !r) (queueId, dir) = do
        when (tty && i `mod` 100 == 0) $ putStr (progress i <> "\r") >> IO.hFlush stdout
        r' <- case strDecode $ B.pack queueId of
          Right rId ->
            getQueue ms SRecipient rId >>= \case
              Right q -> unStoreIO (getMsgQueue ms q) *> action q <* closeMsgQueue q
              Left AUTH -> do
                logWarn $ "STORE: processQueue, queue " <> T.pack queueId <> " was removed, removing " <> T.pack dir
                removeQueueDirectory_ dir
                pure mempty
              Left e -> do
                logError $ "STORE: processQueue, error getting queue " <> T.pack queueId <> ", " <> tshow e
                exitFailure
          Left e -> do
            logError $ "STORE: processQueue, message queue directory " <> T.pack dir <> " is invalid, " <> tshow e
            exitFailure
        pure (i + 1, r <> r')
      progress i = "Processed: " <> show i <> " queues"
      foldQueues depth f acc (queueId, path) = do
        let f' = if depth == pathParts - 1 then f else foldQueues (depth + 1) f
        listDirs >>= foldM f' acc
        where
          listDirs = fmap catMaybes . mapM queuePath =<< listDirectory path
          queuePath dir = do
            let !path' = path </> dir
                !queueId' = queueId <> dir
            ifM
              (doesDirectoryExist path')
              (pure $ Just (queueId', path'))
              (Nothing <$ putStrLn ("Error: path " <> path' <> " is not a directory, skipping"))

  logQueueStates :: JournalMsgStore s -> IO ()
  logQueueStates ms = withActiveMsgQueues ms $ unStoreIO . logQueueState

  logQueueState :: JournalQueue s -> StoreIO s ()
  logQueueState q =
    StoreIO . void $
      readTVarIO (msgQueue_ q)
        $>>= \mq -> readTVarIO (handles mq)
        $>>= (\hs -> (readTVarIO (state mq) >>= appendState (stateHandle hs)) $> Just ())

  -- TODO [queues] remove pun once recipientId is removed from QueueRec
  recipientId' JournalQueue {recipientId} = recipientId
  {-# INLINE recipientId' #-}

  queueRec' = queueRec
  {-# INLINE queueRec' #-}

  msgQueue_' = msgQueue_
  {-# INLINE msgQueue_' #-}

  queueCounts :: JournalMsgStore s -> IO QueueCounts
  queueCounts st = case queueStore st of
    MQStore {queues, notifiers} -> do
      queueCount <- M.size <$> readTVarIO queues
      notifierCount <- M.size <$> readTVarIO notifiers
      pure QueueCounts {queueCount, notifierCount}
    JQStore {queues_, notifiers_} -> do
      queueCount <- M.size <$> readTVarIO queues_
      notifierCount <- M.size <$> readTVarIO notifiers_
      pure QueueCounts {queueCount, notifierCount}

  addQueue :: JournalMsgStore s -> RecipientId -> QueueRec -> IO (Either ErrorType (JournalQueue s))
  addQueue st@JournalMsgStore {queueLocks = ls} rId qr@QueueRec {senderId = sId, notifier} = case queueStore st of
    MQStore {} -> addQueue' st rId qr
    JQStore {queues_, senders_, notifiers_} -> do
      lock <- atomically $ getMapLock ls rId
      tryStore "addQueue" rId $
        withLock' lock "addQueue" $ withLockMap ls sId "addQueueS" $ withNotifierLock $
          ifM hasAnyId (pure $ Left DUPLICATE_) $ E.uninterruptibleMask_ $ do
            q <- makeQueue st lock rId qr
            -- TODO [queues] maybe createQueueDir
            storeQueue_ q qr
            atomically $ TM.insert rId (Just q) queues_
            saveQueueRef st sId rId senders_
            forM_ notifier $ \NtfCreds {notifierId} -> saveQueueRef st notifierId rId notifiers_
            pure $ Right q
      where
        hasAnyId = anyM [hasId rId queues_, hasId sId senders_, withNotifier (`hasId` notifiers_), hasDir rId, hasDir sId, withNotifier hasDir]
        withNotifier p = maybe (pure False) (\NtfCreds {notifierId} -> p notifierId) notifier
        withNotifierLock a = maybe a (\NtfCreds {notifierId} -> withLockMap ls notifierId "addQueueN" a) notifier
        hasId :: EntityId -> TMap EntityId (Maybe a) -> IO Bool
        hasId qId m = maybe False isJust <$> atomically (TM.lookup qId m)
        hasDir qId = doesDirectoryExist $ msgQueueDirectory st qId

  getQueue :: DirectParty p => JournalMsgStore s -> SParty p -> QueueId -> IO (Either ErrorType (JournalQueue s))
  getQueue st party qId = case queueStore st of
    MQStore {} -> getQueue' st party qId
    JQStore {queues_, senders_, notifiers_} ->
      isolateQueueId "getQueue" st qId $
        maybe (Left AUTH) Right <$> case party of
          SRecipient -> getQueue_ qId
          SSender -> getQueueRef senders_ $>>= getQueue_
          SNotifier -> getQueueRef notifiers_ $>>= getQueue_
      where
        getQueue_ rId = TM.lookupIO rId queues_ >>= maybe (loadQueue rId) pure
        getQueueRef :: TMap EntityId (Maybe RecipientId) -> IO (Maybe RecipientId)
        getQueueRef m = TM.lookupIO qId m >>= maybe (loadQueueRef m) pure
        loadQueue _rId = undefined -- TODO [queues] load, cache, return queue
        loadQueueRef _m = undefined -- TODO [queues] load, cache, return queue ID

  secureQueue :: JournalMsgStore s -> JournalQueue s -> SndPublicAuthKey -> IO (Either ErrorType ())
  secureQueue st sq sKey = case queueStore st of
    MQStore {} -> secureQueue' st sq sKey
    JQStore {} ->
      isolateQueueRec sq "secureQueue" $ \q -> case senderKey q of
        Just k -> pure $ if sKey == k then Right () else Left AUTH
        Nothing -> storeQueue sq q {senderKey = Just sKey} $> Right ()

  addQueueNotifier :: JournalMsgStore s -> JournalQueue s -> NtfCreds -> IO (Either ErrorType (Maybe NotifierId))
  addQueueNotifier st sq ntfCreds@NtfCreds {notifierId = nId} = case queueStore st of
    MQStore {} -> addQueueNotifier' st sq ntfCreds
    JQStore {notifiers_} ->
      isolateQueueRec sq "addQueueNotifier" $ \q ->
        withLockMap (queueLocks st) nId "addQueueNotifierN" $
          ifM hasNotifierId (pure $ Left DUPLICATE_) $ do
            nId_ <- forM (notifier q) $ \NtfCreds {notifierId = nId'} -> 
              withLockMap (queueLocks st) nId' "addQueueNotifierD" $
                deleteQueueRef st nId' notifiers_ $> nId'
            storeQueue sq q {notifier = Just ntfCreds}
            saveQueueRef st nId (recipientId sq) notifiers_
            pure $ Right nId_
      where
        hasNotifierId = anyM [hasId, hasDir]
        hasId = maybe False isJust <$> atomically (TM.lookup nId notifiers_)
        hasDir = doesDirectoryExist $ msgQueueDirectory st nId

  deleteQueueNotifier :: JournalMsgStore s -> JournalQueue s -> IO (Either ErrorType (Maybe NotifierId))
  deleteQueueNotifier st sq = case queueStore st of
    MQStore {} -> deleteQueueNotifier' st sq
    JQStore {notifiers_} ->
      isolateQueueRec sq "deleteQueueNotifier" $ \q ->
        fmap Right $ forM (notifier q) $ \NtfCreds {notifierId = nId} ->
          withLockMap (queueLocks st) nId "deleteQueueNotifierN" $ do
            deleteQueueRef st nId notifiers_
            storeQueue sq q {notifier = Nothing}
            pure nId

  suspendQueue :: JournalMsgStore s -> JournalQueue s -> IO (Either ErrorType ())
  suspendQueue st sq = case queueStore st of
    MQStore {} -> suspendQueue' st sq
    JQStore {} ->
      isolateQueueRec sq "suspendQueue" $ \q ->
        fmap Right $ storeQueue sq q {status = QueueOff}

  updateQueueTime :: JournalMsgStore s -> JournalQueue s -> RoundedSystemTime -> IO (Either ErrorType QueueRec)
  updateQueueTime st sq t = case queueStore st of
    MQStore {} -> updateQueueTime' st sq t
    JQStore {} -> isolateQueueRec sq "updateQueueTime" $ fmap Right . update
      where
        update q@QueueRec {updatedAt}
          | updatedAt == Just t = pure q
          | otherwise =
              let !q' = q {updatedAt = Just t}
               in storeQueue sq q' $> q'

  getMsgQueue :: JournalMsgStore s -> JournalQueue s -> StoreIO s (JournalMsgQueue s)
  getMsgQueue ms@JournalMsgStore {random} sq@JournalQueue {msgQueue_, queueDirectory} =
    StoreIO $ readTVarIO msgQueue_ >>= maybe newQ pure
    where
      newQ = do
        -- TODO [queues] this should account for the possibility that the folder exists,
        -- but queue messaging files do not, which will always be the case when queue record is in journals
        q <- ifM (doesDirectoryExist queueDirectory) (openMsgQueue ms sq) createQ
        atomically $ writeTVar msgQueue_ $ Just q
        pure q
        where
          createQ :: IO (JournalMsgQueue s)
          createQ = do
            -- folder and files are not created here,
            -- to avoid file IO for queues without messages during subscription
            journalId <- newJournalId random
            mkJournalQueue (newMsgQueueState journalId) Nothing

  getPeekMsgQueue :: JournalMsgStore s -> JournalQueue s -> StoreIO s (Maybe (JournalMsgQueue s, Message))
  getPeekMsgQueue ms q@JournalQueue {isEmpty} =
    StoreIO (readTVarIO isEmpty) >>= \case
      Just True -> pure Nothing
      Just False -> peek
      Nothing -> do
        -- We only close the queue if we just learnt it's empty.
        -- This is needed to reduce file descriptors and memory usage
        -- after the server just started and many clients subscribe.
        -- In case the queue became non-empty on write and then again empty on read
        -- we won't be closing it, to avoid frequent open/close on active queues.
        r <- peek
        when (isNothing r) $ StoreIO $ closeMsgQueue q
        pure r
    where
      peek = do
        mq <- getMsgQueue ms q
        (mq,) <$$> tryPeekMsg_ q mq

  -- only runs action if queue is not empty
  withIdleMsgQueue :: Int64 -> JournalMsgStore s -> JournalQueue s -> (JournalMsgQueue s -> StoreIO s a) -> StoreIO s (Maybe a, Int)
  withIdleMsgQueue now ms@JournalMsgStore {config} q action =
    StoreIO $ readTVarIO (msgQueue_ q) >>= \case
      Nothing ->
        E.bracket
          (unStoreIO $ getPeekMsgQueue ms q)
          (mapM_ $ \_ -> closeMsgQueue q)
          (maybe (pure (Nothing, 0)) (unStoreIO . run))
        where
          run (mq, _) = do
            r <- action mq
            sz <- getQueueSize_ mq
            pure (Just r, sz)
      Just mq -> do
        ts <- readTVarIO $ activeAt q
        r <- if now - ts >= idleInterval config
          then Just <$> unStoreIO (action mq) `E.finally` closeMsgQueue q
          else pure Nothing
        sz <- unStoreIO $ getQueueSize_ mq
        pure (r, sz)

  deleteQueue :: JournalMsgStore s -> JournalQueue s -> IO (Either ErrorType QueueRec)
  deleteQueue ms q = fst <$$> deleteQueue_ ms q

  deleteQueueSize :: JournalMsgStore s -> JournalQueue s -> IO (Either ErrorType (QueueRec, Int))
  deleteQueueSize ms q =
    deleteQueue_ ms q >>= mapM (traverse getSize)
    -- traverse operates on the second tuple element
    where
      getSize = maybe (pure (-1)) (fmap size . readTVarIO . state)

  getQueueMessages_ :: Bool -> JournalQueue s -> JournalMsgQueue s -> StoreIO s [Message]
  getQueueMessages_ drainMsgs sq q = StoreIO (run [])
    where
      run msgs = readTVarIO (handles q) >>= maybe (pure []) (getMsg msgs)
      getMsg msgs hs = chooseReadJournal sq q drainMsgs hs >>= maybe (pure msgs) readMsg
        where
          readMsg (rs, h) = do
            (msg, len) <- hGetMsgAt h $ bytePos rs
            updateReadPos q drainMsgs len hs
            (msg :) <$> run msgs

  writeMsg :: JournalMsgStore s -> JournalQueue s -> Bool -> Message -> ExceptT ErrorType IO (Maybe (Message, Bool))
  writeMsg ms q'@JournalQueue {recipientId, queueDirectory = dir} logState msg = isolateQueue q' "writeMsg" $ do
    q <- getMsgQueue ms q'
    StoreIO $ (`E.finally` updateActiveAt q') $ do
      st@MsgQueueState {canWrite, size} <- readTVarIO (state q)
      let empty = size == 0
      if canWrite || empty
        then do
          atomically $ writeTVar (isEmpty q') (Just False)
          let canWrt' = quota > size
          if canWrt'
            then writeToJournal q st canWrt' msg $> Just (msg, empty)
            else writeToJournal q st canWrt' msgQuota $> Nothing
        else pure Nothing
    where
      JournalStoreConfig {quota, maxMsgCount} = config ms
      msgQuota = MessageQuota {msgId = messageId msg, msgTs = messageTs msg}
      writeToJournal q@JournalMsgQueue {handles} st@MsgQueueState {writeState, readState = rs, size} canWrt' !msg' = do
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
        hAppend wh (bytePos ws) msgStr
        updateQueueState q logState hs st' $
          when (size == 0) $ writeTVar (tipMsg q) $ Just (Just (msg, msgLen))
        where
          createQueueDir = do
            createDirectoryIfMissing True dir
            let statePath = msgQueueStatePath dir $ B.unpack (strEncode recipientId)
            sh <- openFile statePath AppendMode
            B.hPutStr sh ""
            rh <- createNewJournal dir $ journalId rs
            let hs = MsgQueueHandles {stateHandle = sh, readHandle = rh, writeHandle = Nothing}
            atomically $ writeTVar handles $ Just hs
            pure hs
          switchWriteJournal hs = do
            journalId <- newJournalId $ random ms
            wh <- createNewJournal dir journalId
            atomically $ writeTVar handles $ Just $ hs {writeHandle = Just wh}
            pure (newJournalState journalId, wh)

  -- can ONLY be used while restoring messages, not while server running
  setOverQuota_ :: JournalQueue s -> IO ()
  setOverQuota_ q =
    readTVarIO (msgQueue_ q)
      >>= mapM_ (\JournalMsgQueue {state} -> atomically $ modifyTVar' state $ \st -> st {canWrite = False})

  getQueueSize_ :: JournalMsgQueue s -> StoreIO s Int
  getQueueSize_ JournalMsgQueue {state} = StoreIO $ size <$> readTVarIO state
  {-# INLINE getQueueSize_ #-}

  tryPeekMsg_ :: JournalQueue s -> JournalMsgQueue s -> StoreIO s (Maybe Message)
  tryPeekMsg_ q mq@JournalMsgQueue {tipMsg, handles} =
    StoreIO $ (readTVarIO handles $>>= chooseReadJournal q mq True $>>= peekMsg) >>= setEmpty
    where
      peekMsg (rs, h) = readTVarIO tipMsg >>= maybe readMsg (pure . fmap fst)
        where
          readMsg = do
            ml@(msg, _) <- hGetMsgAt h $ bytePos rs
            atomically $ writeTVar tipMsg $ Just (Just ml)
            pure $ Just msg
      setEmpty msg = do
        atomically $ writeTVar (isEmpty q) (Just $ isNothing msg)
        pure msg

  tryDeleteMsg_ :: JournalQueue s -> JournalMsgQueue s -> Bool -> StoreIO s ()
  tryDeleteMsg_ q mq@JournalMsgQueue {tipMsg, handles} logState = StoreIO $ (`E.finally` when logState (updateActiveAt q)) $
    void $
      readTVarIO tipMsg -- if there is no cached tipMsg, do nothing
        $>>= (pure . fmap snd)
        $>>= \len -> readTVarIO handles
        $>>= \hs -> updateReadPos mq logState len hs $> Just ()

  isolateQueue :: JournalQueue s -> String -> StoreIO s a -> ExceptT ErrorType IO a
  isolateQueue q op = ExceptT . isolateQueue_ q op . fmap Right . unStoreIO
  {-# INLINE isolateQueue #-}

updateActiveAt :: JournalQueue s -> IO ()
updateActiveAt q = atomically . writeTVar (activeAt q) . systemSeconds =<< getSystemTime

tryStore :: forall a. String -> RecipientId -> IO (Either ErrorType a) -> IO (Either ErrorType a)
tryStore op rId a = E.mask_ $ E.try a >>= either storeErr pure
  where
    storeErr :: E.SomeException -> IO (Either ErrorType a)
    storeErr e =
      let e' = intercalate ", " [op, B.unpack $ strEncode rId, show e]
       in logError ("STORE: " <> T.pack e') $> Left (STORE e')

isolateQueueRec :: JournalQueue s -> String -> (QueueRec -> IO (Either ErrorType a)) -> IO (Either ErrorType a)
isolateQueueRec sq op a = isolateQueue_ sq op (atomically (readQueueRec qr) $>>= a)
  where
    qr = queueRec sq

isolateQueue_ :: JournalQueue s -> String -> IO (Either ErrorType a) -> IO (Either ErrorType a)
isolateQueue_ JournalQueue {recipientId, queueLock} op = tryStore op recipientId . withLock' queueLock op

isolateQueueId :: String -> JournalMsgStore s -> RecipientId -> IO (Either ErrorType a) -> IO (Either ErrorType a)
isolateQueueId op ms rId = tryStore op rId . withLockMap (queueLocks ms) rId op

storeQueue :: JournalQueue s -> QueueRec -> IO ()
storeQueue sq@JournalQueue {queueRec} q = do
  storeQueue_ sq q
  atomically $ writeTVar queueRec $ Just q

-- TODO [queues]
deleteQueueDir :: JournalQueue s -> IO ()
deleteQueueDir _sq = pure ()

-- TODO [queues]
saveQueueRef :: JournalMsgStore s -> QueueId -> RecipientId -> TMap QueueId (Maybe RecipientId) -> IO ()
saveQueueRef _st qId rId m = do
  pure () -- save ref to disk
  atomically $ TM.insert qId (Just rId) m

-- TODO [queues]
deleteQueueRef :: JournalMsgStore s -> QueueId -> TMap QueueId (Maybe RecipientId) -> IO ()
deleteQueueRef _st qId m = do
  pure () -- delete ref from disk
  atomically $ TM.delete qId m

-- TODO [queues]
storeQueue_ :: JournalQueue s -> QueueRec -> IO ()
storeQueue_ JournalQueue {recipientId, queueDirectory} _q = pure () -- save queue to disk
  where
    _queuePath = queueRecPath queueDirectory $ B.unpack (strEncode recipientId)

openMsgQueue :: JournalMsgStore s -> JournalQueue s -> IO (JournalMsgQueue s)
openMsgQueue ms JournalQueue {recipientId, queueDirectory = dir} = do
  let statePath = msgQueueStatePath dir $ B.unpack (strEncode recipientId)
  (st, sh) <- readWriteQueueState ms statePath
  (st', rh, wh_) <- closeOnException sh $ openJournals ms dir st sh
  let hs = MsgQueueHandles {stateHandle = sh, readHandle = rh, writeHandle = wh_}
  mkJournalQueue st' (Just hs)

mkJournalQueue :: MsgQueueState -> Maybe MsgQueueHandles -> IO (JournalMsgQueue s)
mkJournalQueue st hs_ = do
  state <- newTVarIO st
  tipMsg <- newTVarIO Nothing
  handles <- newTVarIO hs_
  pure JournalMsgQueue {state, tipMsg, handles}

chooseReadJournal :: JournalQueue s -> JournalMsgQueue s -> Bool -> MsgQueueHandles -> IO (Maybe (JournalState 'JTRead, Handle))
chooseReadJournal sq q log' hs = do
  st@MsgQueueState {writeState = ws, readState = rs} <- readTVarIO (state q)
  case writeHandle hs of
    Just wh | msgPos rs >= msgCount rs && journalId rs /= journalId ws -> do
      -- switching to write journal
      atomically $ writeTVar (handles q) $ Just hs {readHandle = wh, writeHandle = Nothing}
      hClose $ readHandle hs
      when log' $ removeJournal (queueDirectory sq) rs
      let !rs' = (newJournalState $ journalId ws) {msgCount = msgCount ws, byteCount = byteCount ws}
          !st' = st {readState = rs'}
      updateQueueState q log' hs st' $ pure ()
      pure $ Just (rs', wh)
    _ | msgPos rs >= msgCount rs && journalId rs == journalId ws -> pure Nothing
    _ -> pure $ Just (rs, readHandle hs)

updateQueueState :: JournalMsgQueue s -> Bool -> MsgQueueHandles -> MsgQueueState -> STM () -> IO ()
updateQueueState q log' hs st a = do
  unless (validQueueState st) $ E.throwIO $ userError $ "updateQueueState invalid state: " <> show st
  when log' $ appendState (stateHandle hs) st
  atomically $ writeTVar (state q) st >> a

appendState :: Handle -> MsgQueueState -> IO ()
appendState h st = E.uninterruptibleMask_ $ B.hPutStr h $ strEncode st `B.snoc` '\n'

updateReadPos :: JournalMsgQueue s -> Bool -> Int64 -> MsgQueueHandles -> IO ()
updateReadPos q log' len hs = do
  st@MsgQueueState {readState = rs, size} <- readTVarIO (state q)
  let JournalState {msgPos, bytePos} = rs
  let msgPos' = msgPos + 1
      rs' = rs {msgPos = msgPos', bytePos = bytePos + len}
      st' = st {readState = rs', size = size - 1}
  updateQueueState q log' hs st' $ writeTVar (tipMsg q) Nothing

msgQueueDirectory :: JournalMsgStore s -> RecipientId -> FilePath
msgQueueDirectory JournalMsgStore {config = JournalStoreConfig {storePath, pathParts}} rId =
  storePath </> B.unpack (B.intercalate "/" $ splitSegments pathParts $ strEncode rId)
  where
    splitSegments _ "" = []
    splitSegments 1 s = [s]
    splitSegments n s =
      let (seg, s') = B.splitAt 2 s
       in seg : splitSegments (n - 1) s'

queueRecPath :: FilePath -> String -> FilePath
queueRecPath dir queueId = dir </> (queueRecFileName <> "." <> queueId <> logFileExt)

msgQueueStatePath :: FilePath -> String -> FilePath
msgQueueStatePath dir queueId = dir </> (queueLogFileName <> "." <> queueId <> logFileExt)

createNewJournal :: FilePath -> ByteString -> IO Handle
createNewJournal dir journalId = do
  let path = journalFilePath dir journalId -- TODO [queues] retry if file exists
  h <- openFile path ReadWriteMode
  B.hPutStr h ""
  pure h

newJournalId :: TVar StdGen -> IO ByteString
newJournalId g = strEncode <$> atomically (stateTVar g $ genByteString 12)

openJournals :: JournalMsgStore s -> FilePath -> MsgQueueState -> Handle -> IO (MsgQueueState, Handle, Maybe Handle)
openJournals ms dir st@MsgQueueState {readState = rs, writeState = ws} sh = do
  let rjId = journalId rs
      wjId = journalId ws
  openJournal rs >>= \case
    Left path
      | rjId == wjId -> do
          logError $ "STORE: openJournals, no read/write file - creating new file, " <> T.pack path
          newReadJournal
      | otherwise -> do
          let rs' = (newJournalState wjId) {msgCount = msgCount ws, byteCount = byteCount ws}
              st' = st {readState = rs', size = msgCount ws}
          openJournal rs' >>= \case
            Left path' -> do
              logError $ "STORE: openJournals, no read and write files - creating new file, read: " <> T.pack path <> ", write: " <> T.pack path'
              newReadJournal
            Right rh -> do
              logError $ "STORE: openJournals, no read file - switched to write file, " <> T.pack path
              closeOnException rh $ fixFileSize rh $ bytePos ws
              pure (st', rh, Nothing)
    Right rh
      | rjId == wjId -> do
          closeOnException rh $ fixFileSize rh $ bytePos ws
          pure (st, rh, Nothing)
      | otherwise -> closeOnException rh $ do
          fixFileSize rh $ byteCount rs
          openJournal ws >>= \case
            Left path -> do
              let msgs = msgCount rs
                  bytes = byteCount rs
                  size' = msgs - msgPos rs
                  ws' = (newJournalState rjId) {msgPos = msgs, msgCount = msgs, bytePos = bytes, byteCount = bytes}
                  st' = st {writeState = ws', size = size'} -- we don't amend canWrite to trigger QCONT
              logError $ "STORE: openJournals, no write file, " <> T.pack path
              pure (st', rh, Nothing)
            Right wh -> do
              closeOnException wh $ fixFileSize wh $ bytePos ws
              pure (st, rh, Just wh)
  where
    newReadJournal = do
      rjId' <- newJournalId $ random ms
      rh <- createNewJournal dir rjId'
      let st' = newMsgQueueState rjId'
      closeOnException rh $ appendState sh st'
      pure (st', rh, Nothing)
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
        name <- IO.hShow h
        logWarn $ "STORE: fixFileSize, size " <> tshow size <> " > pos " <> tshow pos <> " - truncating, " <> T.pack name
        IO.hSetFileSize h pos'
    | size < pos' -> do
        -- From code logic this can't happen.
        name <- IO.hShow h
        E.throwIO $ userError $ "fixFileSize size " <> show size <> " < pos " <> show pos <> " - aborting: " <> name
    | otherwise -> pure ()

removeJournal :: FilePath -> JournalState t -> IO ()
removeJournal dir JournalState {journalId} = do
  let path = journalFilePath dir journalId
  removeFile path `catchAny` (\e -> logError $ "STORE: removeJournal, " <> T.pack path <> ", " <> tshow e)

-- This function is supposed to be resilient to crashes while updating state files,
-- and also resilient to crashes during its execution.
readWriteQueueState :: JournalMsgStore s -> FilePath -> IO (MsgQueueState, Handle)
readWriteQueueState JournalMsgStore {random, config} statePath =
  ifM
    (doesFileExist tempBackup)
    (renameFile tempBackup statePath >> readQueueState)
    (ifM (doesFileExist statePath) readQueueState writeNewQueueState)
  where
    tempBackup = statePath <> ".bak"
    readQueueState = do
      ls <- B.lines <$> readFileTail
      case ls of
        [] -> writeNewQueueState
        _ -> do
          r@(st, _) <- useLastLine (length ls) True ls
          unless (validQueueState st) $ E.throwIO $ userError $ "readWriteQueueState inconsistent state: " <> show st
          pure r
    writeNewQueueState = do
      logWarn $ "STORE: readWriteQueueState, empty queue state - initialized, " <> T.pack statePath
      st <- newMsgQueueState <$> newJournalId random
      writeQueueState st
    useLastLine len isLastLine ls = case strDecode $ last ls of
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
              logWarn $ "STORE: readWriteQueueState, invalid 1-line queue state - initialized, " <> T.pack statePath
              st <- newMsgQueueState <$> newJournalId random
              backupWriteQueueState st
            ls' -> do
              logWarn $ "STORE: readWriteQueueState, invalid last line in queue state - using the previous line, " <> T.pack statePath
              useLastLine len False ls'
        | otherwise -> E.throwIO $ userError $ "readWriteQueueState invalid state " <> statePath <> ": " <> show e
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
      closeOnException sh $ appendState sh st
      pure (st, sh)
    readFileTail =
      IO.withFile statePath ReadMode $ \h -> do
        size <- IO.hFileSize h
        let sz = stateTailSize config
            sz' = fromIntegral sz
        if size > sz'
          then IO.hSeek h AbsoluteSeek (size - sz') >> B.hGet h sz
          else B.hGet h (fromIntegral size)

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

deleteQueue_ :: forall s. JournalMsgStore s -> JournalQueue s -> IO (Either ErrorType (QueueRec, Maybe (JournalMsgQueue s)))
deleteQueue_ st sq =
  isolateQueueId "deleteQueue_" st rId $ 
    delete >>= mapM (traverse remove)
  where
    rId = recipientId sq
    qr = queueRec sq
    delete :: IO (Either ErrorType (QueueRec, Maybe (JournalMsgQueue s)))
    delete = case queueStore st of
      MQStore {} -> deleteQueue' st sq
      JQStore {senders_, notifiers_} -> atomically (readQueueRec qr) >>= mapM jqDelete
        where
          jqDelete q = E.uninterruptibleMask_ $ do
            deleteQueueRef st (senderId q) senders_
            forM_ (notifier q) $ \NtfCreds {notifierId} -> deleteQueueRef st notifierId notifiers_
            deleteQueueDir sq
            atomically $ writeTVar qr Nothing
            (q,) <$> atomically (swapTVar (msgQueue_' sq) Nothing)
    remove :: Maybe (JournalMsgQueue s) -> IO (Maybe (JournalMsgQueue s))
    remove mq = do
      mapM_ closeMsgQueueHandles mq
      removeQueueDirectory st rId
      pure mq

closeMsgQueue :: JournalQueue s -> IO ()
closeMsgQueue JournalQueue {msgQueue_} = atomically (swapTVar msgQueue_ Nothing) >>= mapM_ closeMsgQueueHandles

closeMsgQueueHandles :: JournalMsgQueue s -> IO ()
closeMsgQueueHandles q = readTVarIO (handles q) >>= mapM_ closeHandles
  where
    closeHandles (MsgQueueHandles sh rh wh_) = do
      hClose sh
      hClose rh
      mapM_ hClose wh_

removeQueueDirectory :: JournalMsgStore s -> RecipientId -> IO ()
removeQueueDirectory st = removeQueueDirectory_ . msgQueueDirectory st

removeQueueDirectory_ :: FilePath -> IO ()
removeQueueDirectory_ dir =
  removePathForcibly dir `catchAny` \e ->
    logError $ "STORE: removeQueueDirectory, " <> T.pack dir <> ", " <> tshow e

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
    Left e -> E.throwIO $ userError $ "hGetMsgAt invalid message: " <> e

openFile :: FilePath -> IOMode -> IO Handle
openFile f mode = do
  h <- IO.openFile f mode
  IO.hSetBuffering h LineBuffering
  pure h

hClose :: Handle -> IO ()
hClose h =
  IO.hClose h `catchAny` \e -> do
    name <- IO.hShow h
    logError $ "STORE: hClose, " <> T.pack name <> ", " <> tshow e

closeOnException :: Handle -> IO a -> IO a
closeOnException h a = a `E.onException` hClose h
