{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.MsgStore where

import Control.Applicative ((<|>))
import Data.Int (Int64)
import Numeric.Natural
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (Message (..), MsgId, RcvMessage (..), RecipientId)

data MsgLogRecord = MLRv3 RecipientId Message | MLRv1 RecipientId RcvMessage

instance StrEncoding MsgLogRecord where
  strEncode = \case
    MLRv3 rId msg -> strEncode (Str "v3", rId, msg)
    MLRv1 rId msg -> strEncode (rId, msg)
  strP = "v3 " *> (MLRv3 <$> strP_ <*> strP) <|> MLRv1 <$> strP_ <*> strP

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
