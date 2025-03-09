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
  ( addQueue,
    getQueue,
    getQueueRec,
    secureQueue,
    addQueueNotifier,
    deleteQueueNotifier,
    suspendQueue,
    blockQueue,
    unblockQueue,
    updateQueueTime,
    deleteQueue',
    newQueueStore,
    readQueueStore,
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
import Data.Functor (($>))
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.StoreLog
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (ifM, safeDecodeUtf8, tshow, ($>>=), (<$$))
import System.Exit (exitFailure)
import System.IO
import UnliftIO.STM

newQueueStore :: IO (STMQueueStore q)
newQueueStore = do
  queues <- TM.emptyIO
  senders <- TM.emptyIO
  notifiers <- TM.emptyIO
  storeLog <- newTVarIO Nothing
  pure STMQueueStore {queues, senders, notifiers, storeLog}

addQueue :: STMStoreClass s => s -> RecipientId -> QueueRec -> IO (Either ErrorType (StoreQueue s))
addQueue st rId qr@QueueRec {senderId = sId, notifier}=
  atomically add
    $>>= \q -> q <$$ withLog "addQueue" st (\s -> logCreateQueue s rId qr)
  where
    STMQueueStore {queues, senders, notifiers} = stmQueueStore st
    add = ifM hasId (pure $ Left DUPLICATE_) $ do
      q <- mkQueue st rId qr
      TM.insert rId q queues
      TM.insert sId rId senders
      forM_ notifier $ \NtfCreds {notifierId} -> TM.insert notifierId rId notifiers
      pure $ Right q
    hasId = or <$> sequence [TM.member rId queues, TM.member sId senders, hasNotifier]
    hasNotifier = maybe (pure False) (\NtfCreds {notifierId} -> TM.member notifierId notifiers) notifier

getQueue :: (STMStoreClass s, DirectParty p) => s -> SParty p -> QueueId -> IO (Either ErrorType (StoreQueue s))
getQueue st party qId =
  maybe (Left AUTH) Right <$> case party of
    SRecipient -> TM.lookupIO qId queues
    SSender -> TM.lookupIO qId senders $>>= (`TM.lookupIO` queues)
    SNotifier -> TM.lookupIO qId notifiers $>>= (`TM.lookupIO` queues)
  where
    STMQueueStore {queues, senders, notifiers} = stmQueueStore st

getQueueRec :: (STMStoreClass s, DirectParty p) => s -> SParty p -> QueueId -> IO (Either ErrorType (StoreQueue s, QueueRec))
getQueueRec st party qId =
  getQueue st party qId
    $>>= (\q -> maybe (Left AUTH) (Right . (q,)) <$> readTVarIO (queueRec' q))

secureQueue :: STMStoreClass s => s -> StoreQueue s -> SndPublicAuthKey -> IO (Either ErrorType ())
secureQueue st sq sKey =
  atomically (readQueueRec qr $>>= secure)
    $>>= \_ -> withLog "secureQueue" st $ \s -> logSecureQueue s (recipientId' sq) sKey
  where
    qr = queueRec' sq
    secure q = case senderKey q of
      Just k -> pure $ if sKey == k then Right () else Left AUTH
      Nothing -> do
        writeTVar qr $ Just q {senderKey = Just sKey}
        pure $ Right ()

addQueueNotifier :: STMStoreClass s => s -> StoreQueue s -> NtfCreds -> IO (Either ErrorType (Maybe NotifierId))
addQueueNotifier st sq ntfCreds@NtfCreds {notifierId = nId} =
  atomically (readQueueRec qr $>>= add)
    $>>= \nId_ -> nId_ <$$ withLog "addQueueNotifier" st (\s -> logAddNotifier s rId ntfCreds)
  where
    rId = recipientId' sq
    qr = queueRec' sq
    STMQueueStore {notifiers} = stmQueueStore st
    add q = ifM (TM.member nId notifiers) (pure $ Left DUPLICATE_) $ do
      nId_ <- forM (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId notifiers $> notifierId
      let !q' = q {notifier = Just ntfCreds}
      writeTVar qr $ Just q'
      TM.insert nId rId notifiers
      pure $ Right nId_

deleteQueueNotifier :: STMStoreClass s => s -> StoreQueue s -> IO (Either ErrorType (Maybe NotifierId))
deleteQueueNotifier st sq =
  atomically (readQueueRec qr >>= mapM delete)
    $>>= \nId_ -> nId_ <$$ withLog "deleteQueueNotifier" st (`logDeleteNotifier` recipientId' sq)
  where
    qr = queueRec' sq
    delete q = forM (notifier q) $ \NtfCreds {notifierId} -> do
      TM.delete notifierId $ notifiers $ stmQueueStore st
      writeTVar qr $! Just q {notifier = Nothing}
      pure notifierId

suspendQueue :: STMStoreClass s => s -> StoreQueue s -> IO (Either ErrorType ())
suspendQueue st sq =
  atomically (readQueueRec qr >>= mapM suspend)
    $>>= \_ -> withLog "suspendQueue" st (`logSuspendQueue` recipientId' sq)
  where
    qr = queueRec' sq
    suspend q = writeTVar qr $! Just q {status = EntityOff}

blockQueue :: STMStoreClass s => s -> StoreQueue s -> BlockingInfo -> IO (Either ErrorType ())
blockQueue st sq info =
  atomically (readQueueRec qr >>= mapM block)
    $>>= \_ -> withLog "blockQueue" st (\sl -> logBlockQueue sl (recipientId' sq) info)
  where
    qr = queueRec' sq
    block q = writeTVar qr $ Just q {status = EntityBlocked info}

unblockQueue :: STMStoreClass s => s -> StoreQueue s -> IO (Either ErrorType ())
unblockQueue st sq =
  atomically (readQueueRec qr >>= mapM unblock)
    $>>= \_ -> withLog "unblockQueue" st (`logUnblockQueue` recipientId' sq)
  where
    qr = queueRec' sq
    unblock q = writeTVar qr $ Just q {status = EntityActive}

updateQueueTime :: STMStoreClass s => s -> StoreQueue s -> RoundedSystemTime -> IO (Either ErrorType QueueRec)
updateQueueTime st sq t = atomically (readQueueRec qr >>= mapM update) $>>= log'
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

deleteQueue' :: STMStoreClass s => s -> StoreQueue s -> IO (Either ErrorType (QueueRec, Maybe (MsgQueue s)))
deleteQueue' st sq =
  atomically (readQueueRec qr >>= mapM delete)
    $>>= \q -> withLog "deleteQueue" st (`logDeleteQueue` recipientId' sq)
    >>= bimapM pure (\_ -> (q,) <$> atomically (swapTVar (msgQueue_' sq) Nothing))
  where
    qr = queueRec' sq
    STMQueueStore {senders, notifiers} = stmQueueStore st
    delete q = do
      writeTVar qr Nothing
      TM.delete (senderId q) senders
      forM_ (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId notifiers
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

withLog :: STMStoreClass s => String -> s -> (StoreLog 'WriteMode -> IO ()) -> IO (Either ErrorType ())
withLog name = withLog' name . storeLog . stmQueueStore

readQueueStore :: forall s. STMStoreClass s => FilePath -> s -> IO ()
readQueueStore f st = readLogLines False f processLine
  where
    processLine :: Bool -> B.ByteString -> IO ()
    processLine eof s = either printError procLogRecord (strDecode s)
      where
        procLogRecord :: StoreLogRecord -> IO ()
        procLogRecord = \case
          CreateQueue rId q -> addQueue st rId q >>= qError rId "CreateQueue"
          SecureQueue qId sKey -> withQueue qId "SecureQueue" $ \q -> secureQueue st q sKey
          AddNotifier qId ntfCreds -> withQueue qId "AddNotifier" $ \q -> addQueueNotifier st q ntfCreds
          SuspendQueue qId -> withQueue qId "SuspendQueue" $ suspendQueue st
          BlockQueue qId info -> withQueue qId "BlockQueue" $ \q -> blockQueue st q info
          UnblockQueue qId -> withQueue qId "UnblockQueue" $ unblockQueue st
          DeleteQueue qId -> withQueue qId "DeleteQueue" $ deleteQueue st
          DeleteNotifier qId -> withQueue qId "DeleteNotifier" $ deleteQueueNotifier st
          UpdateTime qId t -> withQueue qId "UpdateTime" $ \q -> updateQueueTime st q t
        printError :: String -> IO ()
        printError e
          | eof = logWarn err
          | otherwise = logError err >> exitFailure
          where
            err = "Error parsing log: " <> T.pack e <> " - " <> safeDecodeUtf8 s
        withQueue :: forall a. RecipientId -> T.Text -> (StoreQueue s -> IO (Either ErrorType a)) -> IO ()
        withQueue qId op a = runExceptT go >>= qError qId op
          where
            go = do
              q <- ExceptT $ getQueue st SRecipient qId
              liftIO (readTVarIO $ queueRec' q) >>= \case
                Nothing -> logWarn $ logPfx qId op <> "already deleted"
                Just _ -> void $ ExceptT $ a q
        qError qId op = \case
          Left e -> logError $ logPfx qId op <> tshow e
          Right _ -> pure ()
        logPfx qId op = "STORE: " <> op <> ", stored queue " <> decodeLatin1 (strEncode qId) <> ", "
