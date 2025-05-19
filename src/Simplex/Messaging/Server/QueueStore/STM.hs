{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Simplex.Messaging.Server.QueueStore.STM
  ( STMQueueStore (..),
    setStoreLog,
    withLog',
    readQueueRecIO,
    setStatus,
  )
where

import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import Data.Bitraversable (bimapM)
import Data.Functor (($>))
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.X509 as X
import qualified Data.X509.Validation as XV
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (SMPServiceRole)
import Simplex.Messaging.Util (anyM, ifM, ($>>), ($>>=), (<$$))
import System.IO
import UnliftIO.STM

data STMQueueStore q = STMQueueStore
  { queues :: TMap RecipientId q,
    senders :: TMap SenderId RecipientId,
    notifiers :: TMap NotifierId RecipientId,
    links :: TMap LinkId RecipientId,
    storeLog :: TVar (Maybe (StoreLog 'WriteMode))
  }

setStoreLog :: STMQueueStore q -> StoreLog 'WriteMode -> IO ()
setStoreLog st sl = atomically $ writeTVar (storeLog st) (Just sl)

instance StoreQueueClass q => QueueStoreClass q (STMQueueStore q) where
  type QueueStoreCfg (STMQueueStore q) = ()

  newQueueStore :: () -> IO (STMQueueStore q)
  newQueueStore _ = do
    queues <- TM.emptyIO
    senders <- TM.emptyIO
    notifiers <- TM.emptyIO
    links <- TM.emptyIO
    storeLog <- newTVarIO Nothing
    pure STMQueueStore {queues, senders, notifiers, links, storeLog}

  closeQueueStore :: STMQueueStore q -> IO ()
  closeQueueStore STMQueueStore {queues, senders, notifiers, storeLog} = do
    readTVarIO storeLog >>= mapM_ closeStoreLog
    atomically $ TM.clear queues
    atomically $ TM.clear senders
    atomically $ TM.clear notifiers

  loadedQueues = queues
  {-# INLINE loadedQueues #-}
  compactQueues _ = pure 0
  {-# INLINE compactQueues #-}

  queueCounts :: STMQueueStore q -> IO QueueCounts
  queueCounts st = do
    queueCount <- M.size <$> readTVarIO (queues st)
    notifierCount <- M.size <$> readTVarIO (notifiers st)
    pure QueueCounts {queueCount, notifierCount}

  addQueue_ :: STMQueueStore q -> (RecipientId -> QueueRec -> IO q) -> RecipientId -> QueueRec -> IO (Either ErrorType q)
  addQueue_ st mkQ rId qr@QueueRec {senderId = sId, notifier, queueData} = do
    sq <- mkQ rId qr
    add sq $>> withLog "addStoreQueue" st (\s -> logCreateQueue s rId qr) $> Right sq
    where
      STMQueueStore {queues, senders, notifiers, links} = st
      add q = atomically $ ifM hasId (pure $ Left DUPLICATE_) $ Right () <$ do
        TM.insert rId q queues
        TM.insert sId rId senders
        forM_ notifier $ \NtfCreds {notifierId} -> TM.insert notifierId rId notifiers
        forM_ queueData $ \(lnkId, _) -> TM.insert lnkId rId links
      hasId = anyM [TM.member rId queues, TM.member sId senders, hasNotifier, hasLink]
      hasNotifier = maybe (pure False) (\NtfCreds {notifierId} -> TM.member notifierId notifiers) notifier
      hasLink = maybe (pure False) (\(lnkId, _) -> TM.member lnkId links) queueData

  getQueue_ :: DirectParty p => STMQueueStore q -> (Bool -> RecipientId -> QueueRec -> IO q) -> SParty p -> QueueId -> IO (Either ErrorType q)
  getQueue_ st _ party qId =
    maybe (Left AUTH) Right <$> case party of
      SRecipient -> TM.lookupIO qId queues
      SSender -> getSndQueue
      SProxyService -> getSndQueue
      SNotifier -> TM.lookupIO qId notifiers $>>= (`TM.lookupIO` queues)
      SSenderLink -> TM.lookupIO qId links $>>= (`TM.lookupIO` queues)
    where
      STMQueueStore {queues, senders, notifiers, links} = st
      getSndQueue = TM.lookupIO qId senders $>>= (`TM.lookupIO` queues)

  getQueueLinkData :: STMQueueStore q -> q -> LinkId -> IO (Either ErrorType QueueLinkData)
  getQueueLinkData _ q lnkId = atomically $ readQueueRec (queueRec q) $>>= pure . getData
    where
      getData qr = case queueData qr of
        Just (lnkId', d) | lnkId' == lnkId -> Right d
        _ -> Left AUTH

  addQueueLinkData :: STMQueueStore q -> q -> LinkId -> QueueLinkData -> IO (Either ErrorType ())
  addQueueLinkData st sq lnkId d =
    atomically (readQueueRec qr $>>= add)
      $>> withLog "addQueueLinkData" st (\s -> logCreateLink s rId lnkId d)
    where
      rId = recipientId sq
      qr = queueRec sq
      add q = case queueData q of
        Nothing -> addLink
        Just (lnkId', d') | lnkId' == lnkId && fst d' == fst d -> addLink
        _ -> pure $ Left AUTH
        where
          addLink = do
            let !q' = q {queueData = Just (lnkId, d)}
            writeTVar qr $ Just q'
            TM.insert lnkId rId $ links st
            pure $ Right ()

  deleteQueueLinkData :: STMQueueStore q -> q -> IO (Either ErrorType ())
  deleteQueueLinkData st sq =
    withQueueRec qr delete
      $>> withLog "deleteQueueLinkData" st (`logDeleteLink` recipientId sq)
    where
      qr = queueRec sq
      delete q = forM (queueData q) $ \(lnkId, _) -> do
        TM.delete lnkId $ links st
        writeTVar qr $ Just q {queueData = Nothing}

  updateKeys :: STMQueueStore q -> q -> NonEmpty RcvPublicAuthKey -> IO (Either ErrorType ())
  updateKeys st sq rKeys =
    withQueueRec qr update
      $>> withLog "updateKeys" st (\s -> logUpdateKeys s (recipientId sq) rKeys)
    where
      qr = queueRec sq
      update q = writeTVar qr $ Just q {recipientKeys = rKeys}

  secureQueue :: STMQueueStore q -> q -> SndPublicAuthKey -> IO (Either ErrorType ())
  secureQueue st sq sKey =
    atomically (readQueueRec qr $>>= secure)
      $>> withLog "secureQueue" st (\s -> logSecureQueue s (recipientId sq) sKey)
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
    withQueueRec qr delete
      $>>= \nId_ -> nId_ <$$ withLog "deleteQueueNotifier" st (`logDeleteNotifier` recipientId sq)
    where
      qr = queueRec sq
      delete q = forM (notifier q) $ \NtfCreds {notifierId} -> do
        TM.delete notifierId $ notifiers st
        writeTVar qr $ Just q {notifier = Nothing}
        pure notifierId

  suspendQueue :: STMQueueStore q -> q -> IO (Either ErrorType ())
  suspendQueue st sq =
    setStatus (queueRec sq) EntityOff
      $>> withLog "suspendQueue" st (`logSuspendQueue` recipientId sq)

  blockQueue :: STMQueueStore q -> q -> BlockingInfo -> IO (Either ErrorType ())
  blockQueue st sq info =
    setStatus (queueRec sq) (EntityBlocked info)
      $>> withLog "blockQueue" st (\sl -> logBlockQueue sl (recipientId sq) info)

  unblockQueue :: STMQueueStore q -> q -> IO (Either ErrorType ())
  unblockQueue st sq =
    setStatus (queueRec sq) EntityActive
      $>> withLog "unblockQueue" st (`logUnblockQueue` recipientId sq)

  updateQueueTime :: STMQueueStore q -> q -> RoundedSystemTime -> IO (Either ErrorType QueueRec)
  updateQueueTime st sq t = withQueueRec qr update $>>= log'
    where
      qr = queueRec sq
      update q@QueueRec {updatedAt}
        | updatedAt == Just t = pure (q, False)
        | otherwise =
            let !q' = q {updatedAt = Just t}
             in writeTVar qr (Just q') $> (q', True)
      log' (q, changed)
        | changed = q <$$ withLog "updateQueueTime" st (\sl -> logUpdateQueueTime sl (recipientId sq) t)
        | otherwise = pure $ Right q

  deleteStoreQueue :: STMQueueStore q -> q -> IO (Either ErrorType (QueueRec, Maybe (MsgQueue q)))
  deleteStoreQueue st sq =
    withQueueRec qr delete
      $>>= \q -> withLog "deleteStoreQueue" st (`logDeleteQueue` recipientId sq)
      >>= mapM (\_ -> (q,) <$> atomically (swapTVar (msgQueue sq) Nothing))
    where
      qr = queueRec sq
      delete q = do
        writeTVar qr Nothing
        TM.delete (senderId q) $ senders st
        forM_ (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId $ notifiers st
        pure q

  -- TODO [certs] implement
  getCreateService :: STMQueueStore q -> SMPServiceRole -> X.CertificateChain -> XV.Fingerprint -> IO (Either ErrorType ServiceId)
  getCreateService = undefined

withQueueRec :: TVar (Maybe QueueRec) -> (QueueRec -> STM a) -> IO (Either ErrorType a)
withQueueRec qr a = atomically $ readQueueRec qr >>= mapM a

setStatus :: TVar (Maybe QueueRec) -> ServerEntityStatus -> IO (Either ErrorType ())
setStatus qr status =
  atomically $ stateTVar qr $ \case
    Just q -> (Right (), Just q {status})
    Nothing -> (Left AUTH, Nothing)

readQueueRec :: TVar (Maybe QueueRec) -> STM (Either ErrorType QueueRec)
readQueueRec qr = maybe (Left AUTH) Right <$> readTVar qr
{-# INLINE readQueueRec #-}

readQueueRecIO :: TVar (Maybe QueueRec) -> IO (Either ErrorType QueueRec)
readQueueRecIO qr = maybe (Left AUTH) Right <$> readTVarIO qr
{-# INLINE readQueueRecIO #-}

withLog' :: String -> TVar (Maybe (StoreLog 'WriteMode)) -> (StoreLog 'WriteMode -> IO ()) -> IO (Either ErrorType ())
withLog' name sl action =
  readTVarIO sl
    >>= maybe (pure $ Right ()) (E.try . E.uninterruptibleMask_ . action >=> bimapM logErr pure)
  where
    logErr :: E.SomeException -> IO ErrorType
    logErr e = logError ("STORE: " <> T.pack err) $> STORE err
      where
        err = name <> ", withLog, " <> show e

withLog :: String -> STMQueueStore q -> (StoreLog 'WriteMode -> IO ()) -> IO (Either ErrorType ())
withLog name = withLog' name . storeLog
{-# INLINE withLog #-}
