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
    secureQueue',
    addQueueNotifier',
    deleteQueueNotifier',
    suspendQueue',
    updateQueueTime',
    deleteQueue',
    readQueueStore,
    readQueueRec,
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
import Simplex.Messaging.Util (anyM, ifM, ($>>=), (<$$))
import System.IO
import UnliftIO.STM

addQueue' :: STMQueueStore s => s -> RecipientId -> QueueRec -> IO (Either ErrorType (StoreQueue s))
addQueue' st rId qr@QueueRec {senderId = sId, notifier} =
  (mkQueue st rId qr >>= atomically . add)
    $>>= \q -> q <$$ withLog "addQueue" st (\s -> logCreateQueue s rId qr)
  where
    add q = ifM hasId (pure $ Left DUPLICATE_) $ do
      TM.insert rId q $ queues' st
      TM.insert sId rId $ senders' st
      forM_ notifier $ \NtfCreds {notifierId} -> TM.insert notifierId rId $ notifiers' st
      pure $ Right q
    hasId = anyM [TM.member rId $ queues' st, TM.member sId $ senders' st, hasNotifier]
    hasNotifier = maybe (pure False) (\NtfCreds {notifierId} -> TM.member notifierId (notifiers' st)) notifier

getQueue' :: (STMQueueStore s, DirectParty p) => s -> SParty p -> QueueId -> IO (Either ErrorType (StoreQueue s))
getQueue' st party qId =
  maybe (Left AUTH) Right <$> case party of
    SRecipient -> TM.lookupIO qId $ queues' st
    SSender -> TM.lookupIO qId (senders' st) $>>= (`TM.lookupIO` queues' st)
    SNotifier -> TM.lookupIO qId (notifiers' st) $>>= (`TM.lookupIO` queues' st)

secureQueue' :: STMQueueStore s => s -> StoreQueue s -> SndPublicAuthKey -> IO (Either ErrorType ())
secureQueue' st sq sKey =
  atomically (readQueueRec qr $>>= secure)
    $>>= \_ -> withLog "secureQueue" st $ \s -> logSecureQueue s (recipientId' sq) sKey
  where
    qr = queueRec' sq
    secure q = case senderKey q of
      Just k -> pure $ if sKey == k then Right () else Left AUTH
      Nothing -> do
        writeTVar qr $ Just q {senderKey = Just sKey}
        pure $ Right ()

addQueueNotifier' :: STMQueueStore s => s -> StoreQueue s -> NtfCreds -> IO (Either ErrorType (Maybe NotifierId))
addQueueNotifier' st sq ntfCreds@NtfCreds {notifierId = nId} =
  atomically (readQueueRec qr $>>= add)
    $>>= \nId_ -> nId_ <$$ withLog "addQueueNotifier" st (\s -> logAddNotifier s rId ntfCreds)
  where
    qr = queueRec' sq
    rId = recipientId' sq
    add q = ifM (TM.member nId (notifiers' st)) (pure $ Left DUPLICATE_) $ do
      nId_ <- forM (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId (notifiers' st) $> notifierId
      let !q' = q {notifier = Just ntfCreds}
      writeTVar qr $ Just q'
      TM.insert nId rId $ notifiers' st
      pure $ Right nId_

deleteQueueNotifier' :: STMQueueStore s => s -> StoreQueue s -> IO (Either ErrorType (Maybe NotifierId))
deleteQueueNotifier' st sq =
  atomically (readQueueRec qr >>= mapM delete)
    $>>= \nId_ -> nId_ <$$ withLog "deleteQueueNotifier" st (`logDeleteNotifier` recipientId' sq)
  where
    qr = queueRec' sq
    delete q = forM (notifier q) $ \NtfCreds {notifierId} -> do
      TM.delete notifierId $ notifiers' st
      writeTVar qr $! Just q {notifier = Nothing}
      pure notifierId

suspendQueue' :: STMQueueStore s => s -> StoreQueue s -> IO (Either ErrorType ())
suspendQueue' st sq =
  atomically (readQueueRec qr >>= mapM suspend)
    $>>= \_ -> withLog "suspendQueue" st (`logSuspendQueue` recipientId' sq)
  where
    qr = queueRec' sq
    suspend q = writeTVar qr $! Just q {status = QueueOff}

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
      | changed = q <$$ withLog "updateQueueTime" st (\sl -> logUpdateQueueTime sl (recipientId' sq) t)
      | otherwise = pure $ Right q

deleteQueue' :: STMQueueStore s => s -> StoreQueue s -> IO (Either ErrorType (QueueRec, Maybe (MsgQueue s)))
deleteQueue' st sq =
  atomically (readQueueRec qr >>= mapM delete)
    $>>= \q -> withLog "deleteQueue" st (`logDeleteQueue` recipientId' sq)
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
