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
    exportDbMessages,
    getDbMessageStats,
    batchInsertMessages,
  )
where

import Control.Concurrent.STM
import Control.Monad
import Control.Monad.Reader
import Control.Monad.Trans.Except
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as LB
import Data.IORef
import Data.Int (Int64)
import Data.List (intersperse)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import Data.Time.Clock.System (SystemTime (..))
import Database.PostgreSQL.Simple (Binary (..), Only (..), (:.) (..))
import qualified Database.PostgreSQL.Simple as DB
import qualified Database.PostgreSQL.Simple.Copy as DB
import Database.PostgreSQL.Simple.SqlQQ (sql)
import Database.PostgreSQL.Simple.ToField (ToField (..))
import Simplex.Messaging.Agent.Store.Postgres.Common
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.MsgStore
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.Postgres
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Util (maybeFirstRow, maybeFirstRow', (<$$>))
import System.IO (Handle, hFlush, stdout)

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

instance StoreQueueClass PostgresQueue where
  recipientId = recipientId'
  {-# INLINE recipientId #-}
  queueRec = queueRec'
  {-# INLINE queueRec #-}
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

  withActiveMsgQueues _ _ = error "withActiveMsgQueues not used"

  unsafeWithAllMsgQueues _ _ _ = error "unsafeWithAllMsgQueues not used"

  expireOldMessages :: Bool -> PostgresMsgStore -> Int64 -> Int64 -> IO MessageStats
  expireOldMessages _tty ms now ttl =
    maybeFirstRow' newMessageStats toMessageStats $ withConnection st $ \db ->
      DB.query db "CALL expire_old_messages(?,?,0,0,0)" (now, ttl)
    where
      st = dbStore $ queueStore_ ms
      toMessageStats (expiredMsgsCount, storedMsgsCount, storedQueues) =
        MessageStats {expiredMsgsCount, storedMsgsCount, storedQueues}

  logQueueStates _ = error "logQueueStates not used"

  logQueueState _ = error "logQueueState not used"

  queueStore = queueStore_
  {-# INLINE queueStore #-}

  loadedQueueCounts :: PostgresMsgStore -> IO LoadedQueueCounts
  loadedQueueCounts ms = do
    loadedQueueCount <- M.size <$> readTVarIO queues
    loadedNotifierCount <- M.size <$> readTVarIO notifiers
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
  withIdleMsgQueue _ _ _ _ = error "withIdleMsgQueue not used"

  deleteQueue :: PostgresMsgStore -> PostgresQueue -> IO (Either ErrorType QueueRec)
  deleteQueue ms q = deleteStoreQueue (queueStore_ ms) q
  {-# INLINE deleteQueue #-}

  deleteQueueSize :: PostgresMsgStore -> PostgresQueue -> IO (Either ErrorType (QueueRec, Int))
  deleteQueueSize ms q = runExceptT $ do
    size <- getQueueSize ms q
    qr <- ExceptT $ deleteStoreQueue (queueStore_ ms) q
    pure (qr, size)

  getQueueMessages_ _ _ _ = error "getQueueMessages_ not used"

  writeMsg :: PostgresMsgStore -> PostgresQueue -> Bool -> Message -> ExceptT ErrorType IO (Maybe (Message, Bool))
  writeMsg ms q _ msg =
    withDB' "writeMsg" (queueStore_ ms) $ \db -> do
      let (msgQuota, ntf, body) = case msg of
            Message {msgFlags = MsgFlags ntf', msgBody = C.MaxLenBS body'} -> (False, ntf', body')
            MessageQuota {} -> (True, False, B.empty)
      toResult <$>
        DB.query
          db
          "SELECT quota_written, was_empty FROM write_message(?,?,?,?,?,?,?)"
          (recipientId' q, Binary (messageId msg), systemSeconds (messageTs msg), msgQuota, ntf, Binary body, quota)
    where
      toResult = \case
        ((msgQuota, wasEmpty) : _) -> if msgQuota then Nothing else Just (msg, wasEmpty)
        [] -> Nothing
      PostgresMsgStore {config = PostgresMsgStoreCfg {quota}} = ms

  setOverQuota_ :: PostgresQueue -> IO () -- can ONLY be used while restoring messages, not while server running
  setOverQuota_ _ = error "TODO setOverQuota_"

  getQueueSize_ :: () -> DBStoreIO Int
  getQueueSize_ _ = error "getQueueSize_ not used"

  getQueueSize :: PostgresMsgStore -> PostgresQueue -> ExceptT ErrorType IO Int
  getQueueSize ms q =
    withDB' "getQueueSize" (queueStore_ ms) $ \db ->
      maybeFirstRow' 0 fromOnly $
        DB.query db "SELECT msg_queue_size FROM msg_queues WHERE recipient_id = ? AND deleted_at IS NULL" (Only (recipientId' q))

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
  tryDeleteMsg_ _q _ _ = error "tryDeleteMsg_ not used" -- do
    -- db <- asks dbConn
    -- liftIO $ void $
    --   DB.execute
    --     db
    --     -- "DELETE FROM messages WHERE recipient_id = ? ORDER BY message_id ASC LIMIT 1"
    --     "DELETE FROM messages WHERE message_id = (SELECT MIN(message_id) FROM messages WHERE recipient_id = ?)"
    --     (Only (recipientId' q))

  isolateQueue :: PostgresMsgStore -> PostgresQueue -> Text -> DBStoreIO a -> ExceptT ErrorType IO a
  isolateQueue ms _q op a = withDB' op (queueStore_ ms) $ runReaderT a . DBTransaction

  unsafeRunStore _ _ _ = error "unsafeRunStore not used"

  tryPeekMsg :: PostgresMsgStore -> PostgresQueue -> ExceptT ErrorType IO (Maybe Message)
  tryPeekMsg ms q = isolateQueue ms q "tryPeekMsg" $ tryPeekMsg_ q ()
  {-# INLINE tryPeekMsg #-}

  tryDelMsg :: PostgresMsgStore -> PostgresQueue -> MsgId -> ExceptT ErrorType IO (Maybe Message)
  tryDelMsg ms q msgId =
    withDB' "tryDelMsg" (queueStore_ ms) $ \db ->
      maybeFirstRow toMessage $
        DB.query db "SELECT r_msg_id, r_msg_ts, r_msg_quota, r_msg_ntf_flag, r_msg_body FROM try_del_msg(?, ?)" (recipientId' q, Binary msgId)

  tryDelPeekMsg :: PostgresMsgStore -> PostgresQueue -> MsgId -> ExceptT ErrorType IO (Maybe Message, Maybe Message)
  tryDelPeekMsg ms q msgId =
    withDB' "tryDelPeekMsg" (queueStore_ ms) $ \db ->
      toResult . map toMessage
        <$> DB.query db "SELECT r_msg_id, r_msg_ts, r_msg_quota, r_msg_ntf_flag, r_msg_body FROM try_del_peek_msg(?, ?)" (recipientId' q, Binary msgId)
    where
      toResult = \case
        [] -> (Nothing, Nothing)
        [msg]
          | messageId msg == msgId -> (Just msg, Nothing)
          | otherwise -> (Nothing, Just msg)
        deleted : next : _ -> (Just deleted, Just next)

  deleteExpiredMsgs :: PostgresMsgStore -> PostgresQueue -> Int64 -> ExceptT ErrorType IO Int
  deleteExpiredMsgs ms q old =
    maybeFirstRow' 0 (fromIntegral @Int64 . fromOnly) $ withDB' "deleteExpiredMsgs" (queueStore_ ms) $ \db ->
      DB.query db "SELECT delete_expired_msgs(?, ?)" (recipientId' q, old)

toMessage :: (Binary MsgId, Int64, Bool, Bool, Binary MsgBody) -> Message
toMessage (Binary msgId, ts, msgQuota, ntf, Binary body)
  | msgQuota = MessageQuota {msgId, msgTs}
  | otherwise = Message {msgId, msgTs, msgFlags = MsgFlags ntf, msgBody = C.unsafeMaxLenBS body} -- TODO [messages] unsafeMaxLenBS?
  where
    msgTs = MkSystemTime ts 0

exportDbMessages :: Bool -> PostgresMsgStore -> Handle -> IO Int
exportDbMessages tty ms h = do
  rows <- newIORef []
  n <- withConnection st $ \db -> DB.foldWithOptions_ opts db query 0 $ \i r -> do
    let i' = i + 1
    if i' `mod` 1000 > 0
      then modifyIORef rows (r :)
      else do
        readIORef rows >>= writeMessages
        when tty $ putStr (progress i' <> "\r") >> hFlush stdout
    pure i'
  readIORef rows >>= \rs -> unless (null rs) $ writeMessages rs
  when tty $ putStrLn $ progress n
  pure n
  where
    st = dbStore $ queueStore_ ms
    opts = DB.defaultFoldOptions {DB.fetchQuantity = DB.Fixed 1000}
    query =
      [sql|
        SELECT recipient_id, msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body
        FROM messages
        ORDER BY recipient_id, message_id ASC
      |]
    writeMessages = BB.hPutBuilder h . encodeMessages . reverse
    encodeMessages = mconcat . map (\(Only rId :. msg) -> BB.byteString (strEncode $ MLRv3 rId $ toMessage msg) <> BB.char8 '\n')
    progress i = "Processed: " <> show i <> " records"

getDbMessageStats :: PostgresMsgStore -> IO MessageStats
getDbMessageStats ms =
  maybeFirstRow' newMessageStats toMessageStats $ withConnection st $ \db ->
    DB.query_
      db
      [sql|
        SELECT
          (SELECT COUNT (1) FROM msg_queues WHERE deleted_at IS NULL),
          (SELECT COUNT (1) FROM messages m JOIN msg_queues q USING recipient_id WHERE deleted_at IS NULL)
      |]
  where
    st = dbStore $ queueStore_ ms
    toMessageStats (storedQueues, storedMsgsCount) =
      MessageStats {storedQueues, storedMsgsCount, expiredMsgsCount = 0}

batchInsertMessages :: StoreQueueClass q => Bool -> [Either String (RecipientId, Message)] -> PostgresQueueStore q -> IO Int64
batchInsertMessages tty msgs toStore = do
  putStrLn "Importing messages..."
  let st = dbStore toStore
  count <-
    withTransaction st $ \db -> do
      DB.copy_
        db
        [sql|
          COPY messages (recipient_id, msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body)
          FROM STDIN WITH (FORMAT CSV)
        |]
      mapM_ (putMessage db) (zip [1..] msgs)
      DB.putCopyEnd db
  Only mCnt : _ <- withTransaction st (`DB.query_` "SELECT count(*) FROM messages")
  putStrLn $ progress count
  pure mCnt
  where
    putMessage db (i :: Int, msg_) = do
      case msg_ of
        Right msg -> DB.putCopyData db $ messageRecToText msg
        Left e -> putStrLn $ "Error parsing line " <> show i <> ": " <> e
      when (tty && i `mod` 10000 == 0) $ putStr (progress i <> "\r") >> hFlush stdout
    progress i = "Imported: " <> show i <> " messages"

messageRecToText :: (RecipientId, Message) -> B.ByteString
messageRecToText (rId, msg) =
  LB.toStrict $ BB.toLazyByteString $ mconcat tabFields <> BB.char7 '\n'
  where
    tabFields = BB.char7 ',' `intersperse` fields
    fields =
      [ renderField (toField rId),
        renderField (toField $ Binary (messageId msg)),
        renderField (toField $ systemSeconds (messageTs msg)),
        renderField (toField msgQuota),
        renderField (toField ntf),
        renderField (toField $ Binary body)
      ]
    (msgQuota, ntf, body) = case msg of
      Message {msgFlags = MsgFlags ntf', msgBody = C.MaxLenBS body'} -> (False, ntf', body')
      MessageQuota {} -> (True, False, B.empty)
