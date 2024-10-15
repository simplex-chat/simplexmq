{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilyDependencies #-}

module Simplex.Messaging.Server.MsgStore.Types where

import Data.Int (Int64)
import Data.Kind
import Data.Set (Set)
import Simplex.Messaging.Protocol (Message (..), MsgId, RecipientId)

class MsgStoreClass s where
  type MsgQueue s = q | q -> s
  getMsgQueueIds :: s -> IO (Set RecipientId)
  getMsgQueue :: s -> RecipientId -> Int -> IO (MsgQueue s)
  delMsgQueue :: s -> RecipientId -> IO ()
  delMsgQueueSize :: s -> RecipientId -> IO Int
  writeMsg :: MsgQueue s -> Message -> IO (Maybe (Message, Bool))
  tryPeekMsg :: MsgQueue s -> IO (Maybe Message)
  tryDelMsg :: MsgQueue s -> MsgId -> IO (Maybe Message)
  tryDelPeekMsg :: MsgQueue s -> MsgId -> IO (Maybe Message, Maybe Message)
  deleteExpiredMsgs :: MsgQueue s -> Int64 -> IO Int
  getQueueSize :: MsgQueue s -> IO Int

data MSType = MSMemory | MSJournal

data SMSType :: MSType -> Type where
  SMSMemory :: SMSType 'MSMemory
  SMSJournal :: SMSType 'MSJournal

data MsgStorePath :: MSType -> Type where
  MSPMemory :: Maybe FilePath -> MsgStorePath 'MSMemory
  MSPJournal :: FilePath -> MsgStorePath 'MSJournal

data AMsgStorePath = forall s. AMSP (SMSType s) (MsgStorePath s)
