{-# LANGUAGE FunctionalDependencies #-}

module Simplex.Messaging.Server.MsgStore where

import Data.Time.Clock
import qualified Simplex.Messaging.Protocol as SMP

data Message = Message
  { msgId :: SMP.Encoded,
    ts :: UTCTime,
    msgBody :: SMP.MsgBody
  }

class MonadMsgStore s q m | s -> q where
  getMsgQueue :: s -> SMP.RecipientId -> m q
  delMsgQueue :: s -> SMP.RecipientId -> m ()

class MonadMsgQueue q m where
  writeMsg :: q -> Message -> m () -- non blocking
  tryPeekMsg :: q -> m (Maybe Message) -- non blocking
  peekMsg :: q -> m Message -- blocking
  tryDelPeekMsg :: q -> m (Maybe Message) -- atomic delete (== read) last and peek next message, if available
