{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.MsgStore where

import Data.Int (Int64)
import Numeric.Natural
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (Message (..), MsgId, RecipientId)

data MsgLogRecord = MsgLogRecord RecipientId Message

instance StrEncoding MsgLogRecord where
  strEncode (MsgLogRecord rId msg) = strEncode (rId, msg)
  strP = MsgLogRecord <$> strP_ <*> strP

class MonadMsgStore s q m | s -> q where
  getMsgQueue :: s -> RecipientId -> Natural -> m q
  delMsgQueue :: s -> RecipientId -> m ()
  flushMsgQueue :: s -> RecipientId -> m [Message]

class MonadMsgQueue q m where
  isFull :: q -> m Bool
  writeMsg :: q -> Message -> m () -- non blocking
  tryPeekMsg :: q -> m (Maybe Message) -- non blocking
  peekMsg :: q -> m Message -- blocking
  tryDelMsg :: q -> MsgId -> m Bool -- non blocking
  tryDelPeekMsg :: q -> MsgId -> m (Bool, Maybe Message) -- atomic delete (== read) last and peek next message, if available
  deleteExpiredMsgs :: q -> Int64 -> m ()
