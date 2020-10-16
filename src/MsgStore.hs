{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE NamedFieldPuns #-}

module MsgStore where

import Control.Monad.IO.Class
import Data.Time.Clock
import Transmission

data Message = Message
  { msgId :: Encoded,
    ts :: UTCTime,
    msgBody :: MsgBody
  }

class MonadMsgStore s q m | s -> q where
  getMsgQueue :: s -> RecipientId -> m q
  delMsgQueue :: s -> RecipientId -> m ()

class MonadMsgQueue q m where
  writeMsg :: q -> Message -> m () -- non blocking
  tryPeekMsg :: q -> m (Maybe Message) -- non blocking
  peekMsg :: q -> m Message -- blocking
  tryDelPeekMsg :: q -> m (Maybe Message) -- atomic delete (== read) last and peek next message, if available

newMessage :: MonadIO m => MsgBody -> m Message
newMessage msgBody = do
  ts <- liftIO getCurrentTime
  return
    Message
      { msgId = "1",
        ts,
        msgBody
      }
