{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.MsgStore where

import Control.Applicative ((<|>))
import Data.Functor (($>))
import Data.Int (Int64)
import Numeric.Natural
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (Message (..), MsgId, RecipientId)

data MsgLogRecord = MsgLogRecord MLRVersion RecipientId Message

data MLRVersion = MLRv1 | MLRv3

instance StrEncoding MLRVersion where
  strEncode = \case
    MLRv3 -> "v3 "
    MLRv1 -> ""
  strP = "v3 " $> MLRv3 <|> pure MLRv1

data MsgLogRecordV1 = MsgLogRecordV1 RecipientId Message

instance StrEncoding MsgLogRecord where
  strEncode (MsgLogRecord v rId msg) = strEncode v <> strEncode (rId, msg)
  strP = MsgLogRecord <$> strP <*> strP_ <*> strP

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
