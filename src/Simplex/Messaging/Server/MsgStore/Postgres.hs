{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.Messaging.Server.MsgStore.Postgres
  ( PostgresMsgStore,
    PostgresMsgStoreCfg (..),
  )
where

import Control.Concurrent.STM
import Control.Monad
import Control.Monad.Reader
import Control.Monad.Trans.Except
import qualified Data.ByteString as B
import Data.Functor (($>))
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import Data.Time.Clock.System (SystemTime (..))
import Database.PostgreSQL.Simple (Binary (..), Only (..))
import qualified Database.PostgreSQL.Simple as DB
import Database.PostgreSQL.Simple.SqlQQ (sql)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.Postgres
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.Util (firstRow, maybeFirstRow, (<$$>))

data PostgresMsgStore = PostgresMsgStore
  { config :: PostgresMsgStoreCfg,
    queueStore_ :: PostgresQueueStore'
  }

data PostgresMsgStoreCfg = PostgresMsgStoreCfg
  { queueStoreCfg :: PostgresStoreCfg,
    quota :: Int
  }

type PostgresQueueStore' = PostgresQueueStore PostgresQueue

data PostgresQueue = PostgresQueue
  { recipientId' :: RecipientId,
    queueRec' :: TVar (Maybe QueueRec)
  }

data MsgQueueState = MsgQueueState
  { canWrt :: Bool,
    size :: Int
  }

instance StoreQueueClass PostgresQueue where
  -- type MsgQueue PostgresQueue = ()
  recipientId = recipientId'
  {-# INLINE recipientId #-}
  queueRec = queueRec'
  {-# INLINE queueRec #-}
  -- msgQueue = msgQueue'
  -- {-# INLINE msgQueue #-}
  withQueueLock PostgresQueue {} _ = id -- TODO [messages] maybe it's just transaction?
  {-# INLINE withQueueLock #-}

newtype DBTransaction = DBTransaction {dbConn :: DB.Connection}

type DBStoreIO a = ReaderT DBTransaction IO a

instance MsgStoreClass PostgresMsgStore where
  type StoreMonad PostgresMsgStore = ReaderT DBTransaction IO
  type MsgQueue PostgresMsgStore = ()
  type QueueStore PostgresMsgStore = PostgresQueueStore'
  type StoreQueue PostgresMsgStore = PostgresQueue
  type MsgStoreConfig PostgresMsgStore = PostgresMsgStoreCfg

  newMsgStore :: PostgresMsgStoreCfg -> IO PostgresMsgStore
  newMsgStore config = do
    queueStore_ <- newQueueStore @PostgresQueue $ queueStoreCfg config
    pure PostgresMsgStore {config, queueStore_}

  closeMsgStore :: PostgresMsgStore -> IO ()
  closeMsgStore = closeQueueStore @PostgresQueue . queueStore_

  withActiveMsgQueues :: Monoid a => PostgresMsgStore -> (PostgresQueue -> IO a) -> IO a
  withActiveMsgQueues _ _ = error "TODO withActiveMsgQueues"

  -- This function can only be used in server CLI commands or before server is started.
  -- tty, withData, store
  unsafeWithAllMsgQueues :: Monoid a => Bool -> Bool -> PostgresMsgStore -> (PostgresQueue -> IO a) -> IO a
  unsafeWithAllMsgQueues _ _ _ _ = error "TODO unsafeWithAllMsgQueues"

  -- tty, store, now, ttl
  expireOldMessages :: Bool -> PostgresMsgStore -> Int64 -> Int64 -> IO MessageStats
  expireOldMessages _ _ _ _ = error "TODO expireOldMessages"

  logQueueStates _ = pure ()
  {-# INLINE logQueueStates #-}
  logQueueState _ = pure ()
  {-# INLINE logQueueState #-}
  queueStore = queueStore_
  {-# INLINE queueStore #-}

  loadedQueueCounts :: PostgresMsgStore -> IO LoadedQueueCounts
  loadedQueueCounts ms = do
    loadedQueueCount <- M.size <$> readTVarIO queues
    loadedNotifierCount <- M.size <$> readTVarIO notifiers
    -- openJournalCount <- readTVarIO (openedQueueCount ms)
    -- queueLockCount <- M.size <$> readTVarIO (queueLocks ms)
    notifierLockCount <- M.size <$> readTVarIO notifierLocks
    pure LoadedQueueCounts {loadedQueueCount, loadedNotifierCount, openJournalCount = 0, queueLockCount = 0, notifierLockCount}
    where
      PostgresQueueStore {queues, notifiers, notifierLocks} = queueStore_ ms

  mkQueue :: PostgresMsgStore -> Bool -> RecipientId -> QueueRec -> IO PostgresQueue
  mkQueue _ _keepLock rId qr = PostgresQueue rId <$> newTVarIO (Just qr)
  {-# INLINE mkQueue #-}

  getMsgQueue _ _ _ = pure ()
  {-# INLINE getMsgQueue #-}

  getPeekMsgQueue :: PostgresMsgStore -> PostgresQueue -> DBStoreIO (Maybe ((), Message))
  getPeekMsgQueue _ q = ((),) <$$> tryPeekMsg_ q ()

  -- the journal queue will be closed after action if it was initially closed or idle longer than interval in config
  withIdleMsgQueue :: Int64 -> PostgresMsgStore -> PostgresQueue -> (() -> DBStoreIO a) -> DBStoreIO (Maybe a, Int)
  withIdleMsgQueue _ _ _ _ = error "TODO withIdleMsgQueue"

  deleteQueue :: PostgresMsgStore -> PostgresQueue -> IO (Either ErrorType QueueRec)
  deleteQueue ms q = deleteStoreQueue (queueStore_ ms) q
  {-# INLINE deleteQueue #-}

  deleteQueueSize :: PostgresMsgStore -> PostgresQueue -> IO (Either ErrorType (QueueRec, Int))
  deleteQueueSize _ _ = error "TODO deleteQueueSize"

  getQueueMessages_ :: Bool -> PostgresQueue -> () -> DBStoreIO [Message]
  getQueueMessages_ _ _ _ = error "TODO getQueueMessages_"

  writeMsg :: PostgresMsgStore -> PostgresQueue -> Bool -> Message -> ExceptT ErrorType IO (Maybe (Message, Bool))
  writeMsg ms q' _logState msg =
    withDB "writeMsg" (queueStore_ ms) $ \db -> runExceptT $ do
      (canWrt, size) :: (Bool, Int) <- ExceptT $ getMsgQueueState db
      let empty = size == 0
      -- can_write and size columns should be updated by triggers
      if canWrt || empty
        then case msg of
          Message {msgFlags = MsgFlags ntf, msgBody = C.MaxLenBS body}
            | size < quota ->
                storeMessage db False ntf body $> Just (msg, empty)
          _ -> storeMessage db True False B.empty $> Nothing
        else pure Nothing
    where
      rId = recipientId' q'
      getMsgQueueState db =
        liftIO $ firstRow id AUTH $
          DB.query db "SELECT msg_can_write, msg_queue_size FROM msg_queues WHERE recipient_id = ?" (Only rId)
      storeMessage db msgQuota ntf body =
        liftIO $
          DB.execute
            db
            "INSERT INTO messages(recipient_id, msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body) VALUES (?,?,?,?,?,?)"
            (rId, Binary (messageId msg), systemSeconds (messageTs msg), msgQuota, ntf, Binary body)
      PostgresMsgStore {config = PostgresMsgStoreCfg {quota}} = ms

  setOverQuota_ :: PostgresQueue -> IO () -- can ONLY be used while restoring messages, not while server running
  setOverQuota_ _ = error "TODO setOverQuota_"

  getQueueSize_ :: () -> DBStoreIO Int
  getQueueSize_ _ = error "TODO getQueueSize_"

  tryPeekMsg_ :: PostgresQueue -> () -> DBStoreIO (Maybe Message)
  tryPeekMsg_ q _ = do
    db <- asks dbConn
    liftIO $ maybeFirstRow toMessage $
      DB.query
        db
        [sql|
          SELECT msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body
          FROM messages
          WHERE recipient_id = ?
          ORDER BY message_id ASC LIMIT 1
        |]
        (Only (recipientId' q))

  tryDeleteMsg_ :: PostgresQueue -> () -> Bool -> DBStoreIO ()
  tryDeleteMsg_ q _ _ = do
    db <- asks dbConn
    liftIO $ void $
      DB.execute
        db
        -- "DELETE FROM messages WHERE recipient_id = ? ORDER BY message_id ASC LIMIT 1"
        "DELETE FROM messages WHERE message_id = (SELECT MIN(message_id) FROM messages WHERE recipient_id = ?)"
        (Only (recipientId' q))

  isolateQueue :: PostgresMsgStore -> PostgresQueue -> Text -> DBStoreIO a -> ExceptT ErrorType IO a
  isolateQueue ms _q op a = withDB' op (queueStore_ ms) $ runReaderT a . DBTransaction

  unsafeRunStore :: PostgresQueue -> Text -> DBStoreIO a -> IO a
  unsafeRunStore _ _ _ = error "TODO unsafeRunStore"

  tryPeekMsg :: PostgresMsgStore -> PostgresQueue -> ExceptT ErrorType IO (Maybe Message)
  tryPeekMsg ms q = isolateQueue ms q "tryPeekMsg" $ tryPeekMsg_ q ()
  {-# INLINE tryPeekMsg #-}

  tryDelMsg :: PostgresMsgStore -> PostgresQueue -> MsgId -> ExceptT ErrorType IO (Maybe Message)
  tryDelMsg ms q msgId =
    withDB' "tryDelMsg" (queueStore_ ms) $ \db ->
      maybeFirstRow toMessage $
        DB.query
          db
          [sql|
            WITH peek AS (
              SELECT message_id, msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body
              FROM messages
              WHERE recipient_id = ?
              ORDER BY message_id ASC
              LIMIT 1
            )
            DELETE FROM messages
            WHERE message_id = (SELECT message_id FROM peek WHERE msg_id = ?)
            RETURNING msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body;
          |]
          (recipientId' q, Binary msgId)

  tryDelPeekMsg :: PostgresMsgStore -> PostgresQueue -> MsgId -> ExceptT ErrorType IO (Maybe Message, Maybe Message)
  tryDelPeekMsg ms q msgId =
    withDB' "tryDelPeekMsg" (queueStore_ ms) $ \db ->
      toResult . map toMessage
        <$> DB.query
          db
          [sql|
            WITH peek AS (
              SELECT
                row_number() OVER (ORDER BY message_id ASC) AS row_num,
                message_id, msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body
              FROM messages
              WHERE recipient_id = ?
              ORDER BY message_id ASC
              LIMIT 2
            ),
            deleted AS (
              DELETE FROM messages
              WHERE message_id = (SELECT message_id FROM peek WHERE row_num = 1 AND msg_id = ?)
              RETURNING msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body
            )
            SELECT msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body FROM deleted
            UNION ALL
            SELECT msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body
            FROM peek
            WHERE row_num = CASE WHEN EXISTS (SELECT 1 FROM deleted) THEN 2 ELSE 1 END;
          |]
          (recipientId' q, Binary msgId)
    where
      toResult = \case
        [] -> (Nothing, Nothing)
        [msg]
          | messageId msg == msgId -> (Just msg, Nothing)
          | otherwise -> (Nothing, Just msg)
        deleted : next : _ -> (Just deleted, Just next)

toMessage :: (Binary MsgId, Int64, Bool, Bool, Binary MsgBody) -> Message
toMessage (Binary msgId, ts, msgQuota, ntf, Binary body)
  | msgQuota = MessageQuota {msgId, msgTs}
  | otherwise = Message {msgId, msgTs, msgFlags = MsgFlags ntf, msgBody = C.unsafeMaxLenBS body} -- TODO [messages] unsafeMaxLenBS?
  where
    msgTs = MkSystemTime ts 0
