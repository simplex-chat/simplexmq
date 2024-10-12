{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilyDependencies #-}

module Simplex.Messaging.Server.MsgStore.Types where

import Data.Int (Int64)
import Data.Kind
import Data.Set (Set)
import Simplex.Messaging.Protocol (Message (..), MsgId, RecipientId)

class MsgStoreClass s where
  type MessageQueue s = q | q -> s
  getMsgQueueIds :: s -> IO (Set RecipientId)
  getMsgQueue :: s -> RecipientId -> Int -> IO (MessageQueue s)
  delMsgQueue :: s -> RecipientId -> IO ()
  delMsgQueueSize :: s -> RecipientId -> IO Int

class MsgQueueClass q where 
  writeMsg :: q -> Message -> IO (Maybe (Message, Bool))
  tryPeekMsg :: q -> IO (Maybe Message)
  tryDelMsg :: q -> MsgId -> IO (Maybe Message)
  tryDelPeekMsg :: q -> MsgId -> IO (Maybe Message, Maybe Message)
  deleteExpiredMsgs :: q -> Int64 -> IO Int
  getQueueSize :: q -> IO Int

data MSType = MSMemory | MSJournal

data SMSType :: MSType -> Type where
  SMSMemory :: SMSType 'MSMemory
  SMSJournal :: SMSType 'MSJournal

data MsgStorePath :: MSType -> Type where
  MSPMemory :: Maybe FilePath -> MsgStorePath 'MSMemory
  MSPJournal :: FilePath -> MsgStorePath 'MSJournal

data AMsgStorePath = forall s. AMSP (SMSType s) (MsgStorePath s)
