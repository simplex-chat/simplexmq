{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeFamilyDependencies #-}

module Simplex.Messaging.Server.QueueStore.Types where

import Control.Concurrent.STM
import Control.Monad
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.X509 as X
import qualified Data.X509.Validation as XV
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.TMap (TMap)
import Simplex.Messaging.Transport (SMPServiceRole)

class StoreQueueClass q where
  type MsgQueue q = mq | mq -> q
  recipientId :: q -> RecipientId
  queueRec :: q -> TVar (Maybe QueueRec)
  msgQueue :: q -> TVar (Maybe (MsgQueue q))
  withQueueLock :: q -> String -> IO a -> IO a

class StoreQueueClass q => QueueStoreClass q s where
  type QueueStoreCfg s
  newQueueStore :: QueueStoreCfg s -> IO s
  closeQueueStore :: s -> IO ()
  queueCounts :: s -> IO QueueCounts
  loadedQueues :: s -> TMap RecipientId q
  compactQueues :: s -> IO Int64
  addQueue_ :: s -> (RecipientId -> QueueRec -> IO q) -> RecipientId -> QueueRec -> IO (Either ErrorType q)
  getQueue_ :: DirectParty p => s -> (Bool -> RecipientId -> QueueRec -> IO q) -> SParty p -> QueueId -> IO (Either ErrorType q)
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
  updateQueueTime :: s -> q -> RoundedSystemTime -> IO (Either ErrorType QueueRec)
  deleteStoreQueue :: s -> q -> IO (Either ErrorType (QueueRec, Maybe (MsgQueue q)))
  getCreateService :: s -> ServiceRec -> IO (Either ErrorType ServiceId)
  setQueueRcvService :: s -> q -> Maybe ServiceId -> IO (Either ErrorType ())
  setQueueNtfService :: s -> q -> Maybe ServiceId -> IO (Either ErrorType ())
  getQueueNtfServices :: s -> [(NotifierId, a)] -> IO (Either ErrorType ([(Maybe ServiceId, [(NotifierId, a)])], [(NotifierId, a)]))
  getNtfServiceQueueCount :: s -> ServiceId -> IO (Either ErrorType Int64)

data QueueCounts = QueueCounts
  { queueCount :: Int,
    notifierCount :: Int
  }

withLoadedQueues :: (Monoid a, QueueStoreClass q s) => s -> (q -> IO a) -> IO a
withLoadedQueues st f = readTVarIO (loadedQueues st) >>= foldM run mempty
  where
    run !acc = fmap (acc <>) . f
