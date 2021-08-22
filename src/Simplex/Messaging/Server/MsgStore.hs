{-# LANGUAGE FunctionalDependencies #-}

module Simplex.Messaging.Server.MsgStore where

import Data.Time.Clock
import Numeric.Natural
import Simplex.Messaging.Protocol (Encoded, MsgBody, RecipientId)

data Message = Message
  { msgId :: Encoded,
    ts :: UTCTime,
    msgBody :: MsgBody
  }

class MonadMsgStore s q m | s -> q where
  getMsgQueue :: s -> RecipientId -> Natural -> m q
  delMsgQueue :: s -> RecipientId -> m ()

class MonadMsgQueue q m where
  isFull :: q -> m Bool
  writeMsg :: q -> Message -> m () -- non blocking
  tryPeekMsg :: q -> m (Maybe Message) -- non blocking
  peekMsg :: q -> m Message -- blocking
  tryDelPeekMsg :: q -> m (Maybe Message) -- atomic delete (== read) last and peek next message, if available
