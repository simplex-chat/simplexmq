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
  ( STMQueueStore (..),
    newQueueStore,
    setStoreLog,
    withQueues,
    addQueue',
    getQueue',
    secureQueue',
    addQueueNotifier',
    deleteQueueNotifier',
    suspendQueue',
    blockQueue',
    unblockQueue',
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
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Data.Bitraversable (bimapM)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Functor (($>))
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

newQueueStore :: IO (STMQueueStore q)
newQueueStore = do
  queues <- TM.emptyIO
  senders <- TM.emptyIO
  notifiers <- TM.emptyIO
  storeLog <- newTVarIO Nothing
  pure STMQueueStore {queues, senders, notifiers, storeLog}

setStoreLog :: STMQueueStore q -> StoreLog 'WriteMode -> IO ()
setStoreLog st sl = atomically $ writeTVar (storeLog st) (Just sl)

withQueues :: Monoid a => STMQueueStore (StoreQueue s) -> (StoreQueue s -> IO a) -> IO a
withQueues st f = readTVarIO (queues st) >>= foldM run mempty
  where
    run !acc = fmap (acc <>) . f

addQueue' :: STMStoreClass s => s -> RecipientId -> QueueRec -> IO (Either ErrorType (StoreQueue s))
addQueue' ms rId qr@QueueRec {senderId = sId, notifier} =
  (mkQueue ms rId qr >>= atomically . add)
    $>>= \q -> q <$$ withLog "addQueue" st (\s -> logCreateQueue s rId qr)
  where
    st = stmQueueStore ms
    add q = ifM hasId (pure $ Left DUPLICATE_) $ do
      TM.insert rId q $ queues st
      TM.insert sId rId $ senders st
      forM_ notifier $ \NtfCreds {notifierId} -> TM.insert notifierId rId $ notifiers st
      pure $ Right q
    hasId = anyM [TM.member rId $ queues st, TM.member sId $ senders st, hasNotifier]
    hasNotifier = maybe (pure False) (\NtfCreds {notifierId} -> TM.member notifierId (notifiers st)) notifier

getQueue' :: DirectParty p => STMQueueStore q -> SParty p -> QueueId -> IO (Either ErrorType q)
getQueue' st party qId =
  maybe (Left AUTH) Right <$> case party of
    SRecipient -> TM.lookupIO qId $ queues st
    SSender -> TM.lookupIO qId (senders st) $>>= (`TM.lookupIO` queues st)
    SNotifier -> TM.lookupIO qId (notifiers st) $>>= (`TM.lookupIO` queues st)

secureQueue' :: MsgStoreClass s => STMQueueStore (StoreQueue s) -> StoreQueue s -> SndPublicAuthKey -> IO (Either ErrorType ())
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

addQueueNotifier' :: MsgStoreClass s => STMQueueStore (StoreQueue s) -> StoreQueue s -> NtfCreds -> IO (Either ErrorType (Maybe NotifierId))
addQueueNotifier' st sq ntfCreds@NtfCreds {notifierId = nId} =
  atomically (readQueueRec qr $>>= add)
    $>>= \nId_ -> nId_ <$$ withLog "addQueueNotifier" st (\s -> logAddNotifier s rId ntfCreds)
  where
    qr = queueRec' sq
    rId = recipientId' sq
    add q = ifM (TM.member nId (notifiers st)) (pure $ Left DUPLICATE_) $ do
      nId_ <- forM (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId (notifiers st) $> notifierId
      let !q' = q {notifier = Just ntfCreds}
      writeTVar qr $ Just q'
      TM.insert nId rId $ notifiers st
      pure $ Right nId_

deleteQueueNotifier' :: MsgStoreClass s => STMQueueStore (StoreQueue s) -> StoreQueue s -> IO (Either ErrorType (Maybe NotifierId))
deleteQueueNotifier' st sq =
  atomically (readQueueRec qr >>= mapM delete)
    $>>= \nId_ -> nId_ <$$ withLog "deleteQueueNotifier" st (`logDeleteNotifier` recipientId' sq)
  where
    qr = queueRec' sq
    delete q = forM (notifier q) $ \NtfCreds {notifierId} -> do
      TM.delete notifierId $ notifiers st
      writeTVar qr $! Just q {notifier = Nothing}
      pure notifierId

suspendQueue' :: MsgStoreClass s => STMQueueStore (StoreQueue s) -> StoreQueue s -> IO (Either ErrorType ())
suspendQueue' st sq =
  atomically (readQueueRec qr >>= mapM suspend)
    $>>= \_ -> withLog "suspendQueue" st (`logSuspendQueue` recipientId' sq)
  where
    qr = queueRec' sq
    suspend q = writeTVar qr $! Just q {status = EntityOff}

blockQueue' :: MsgStoreClass s => STMQueueStore (StoreQueue s) -> StoreQueue s -> BlockingInfo -> IO (Either ErrorType ())
blockQueue' st sq info =
  atomically (readQueueRec qr >>= mapM block)
    $>>= \_ -> withLog "blockQueue" st (\sl -> logBlockQueue sl (recipientId' sq) info)
  where
    qr = queueRec' sq
    block q = writeTVar qr $ Just q {status = EntityBlocked info}

unblockQueue' :: MsgStoreClass s => STMQueueStore (StoreQueue s) -> StoreQueue s -> IO (Either ErrorType ())
unblockQueue' st sq =
  atomically (readQueueRec qr >>= mapM unblock)
    $>>= \_ -> withLog "unblockQueue" st (`logUnblockQueue` recipientId' sq)
  where
    qr = queueRec' sq
    unblock q = writeTVar qr $ Just q {status = EntityActive}

updateQueueTime' :: MsgStoreClass s => STMQueueStore (StoreQueue s) -> StoreQueue s -> RoundedSystemTime -> IO (Either ErrorType QueueRec)
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

deleteQueue' :: MsgStoreClass s => STMQueueStore (StoreQueue s) -> StoreQueue s -> IO (Either ErrorType (QueueRec, Maybe (MsgQueue s)))
deleteQueue' st sq =
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

readQueueStore :: forall s. STMStoreClass s => FilePath -> s -> IO ()
readQueueStore f ms = withFile f ReadMode $ LB.hGetContents >=> mapM_ processLine . LB.lines
  where
    st = stmQueueStore ms
    processLine :: LB.ByteString -> IO ()
    processLine s' = either printError procLogRecord (strDecode s)
      where
        s = LB.toStrict s'
        procLogRecord :: StoreLogRecord -> IO ()
        procLogRecord = \case
          CreateQueue rId q -> addQueue ms rId q >>= qError rId "CreateQueue"
          SecureQueue qId sKey -> withQueue qId "SecureQueue" $ \q -> secureQueue' st q sKey
          AddNotifier qId ntfCreds -> withQueue qId "AddNotifier" $ \q -> addQueueNotifier' st q ntfCreds
          SuspendQueue qId -> withQueue qId "SuspendQueue" $ suspendQueue' st
          BlockQueue qId info -> withQueue qId "BlockQueue" $ \q -> blockQueue' st q info
          UnblockQueue qId -> withQueue qId "UnblockQueue" $ unblockQueue' st
          DeleteQueue qId -> withQueue qId "DeleteQueue" $ deleteQueue' st
          DeleteNotifier qId -> withQueue qId "DeleteNotifier" $ deleteQueueNotifier' st
          UpdateTime qId t -> withQueue qId "UpdateTime" $ \q -> updateQueueTime' st q t
        printError :: String -> IO ()
        printError e = B.putStrLn $ "Error parsing log: " <> B.pack e <> " - " <> s
        withQueue :: forall a. RecipientId -> T.Text -> (StoreQueue s -> IO (Either ErrorType a)) -> IO ()
        withQueue qId op a = runExceptT go >>= qError qId op
          where
            go = do
              q <- ExceptT $ getQueue' st SRecipient qId
              liftIO (readTVarIO $ queueRec' q) >>= \case
                Nothing -> logWarn $ logPfx qId op <> "already deleted"
                Just _ -> void $ ExceptT $ a q
        qError qId op = \case
          Left e -> logError $ logPfx qId op <> tshow e
          Right _ -> pure ()
        logPfx qId op = "STORE: " <> op <> ", stored queue " <> decodeLatin1 (strEncode qId) <> ", "
