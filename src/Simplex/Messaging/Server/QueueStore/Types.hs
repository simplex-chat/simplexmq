{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeFamilyDependencies #-}

module Simplex.Messaging.Server.QueueStore.Types
  ( StoreQueueClass (..),
    QueueStoreClass (..),
    EntityCounts (..),
    withLoadedQueues,
  ) where

import Control.Concurrent.STM
import Control.Monad
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.SystemTime
import Simplex.Messaging.TMap (TMap)

class StoreQueueClass q where
  recipientId :: q -> RecipientId
  queueRec :: q -> TVar (Maybe QueueRec)
  withQueueLock :: q -> Text -> IO a -> IO a

class StoreQueueClass q => QueueStoreClass q s where
  type QueueStoreCfg s
  newQueueStore :: QueueStoreCfg s -> IO s
  closeQueueStore :: s -> IO ()
  getEntityCounts :: s -> IO EntityCounts
  loadedQueues :: s -> TMap RecipientId q
  compactQueues :: s -> IO Int64
  addQueue_ :: s -> (RecipientId -> QueueRec -> IO q) -> RecipientId -> QueueRec -> IO (Either ErrorType q)
  getQueue_ :: QueueParty p => s -> (Bool -> RecipientId -> QueueRec -> IO q) -> SParty p -> QueueId -> IO (Either ErrorType q)
  getQueues_ :: BatchParty p => s -> (Bool -> RecipientId -> QueueRec -> IO q) -> SParty p -> [QueueId] -> IO [Either ErrorType q]
  getQueueLinkData :: s -> q -> LinkId -> IO (Either ErrorType QueueLinkData)
  addQueueLinkData :: s -> q -> LinkId -> QueueLinkData -> IO (Either ErrorType ())
  deleteQueueLinkData :: s -> q -> IO (Either ErrorType ())
  secureQueue :: s -> q -> SndPublicAuthKey -> IO (Either ErrorType ())
  updateKeys :: s -> q -> NonEmpty RcvPublicAuthKey -> IO (Either ErrorType ())
  addQueueNotifier :: s -> q -> NtfCreds -> IO (Either ErrorType (Maybe NtfCreds))
  deleteQueueNotifier :: s -> q -> IO (Either ErrorType (Maybe NtfCreds))
  suspendQueue :: s -> q -> IO (Either ErrorType ())
  blockQueue :: s -> q -> BlockingInfo -> IO (Either ErrorType ())
  unblockQueue :: s -> q -> IO (Either ErrorType ())
  updateQueueTime :: s -> q -> SystemDate -> IO (Either ErrorType QueueRec)
  deleteStoreQueue :: s -> q -> IO (Either ErrorType QueueRec)
  getCreateService :: s -> ServiceRec -> IO (Either ErrorType ServiceId)
  setQueueService :: (PartyI p, ServiceParty p) => s -> q -> SParty p -> Maybe ServiceId -> IO (Either ErrorType ())
  getQueueNtfServices :: s -> [(NotifierId, a)] -> IO (Either ErrorType ([(Maybe ServiceId, [(NotifierId, a)])], [(NotifierId, a)]))
  getServiceQueueCount :: (PartyI p, ServiceParty p) => s -> SParty p -> ServiceId -> IO (Either ErrorType Int64)

data EntityCounts = EntityCounts
  { queueCount :: Int,
    notifierCount :: Int,
    rcvServiceCount :: Int,
    ntfServiceCount :: Int,
    rcvServiceQueuesCount :: Int,
    ntfServiceQueuesCount :: Int
  }

withLoadedQueues :: (Monoid a, QueueStoreClass q s) => s -> (q -> IO a) -> IO a
withLoadedQueues st f = readTVarIO (loadedQueues st) >>= foldM run mempty
  where
    run !acc = fmap (acc <>) . f
