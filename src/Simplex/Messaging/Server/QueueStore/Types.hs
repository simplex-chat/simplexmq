{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeFamilyDependencies #-}

module Simplex.Messaging.Server.QueueStore.Types where

import Control.Concurrent.STM
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore

class StoreQueueClass q where
  type MsgQueue q = mq | mq -> q
  recipientId :: q -> RecipientId
  queueRec :: q -> TVar (Maybe QueueRec)
  msgQueue :: q -> TVar (Maybe (MsgQueue q))

class StoreQueueClass q => QueueStoreClass q s where
  queueCounts :: s -> IO QueueCounts
  addStoreQueue :: s -> QueueRec -> q -> IO (Either ErrorType ())
  getQueue :: DirectParty p => s -> SParty p -> QueueId -> IO (Either ErrorType q)
  secureQueue :: s -> q -> SndPublicAuthKey -> IO (Either ErrorType ())
  addQueueNotifier :: s -> q -> NtfCreds -> IO (Either ErrorType (Maybe NotifierId))
  deleteQueueNotifier :: s -> q -> IO (Either ErrorType (Maybe NotifierId))
  suspendQueue :: s -> q -> IO (Either ErrorType ())
  blockQueue :: s -> q -> BlockingInfo -> IO (Either ErrorType ())
  unblockQueue :: s -> q -> IO (Either ErrorType ())
  updateQueueTime :: s -> q -> RoundedSystemTime -> IO (Either ErrorType QueueRec)
  deleteStoreQueue :: s -> q -> IO (Either ErrorType (QueueRec, Maybe (MsgQueue q)))

data QueueCounts = QueueCounts
  { queueCount :: Int,
    notifierCount :: Int
  }
