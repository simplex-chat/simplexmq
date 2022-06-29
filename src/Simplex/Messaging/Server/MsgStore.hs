{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.MsgStore where

import Control.Applicative ((<|>))
import qualified Data.ByteString.Char8 as B
import Data.Int (Int64)
import Data.Time.Clock.System (SystemTime)
import Numeric.Natural
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (MsgBody, MsgFlags, MsgId, RecipientId, noMsgFlags)

data Message = Message
  { msgId :: MsgId,
    ts :: SystemTime,
    msgFlags :: MsgFlags,
    msgBody :: MsgBody
  }

instance StrEncoding Message where
  strEncode Message {msgId, ts, msgFlags, msgBody} =
    B.unwords
      [ strEncode msgId,
        strEncode ts,
        "flags=" <> strEncode msgFlags,
        strEncode msgBody
      ]
  strP = do
    msgId <- strP_
    ts <- strP_
    msgFlags <- ("flags=" *> strP_) <|> pure noMsgFlags
    msgBody <- strP
    pure Message {msgId, ts, msgFlags, msgBody}

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
