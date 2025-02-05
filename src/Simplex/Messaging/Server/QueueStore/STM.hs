{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UndecidableInstances #-}

module Simplex.Messaging.Server.QueueStore.STM
  ( stmQueueCounts,
    stmAddQueue,
    stmGetQueue,
    stmSecureQueue,
    stmAddQueueNotifier,
    stmDeleteQueueNotifier,
    stmSuspendQueue,
    stmBlockQueue,
    stmUnblockQueue,
    stmUpdateQueueTime,
    stmDeleteQueue,
    newSTMQueueStore,
    readSTMQueueStore,
    withQueues,
    withLog',
  )
where

import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Data.Bitraversable (bimapM)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Functor (($>))
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.StoreLog
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (anyM, ifM, tshow, ($>>=), (<$$))
import System.IO
import UnliftIO.STM

newSTMQueueStore :: IO (STMQueueStore q)
newSTMQueueStore = do
  queues <- TM.emptyIO
  senders <- TM.emptyIO
  notifiers <- TM.emptyIO
  storeLog <- newTVarIO Nothing
  pure STMQueueStore {queues, senders, notifiers, storeLog}

withQueues :: Monoid a => STMQueueStore (StoreQueue s) -> (StoreQueue s -> IO a) -> IO a
withQueues st f = readTVarIO (queues st) >>= foldM run mempty
  where
    run !acc = fmap (acc <>) . f

stmQueueCounts :: STMQueueStore q -> IO QueueCounts
stmQueueCounts st = do
  queueCount <- M.size <$> readTVarIO (queues st)
  notifierCount <- M.size <$> readTVarIO (notifiers st)
  pure QueueCounts {queueCount, notifierCount}

stmAddQueue :: STMStoreClass s => s -> RecipientId -> QueueRec -> IO (Either ErrorType (StoreQueue s))
stmAddQueue ms rId qr@QueueRec {senderId = sId, notifier}=
  (mkQueue ms rId qr >>= atomically . add)
    $>>= \q -> q <$$ withLog "addQueue" st (\s -> logCreateQueue s rId qr)
  where
    st@STMQueueStore {queues, senders, notifiers} = stmQueueStore ms
    add q = ifM hasId (pure $ Left DUPLICATE_) $ do
      TM.insert rId q queues
      TM.insert sId rId senders
      forM_ notifier $ \NtfCreds {notifierId} -> TM.insert notifierId rId notifiers
      pure $ Right q
    hasId = anyM [TM.member rId queues, TM.member sId senders, hasNotifier]
    hasNotifier = maybe (pure False) (\NtfCreds {notifierId} -> TM.member notifierId notifiers) notifier

stmGetQueue :: DirectParty p => STMQueueStore q -> SParty p -> QueueId -> IO (Either ErrorType q)
stmGetQueue st party qId =
  maybe (Left AUTH) Right <$> case party of
    SRecipient -> TM.lookupIO qId queues
    SSender -> TM.lookupIO qId senders $>>= (`TM.lookupIO` queues)
    SNotifier -> TM.lookupIO qId notifiers $>>= (`TM.lookupIO` queues)
  where
    STMQueueStore {queues, senders, notifiers} = st

stmSecureQueue :: MsgStoreClass s => STMQueueStore (StoreQueue s) -> StoreQueue s -> SndPublicAuthKey -> IO (Either ErrorType ())
stmSecureQueue st sq sKey =
  atomically (readQueueRec qr $>>= secure)
    $>>= \_ -> withLog "secureQueue" st $ \s -> logSecureQueue s (recipientId' sq) sKey
  where
    qr = queueRec' sq
    secure q = case senderKey q of
      Just k -> pure $ if sKey == k then Right () else Left AUTH
      Nothing -> do
        writeTVar qr $ Just q {senderKey = Just sKey}
        pure $ Right ()

stmAddQueueNotifier :: MsgStoreClass s => STMQueueStore (StoreQueue s) -> StoreQueue s -> NtfCreds -> IO (Either ErrorType (Maybe NotifierId))
stmAddQueueNotifier st sq ntfCreds@NtfCreds {notifierId = nId} =
  atomically (readQueueRec qr $>>= add)
    $>>= \nId_ -> nId_ <$$ withLog "addQueueNotifier" st (\s -> logAddNotifier s rId ntfCreds)
  where
    rId = recipientId' sq
    qr = queueRec' sq
    STMQueueStore {notifiers} = st
    add q = ifM (TM.member nId notifiers) (pure $ Left DUPLICATE_) $ do
      nId_ <- forM (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId notifiers $> notifierId
      let !q' = q {notifier = Just ntfCreds}
      writeTVar qr $ Just q'
      TM.insert nId rId notifiers
      pure $ Right nId_

stmDeleteQueueNotifier :: MsgStoreClass s => STMQueueStore (StoreQueue s) -> StoreQueue s -> IO (Either ErrorType (Maybe NotifierId))
stmDeleteQueueNotifier st sq =
  atomically (readQueueRec qr >>= mapM delete)
    $>>= \nId_ -> nId_ <$$ withLog "deleteQueueNotifier" st (`logDeleteNotifier` recipientId' sq)
  where
    qr = queueRec' sq
    delete q = forM (notifier q) $ \NtfCreds {notifierId} -> do
      TM.delete notifierId $ notifiers st
      writeTVar qr $! Just q {notifier = Nothing}
      pure notifierId

stmSuspendQueue :: MsgStoreClass s => STMQueueStore (StoreQueue s) -> StoreQueue s -> IO (Either ErrorType ())
stmSuspendQueue st sq =
  atomically (readQueueRec qr >>= mapM suspend)
    $>>= \_ -> withLog "suspendQueue" st (`logSuspendQueue` recipientId' sq)
  where
    qr = queueRec' sq
    suspend q = writeTVar qr $! Just q {status = EntityOff}

stmBlockQueue :: MsgStoreClass s => STMQueueStore (StoreQueue s) -> StoreQueue s -> BlockingInfo -> IO (Either ErrorType ())
stmBlockQueue st sq info =
  atomically (readQueueRec qr >>= mapM block)
    $>>= \_ -> withLog "blockQueue" st (\sl -> logBlockQueue sl (recipientId' sq) info)
  where
    qr = queueRec' sq
    block q = writeTVar qr $ Just q {status = EntityBlocked info}

stmUnblockQueue :: MsgStoreClass s => STMQueueStore (StoreQueue s) -> StoreQueue s -> IO (Either ErrorType ())
stmUnblockQueue st sq =
  atomically (readQueueRec qr >>= mapM unblock)
    $>>= \_ -> withLog "unblockQueue" st (`logUnblockQueue` recipientId' sq)
  where
    qr = queueRec' sq
    unblock q = writeTVar qr $ Just q {status = EntityActive}

stmUpdateQueueTime :: MsgStoreClass s => STMQueueStore (StoreQueue s) -> StoreQueue s -> RoundedSystemTime -> IO (Either ErrorType QueueRec)
stmUpdateQueueTime st sq t = atomically (readQueueRec qr >>= mapM update) $>>= log'
  where
    qr = queueRec' sq
    update q@QueueRec {updatedAt}
      | updatedAt == Just t = pure (q, False)
      | otherwise =
          let !q' = q {updatedAt = Just t}
           in (writeTVar qr $! Just q') $> (q', True)
    log' (q, changed)
      | changed = q <$$ withLog "updateQueueTime" st (\sl -> logUpdateQueueTime sl (recipientId' sq) t)
      | otherwise = pure $ Right q

stmDeleteQueue :: MsgStoreClass s => STMQueueStore (StoreQueue s) -> StoreQueue s -> IO (Either ErrorType (QueueRec, Maybe (MsgQueue s)))
stmDeleteQueue st sq =
  atomically (readQueueRec qr >>= mapM delete)
    $>>= \q -> withLog "deleteQueue" st (`logDeleteQueue` recipientId' sq)
    >>= bimapM pure (\_ -> (q,) <$> atomically (swapTVar (msgQueue_' sq) Nothing))
  where
    qr = queueRec' sq
    delete q = do
      writeTVar qr Nothing
      TM.delete (senderId q) $ senders st
      forM_ (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId $ notifiers st
      pure q

readQueueRec :: TVar (Maybe QueueRec) -> STM (Either ErrorType QueueRec)
readQueueRec qr = maybe (Left AUTH) Right <$> readTVar qr
{-# INLINE readQueueRec #-}

withLog' :: String -> TVar (Maybe (StoreLog 'WriteMode)) -> (StoreLog 'WriteMode -> IO ()) -> IO (Either ErrorType ())
withLog' name sl action =
  readTVarIO sl
    >>= maybe (pure $ Right ()) (E.try . action >=> bimapM logErr pure)
  where
    logErr :: E.SomeException -> IO ErrorType
    logErr e = logError ("STORE: " <> T.pack err) $> STORE err
      where
        err = name <> ", withLog, " <> show e

withLog :: String -> STMQueueStore q -> (StoreLog 'WriteMode -> IO ()) -> IO (Either ErrorType ())
withLog name = withLog' name . storeLog

readSTMQueueStore :: forall s. STMStoreClass s => FilePath -> s -> IO ()
readSTMQueueStore f ms = withFile f ReadMode $ LB.hGetContents >=> mapM_ processLine . LB.lines
  where
    st = stmQueueStore ms
    processLine :: LB.ByteString -> IO ()
    processLine s' = either printError procLogRecord (strDecode s)
      where
        s = LB.toStrict s'
        procLogRecord :: StoreLogRecord -> IO ()
        procLogRecord = \case
          CreateQueue rId q -> stmAddQueue ms rId q >>= qError rId "CreateQueue"
          SecureQueue qId sKey -> withQueue qId "SecureQueue" $ \q -> stmSecureQueue st q sKey
          AddNotifier qId ntfCreds -> withQueue qId "AddNotifier" $ \q -> stmAddQueueNotifier st q ntfCreds
          SuspendQueue qId -> withQueue qId "SuspendQueue" $ stmSuspendQueue st
          BlockQueue qId info -> withQueue qId "BlockQueue" $ \q -> stmBlockQueue st q info
          UnblockQueue qId -> withQueue qId "UnblockQueue" $ stmUnblockQueue st
          DeleteQueue qId -> withQueue qId "DeleteQueue" $ stmDeleteQueue st
          DeleteNotifier qId -> withQueue qId "DeleteNotifier" $ stmDeleteQueueNotifier st
          UpdateTime qId t -> withQueue qId "UpdateTime" $ \q -> stmUpdateQueueTime st q t
        printError :: String -> IO ()
        printError e = B.putStrLn $ "Error parsing log: " <> B.pack e <> " - " <> s
        withQueue :: forall a. RecipientId -> T.Text -> (StoreQueue s -> IO (Either ErrorType a)) -> IO ()
        withQueue qId op a = runExceptT go >>= qError qId op
          where
            go = do
              q <- ExceptT $ stmGetQueue st SRecipient qId
              liftIO (readTVarIO $ queueRec' q) >>= \case
                Nothing -> logWarn $ logPfx qId op <> "already deleted"
                Just _ -> void $ ExceptT $ a q
        qError qId op = \case
          Left e -> logError $ logPfx qId op <> tshow e
          Right _ -> pure ()
        logPfx qId op = "STORE: " <> op <> ", stored queue " <> decodeLatin1 (strEncode qId) <> ", "
