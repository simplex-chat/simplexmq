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
import Data.ByteString (ByteString)
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List (partition)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.X509.Validation as XV
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (anyM, ifM, ($>>), ($>>=), (<$$))
import System.IO
import UnliftIO.STM

data STMQueueStore q = STMQueueStore
  { queues :: TMap RecipientId q,
    senders :: TMap SenderId RecipientId,
    notifiers :: TMap NotifierId RecipientId,
    services :: TMap ServiceId STMService,
    serviceCerts :: TMap CertFingerprint ServiceId,
    links :: TMap LinkId RecipientId,
    storeLog :: TVar (Maybe (StoreLog 'WriteMode))
  }

type CertFingerprint = ByteString

data STMService = STMService
  { serviceRec :: ServiceRec,
    serviceRcvQueues :: TVar (Set RecipientId),
    serviceNtfQueues :: TVar (Set NotifierId)
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
    services <- TM.emptyIO
    serviceCerts <- TM.emptyIO
    links <- TM.emptyIO
    storeLog <- newTVarIO Nothing
    pure STMQueueStore {queues, senders, notifiers, links, services, serviceCerts, storeLog}

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

  addQueueNotifier :: STMQueueStore q -> q -> NtfCreds -> IO (Either ErrorType (Maybe NtfCreds))
  addQueueNotifier st sq ntfCreds@NtfCreds {notifierId = nId} =
    atomically (readQueueRec qr $>>= add)
      $>>= \nc_ -> nc_ <$$ withLog "addQueueNotifier" st (\s -> logAddNotifier s rId ntfCreds)
    where
      rId = recipientId sq
      qr = queueRec sq
      STMQueueStore {notifiers} = st
      add q = ifM (TM.member nId notifiers) (pure $ Left DUPLICATE_) $ do
        nc_ <- forM (notifier q) $ \nc@NtfCreds {notifierId} -> TM.delete notifierId notifiers $> nc
        let !q' = q {notifier = Just ntfCreds}
        writeTVar qr $ Just q'
        TM.insert nId rId notifiers
        pure $ Right nc_

  deleteQueueNotifier :: STMQueueStore q -> q -> IO (Either ErrorType (Maybe NtfCreds))
  deleteQueueNotifier st sq =
    withQueueRec qr delete
      $>>= \nc_ -> nc_ <$$ withLog "deleteQueueNotifier" st (`logDeleteNotifier` recipientId sq)
    where
      qr = queueRec sq
      delete q = forM (notifier q) $ \nc@NtfCreds {notifierId} -> do
        TM.delete notifierId $ notifiers st
        writeTVar qr $ Just q {notifier = Nothing}
        pure nc

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

  getCreateService :: STMQueueStore q -> ServiceRec -> IO (Either ErrorType ServiceId)
  getCreateService st sr@ServiceRec {serviceId = newSrvId, serviceRole, serviceCertHash = XV.Fingerprint fps} =
    TM.lookupIO fps serviceCerts
      >>= maybe
        (atomically $ TM.lookup fps serviceCerts >>= maybe newService checkService)
        (atomically . checkService)
      $>>= \(serviceId, new) ->
        if new
          then serviceId <$$ withLog "getCreateService" st (`logNewService` sr)
          else pure $ Right serviceId
    where
      STMQueueStore {services, serviceCerts} = st
      checkService sId =
        TM.lookup sId services >>= \case
          Just STMService {serviceRec = ServiceRec {serviceId, serviceRole = role}}
            | role == serviceRole -> pure $ Right (serviceId, False)
            | otherwise -> pure $ Left AUTH -- TODO [certs] remove associations?
          Nothing -> newService_
      newService = ifM (TM.member newSrvId services) (pure $ Left DUPLICATE_) newService_
      newService_ = do
        TM.insertM newSrvId newSTMService services
        TM.insert fps newSrvId serviceCerts
        pure $ Right (newSrvId, True)
      newSTMService = do
        serviceRcvQueues <- newTVar S.empty
        serviceNtfQueues <- newTVar S.empty
        pure STMService {serviceRec = sr, serviceRcvQueues, serviceNtfQueues}

  setQueueRcvService :: STMQueueStore q -> q -> Maybe ServiceId -> IO (Either ErrorType ())
  setQueueRcvService st sq serviceId =
    atomically (readQueueRec qr $>>= setService)
      $>>= \_ -> withLog "setQueueRcvService" st (\sl -> logQueueRcvService sl rId serviceId)
    where
      qr = queueRec sq
      rId = recipientId sq
      setService q@QueueRec {rcvServiceId = prevSrvId}
        | prevSrvId == serviceId = pure $ Right ()
        | otherwise = do
            let !q' = Just q {rcvServiceId = serviceId}
            setQueueService (services st) serviceRcvQueues rId prevSrvId serviceId
              $>> (writeTVar qr q' $> Right ())

  setQueueNtfService :: STMQueueStore q -> q -> Maybe ServiceId -> IO (Either ErrorType ())
  setQueueNtfService st sq serviceId =
    atomically (readQueueRec qr $>>= setService)
      $>>= \_ -> withLog "setQueueNtfService" st (\sl -> logQueueRcvService sl rId serviceId)
    where
      qr = queueRec sq
      rId = recipientId sq
      setService q@QueueRec {notifier} = case notifier of
        Nothing -> pure $ Left AUTH -- TODO [certs] different error? INTERNAL?
        Just nc@NtfCreds {notifierId = nId, ntfServiceId = prevSrvId}
          | prevSrvId == serviceId -> pure $ Right ()
          | otherwise -> do
              let !q' = Just q {notifier = Just nc {ntfServiceId = serviceId}}
              setQueueService (services st) serviceNtfQueues nId prevSrvId serviceId
                $>> (writeTVar qr q' $> Right ())

  getQueueNtfServices :: STMQueueStore q -> [(NotifierId, a)] -> IO (Either ErrorType ([(Maybe ServiceId, [(NotifierId, a)])], [(NotifierId, a)]))
  getQueueNtfServices st ntfs = do
    ss <- readTVarIO (services st)
    (ssNtfs, noServiceNtfs) <- if M.null ss then pure ([], ntfs) else foldM addService ([], ntfs) (M.assocs ss)
    ns <- readTVarIO (notifiers st)
    let (ntfs', deleteNtfs) = partition (\(nId, _) -> M.member nId ns) noServiceNtfs
        ssNtfs' = (Nothing, ntfs') : ssNtfs
    pure $ Right (ssNtfs', deleteNtfs)
    where
      addService (ssNtfs, ntfs') (serviceId, s) = do
        snIds <- readTVarIO $ serviceNtfQueues s
        let (sNtfs, restNtfs) = partition (\(nId, _) -> S.member nId snIds) ntfs'
            ssNtfs' = (Just serviceId, sNtfs) : ssNtfs
        pure (ssNtfs', restNtfs)

  -- TODO [certs]
  getNtfServiceQueueCount :: STMQueueStore q -> ServiceId -> IO (Either ErrorType Int64)
  getNtfServiceQueueCount = undefined

withQueueRec :: TVar (Maybe QueueRec) -> (QueueRec -> STM a) -> IO (Either ErrorType a)
withQueueRec qr a = atomically $ readQueueRec qr >>= mapM a

setStatus :: TVar (Maybe QueueRec) -> ServerEntityStatus -> IO (Either ErrorType ())
setStatus qr status =
  atomically $ stateTVar qr $ \case
    Just q -> (Right (), Just q {status})
    Nothing -> (Left AUTH, Nothing)

setQueueService :: TMap ServiceId STMService -> (STMService -> TVar (Set QueueId)) -> QueueId -> Maybe ServiceId -> Maybe ServiceId -> STM (Either ErrorType ())
setQueueService ss serviceSel qId prevSrvId currSrvId = do
  mapM_ (setService S.delete) prevSrvId
  fromMaybe (Right ()) <$> mapM (setService S.insert) currSrvId
  where
    setService :: (QueueId -> Set QueueId -> Set QueueId) -> ServiceId -> STM (Either ErrorType ())
    setService f sId =
      TM.lookup sId ss >>= \case
        Just s -> Right () <$ modifyTVar' (serviceSel s) (f qId)
        Nothing -> pure $ Left AUTH -- TODO [certs] INTERNAL?

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
