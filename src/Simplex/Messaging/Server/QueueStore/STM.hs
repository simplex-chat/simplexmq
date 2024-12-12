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
  ( addQueue',
    getQueue',
    getQueueRec',
    secureQueue',
    addQueueNotifier',
    deleteQueueNotifier',
    suspendQueue',
    updateQueueTime',
    deleteQueue',
    readQueueStore,
    withLog',
  )
where

import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import Data.Bitraversable (bimapM)
import Data.Functor (($>))
import qualified Data.Text as T
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.StoreLog
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (ifM, ($>>=), (<$$))
import System.IO
import UnliftIO.STM

addQueue' :: STMQueueStore s => s -> QueueRec -> IO (Either ErrorType (StoreQueue s))
addQueue' st qr@QueueRec {recipientId = rId, senderId = sId, notifier} =
  (mkQueue st qr >>= atomically . add)
    $>>= \q -> q <$$ withLog "addQueue" st (`logCreateQueue` qr)
  where
    add q = ifM hasId (pure $ Left DUPLICATE_) $ do
      TM.insert rId q $ queues' st
      TM.insert sId rId $ senders' st
      forM_ notifier $ \NtfCreds {notifierId} -> TM.insert notifierId rId $ notifiers' st
      pure $ Right q
    hasId = foldM (fmap . (||)) False [TM.member rId $ queues' st, TM.member sId $ senders' st, hasNotifier]
    hasNotifier = maybe (pure False) (\NtfCreds {notifierId} -> TM.member notifierId (notifiers' st)) notifier

getQueue' :: (STMQueueStore s, DirectParty p) => s -> SParty p -> QueueId -> IO (Either ErrorType (StoreQueue s))
getQueue' st party qId =
  maybe (Left AUTH) Right <$> case party of
    SRecipient -> TM.lookupIO qId $ queues' st
    SSender -> TM.lookupIO qId (senders' st) $>>= (`TM.lookupIO` queues' st)
    SNotifier -> TM.lookupIO qId (notifiers' st) $>>= (`TM.lookupIO` queues' st)

getQueueRec' :: (STMQueueStore s, DirectParty p) => s -> SParty p -> QueueId -> IO (Either ErrorType (StoreQueue s, QueueRec))
getQueueRec' st party qId =
  getQueue st party qId
    $>>= (\q -> maybe (Left AUTH) (Right . (q,)) <$> readTVarIO (queueRec' q))

secureQueue' :: STMQueueStore s => s -> StoreQueue s -> SndPublicAuthKey -> IO (Either ErrorType ())
secureQueue' st sq sKey =
  atomically (readQueueRec qr $>>= secure)
    $>>= \rId -> withLog "secureQueue" st $ \s -> logSecureQueue s rId sKey
  where
    qr = queueRec' sq
    secure q@QueueRec {recipientId = rId} = case senderKey q of
      Just k -> pure $ if sKey == k then Right rId else Left AUTH
      Nothing -> do
        writeTVar qr $ Just q {senderKey = Just sKey}
        pure $ Right rId

addQueueNotifier' :: STMQueueStore s => s -> StoreQueue s -> NtfCreds -> IO (Either ErrorType (Maybe NotifierId))
addQueueNotifier' st sq ntfCreds@NtfCreds {notifierId = nId} =
  atomically (readQueueRec qr $>>= add)
    $>>= \(rId, nId_) -> nId_ <$$ withLog "addQueueNotifier" st (\s -> logAddNotifier s rId ntfCreds)
  where
    qr = queueRec' sq
    add q@QueueRec {recipientId = rId} = ifM (TM.member nId (notifiers' st)) (pure $ Left DUPLICATE_) $ do
      nId_ <- forM (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId (notifiers' st) $> notifierId
      let !q' = q {notifier = Just ntfCreds}
      writeTVar qr $ Just q'
      TM.insert nId rId $ notifiers' st
      pure $ Right (rId, nId_)

deleteQueueNotifier' :: STMQueueStore s => s -> StoreQueue s -> IO (Either ErrorType (Maybe NotifierId))
deleteQueueNotifier' st sq =
  atomically (readQueueRec qr >>= mapM delete)
    $>>= \(rId, nId_) -> nId_ <$$ withLog "deleteQueueNotifier" st (`logDeleteNotifier` rId)
  where
    qr = queueRec' sq
    delete q = fmap (recipientId q,) $ forM (notifier q) $ \NtfCreds {notifierId} -> do
      TM.delete notifierId $ notifiers' st
      writeTVar qr $! Just q {notifier = Nothing}
      pure notifierId

suspendQueue' :: STMQueueStore s => s -> StoreQueue s -> IO (Either ErrorType ())
suspendQueue' st sq =
  atomically (readQueueRec qr >>= mapM suspend)
    $>>= \rId -> withLog "suspendQueue" st (`logSuspendQueue` rId)
  where
    qr = queueRec' sq
    suspend q = do
      writeTVar qr $! Just q {status = QueueOff}
      pure $ recipientId q

updateQueueTime' :: STMQueueStore s => s -> StoreQueue s -> RoundedSystemTime -> IO (Either ErrorType QueueRec)
updateQueueTime' st sq t = atomically (readQueueRec qr >>= mapM update) $>>= log'
  where
    qr = queueRec' sq
    update q@QueueRec {updatedAt}
      | updatedAt == Just t = pure (q, False)
      | otherwise =
          let !q' = q {updatedAt = Just t}
           in (writeTVar qr $! Just q') $> (q', True)
    log' (q, changed)
      | changed = q <$$ withLog "updateQueueTime" st (\sl -> logUpdateQueueTime sl (recipientId q) t)
      | otherwise = pure $ Right q

deleteQueue' :: STMQueueStore s => s -> RecipientId -> StoreQueue s -> IO (Either ErrorType (QueueRec, Maybe (MsgQueue s)))
deleteQueue' st rId sq =
  atomically (readQueueRec qr >>= mapM delete)
    $>>= \q -> withLog "deleteQueue" st (`logDeleteQueue` rId)
    >>= bimapM pure (\_ -> (q,) <$> atomically (swapTVar (msgQueue_' sq) Nothing))
  where
    qr = queueRec' sq
    delete q = do
      writeTVar qr Nothing
      TM.delete (senderId q) $ senders' st
      forM_ (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId $ notifiers' st
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

withLog :: STMQueueStore s => String -> s -> (StoreLog 'WriteMode -> IO ()) -> IO (Either ErrorType ())
withLog name = withLog' name . storeLog'
