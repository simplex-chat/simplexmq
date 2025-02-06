{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
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
  ( STMQueueStore (..),
    newSTMQueueStore,
    withQueues,
    withLog',
  )
where

import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import Data.Bitraversable (bimapM)
import Data.Functor (($>))
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Simplex.Messaging.Protocol
-- import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (anyM, ifM, ($>>=), (<$$))
import System.IO
import UnliftIO.STM

data STMQueueStore q = STMQueueStore
  { queues :: TMap RecipientId q,
    senders :: TMap SenderId RecipientId,
    notifiers :: TMap NotifierId RecipientId,
    storeLog :: TVar (Maybe (StoreLog 'WriteMode))
  }

newSTMQueueStore :: IO (STMQueueStore q)
newSTMQueueStore = do
  queues <- TM.emptyIO
  senders <- TM.emptyIO
  notifiers <- TM.emptyIO
  storeLog <- newTVarIO Nothing
  pure STMQueueStore {queues, senders, notifiers, storeLog}

withQueues :: Monoid a => STMQueueStore q -> (q -> IO a) -> IO a
withQueues st f = readTVarIO (queues st) >>= foldM run mempty
  where
    run !acc = fmap (acc <>) . f

instance StoreQueueClass q => QueueStoreClass q (STMQueueStore q) where
  queueCounts :: STMQueueStore q -> IO QueueCounts
  queueCounts st = do
    queueCount <- M.size <$> readTVarIO (queues st)
    notifierCount <- M.size <$> readTVarIO (notifiers st)
    pure QueueCounts {queueCount, notifierCount}

  addStoreQueue :: STMQueueStore q -> QueueRec -> q -> IO (Either ErrorType ())
  addStoreQueue st qr@QueueRec {senderId = sId, notifier} sq =
    add $>>= \_ -> withLog "addStoreQueue" st (\s -> logCreateQueue s rId qr)
    where
      STMQueueStore {queues, senders, notifiers} = st
      rId = recipientId sq
      add = atomically $ ifM hasId (pure $ Left DUPLICATE_) $ do
        TM.insert rId sq queues
        TM.insert sId rId senders
        forM_ notifier $ \NtfCreds {notifierId} -> TM.insert notifierId rId notifiers
        pure $ Right ()
      hasId = anyM [TM.member rId queues, TM.member sId senders, hasNotifier]
      hasNotifier = maybe (pure False) (\NtfCreds {notifierId} -> TM.member notifierId notifiers) notifier

  getQueue :: DirectParty p => STMQueueStore q -> SParty p -> QueueId -> IO (Either ErrorType q)
  getQueue st party qId =
    maybe (Left AUTH) Right <$> case party of
      SRecipient -> TM.lookupIO qId queues
      SSender -> TM.lookupIO qId senders $>>= (`TM.lookupIO` queues)
      SNotifier -> TM.lookupIO qId notifiers $>>= (`TM.lookupIO` queues)
    where
      STMQueueStore {queues, senders, notifiers} = st

  secureQueue :: STMQueueStore q -> q -> SndPublicAuthKey -> IO (Either ErrorType ())
  secureQueue st sq sKey =
    atomically (readQueueRec qr $>>= secure)
      $>>= \_ -> withLog "secureQueue" st $ \s -> logSecureQueue s (recipientId sq) sKey
    where
      qr = queueRec sq
      secure q = case senderKey q of
        Just k -> pure $ if sKey == k then Right () else Left AUTH
        Nothing -> do
          writeTVar qr $ Just q {senderKey = Just sKey}
          pure $ Right ()

  addQueueNotifier :: STMQueueStore q -> q -> NtfCreds -> IO (Either ErrorType (Maybe NotifierId))
  addQueueNotifier st sq ntfCreds@NtfCreds {notifierId = nId} =
    atomically (readQueueRec qr $>>= add)
      $>>= \nId_ -> nId_ <$$ withLog "addQueueNotifier" st (\s -> logAddNotifier s rId ntfCreds)
    where
      rId = recipientId sq
      qr = queueRec sq
      STMQueueStore {notifiers} = st
      add q = ifM (TM.member nId notifiers) (pure $ Left DUPLICATE_) $ do
        nId_ <- forM (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId notifiers $> notifierId
        let !q' = q {notifier = Just ntfCreds}
        writeTVar qr $ Just q'
        TM.insert nId rId notifiers
        pure $ Right nId_

  deleteQueueNotifier :: STMQueueStore q -> q -> IO (Either ErrorType (Maybe NotifierId))
  deleteQueueNotifier st sq =
    atomically (readQueueRec qr >>= mapM delete)
      $>>= \nId_ -> nId_ <$$ withLog "deleteQueueNotifier" st (`logDeleteNotifier` recipientId sq)
    where
      qr = queueRec sq
      delete q = forM (notifier q) $ \NtfCreds {notifierId} -> do
        TM.delete notifierId $ notifiers st
        writeTVar qr $! Just q {notifier = Nothing}
        pure notifierId

  suspendQueue :: STMQueueStore q -> q -> IO (Either ErrorType ())
  suspendQueue st sq =
    atomically (readQueueRec qr >>= mapM suspend)
      $>>= \_ -> withLog "suspendQueue" st (`logSuspendQueue` recipientId sq)
    where
      qr = queueRec sq
      suspend q = writeTVar qr $! Just q {status = EntityOff}

  blockQueue :: STMQueueStore q -> q -> BlockingInfo -> IO (Either ErrorType ())
  blockQueue st sq info =
    atomically (readQueueRec qr >>= mapM block)
      $>>= \_ -> withLog "blockQueue" st (\sl -> logBlockQueue sl (recipientId sq) info)
    where
      qr = queueRec sq
      block q = writeTVar qr $ Just q {status = EntityBlocked info}

  unblockQueue :: STMQueueStore q -> q -> IO (Either ErrorType ())
  unblockQueue st sq =
    atomically (readQueueRec qr >>= mapM unblock)
      $>>= \_ -> withLog "unblockQueue" st (`logUnblockQueue` recipientId sq)
    where
      qr = queueRec sq
      unblock q = writeTVar qr $ Just q {status = EntityActive}

  updateQueueTime :: STMQueueStore q -> q -> RoundedSystemTime -> IO (Either ErrorType QueueRec)
  updateQueueTime st sq t = atomically (readQueueRec qr >>= mapM update) $>>= log'
    where
      qr = queueRec sq
      update q@QueueRec {updatedAt}
        | updatedAt == Just t = pure (q, False)
        | otherwise =
            let !q' = q {updatedAt = Just t}
            in (writeTVar qr $! Just q') $> (q', True)
      log' (q, changed)
        | changed = q <$$ withLog "updateQueueTime" st (\sl -> logUpdateQueueTime sl (recipientId sq) t)
        | otherwise = pure $ Right q

  deleteStoreQueue :: STMQueueStore q -> q -> IO (Either ErrorType (QueueRec, Maybe (MsgQueue q)))
  deleteStoreQueue st sq =
    atomically (readQueueRec qr >>= mapM delete)
      $>>= \q -> withLog "deleteStoreQueue" st (`logDeleteQueue` recipientId sq)
      >>= bimapM pure (\_ -> (q,) <$> atomically (swapTVar (msgQueue sq) Nothing))
    where
      qr = queueRec sq
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
