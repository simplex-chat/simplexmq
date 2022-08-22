{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Server.MsgStore.STM where

import Control.Concurrent.STM.TBQueue (flushTBQueue)
import Control.Monad (when)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Int (Int64)
import Data.Time.Clock.System (SystemTime (systemSeconds))
import Numeric.Natural
import Simplex.Messaging.Protocol (Message (..), MsgId, RecipientId)
import Simplex.Messaging.Server.MsgStore
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import UnliftIO.STM

newtype MsgQueue = MsgQueue {msgQueue :: TBQueue Message}

type STMMsgStore = TMap RecipientId MsgQueue

newMsgStore :: STM STMMsgStore
newMsgStore = TM.empty

instance MonadMsgStore STMMsgStore MsgQueue STM where
  getMsgQueue :: STMMsgStore -> RecipientId -> Natural -> STM MsgQueue
  getMsgQueue st rId quota = maybe newQ pure =<< TM.lookup rId st
    where
      newQ = do
        q <- MsgQueue <$> newTBQueue quota
        TM.insert rId q st
        return q

  delMsgQueue :: STMMsgStore -> RecipientId -> STM ()
  delMsgQueue st rId = TM.delete rId st

  flushMsgQueue :: STMMsgStore -> RecipientId -> STM [Message]
  flushMsgQueue st rId = TM.lookup rId st >>= maybe (pure []) (flushTBQueue . msgQueue)

instance MonadMsgQueue MsgQueue STM where
  isFull :: MsgQueue -> STM Bool
  isFull = isFullTBQueue . msgQueue

  queueLength :: MsgQueue -> STM Natural
  queueLength = lengthTBQueue . msgQueue

  writeMsg :: MsgQueue -> Message -> STM ()
  writeMsg = writeTBQueue . msgQueue

  tryPeekMsg :: MsgQueue -> STM (Maybe Message)
  tryPeekMsg = tryPeekTBQueue . msgQueue

  peekMsg :: MsgQueue -> STM Message
  peekMsg = peekTBQueue . msgQueue

  tryDelMsg :: MsgQueue -> MsgId -> STM Bool
  tryDelMsg (MsgQueue q) msgId' =
    tryPeekTBQueue q >>= \case
      Just Message {msgId}
        | msgId == msgId' || B.null msgId' -> tryReadTBQueue q $> True
        | otherwise -> pure False
      _ -> pure False

  -- atomic delete (== read) last and peek next message if available
  tryDelPeekMsg :: MsgQueue -> MsgId -> STM (Bool, Maybe Message)
  tryDelPeekMsg (MsgQueue q) msgId' =
    tryPeekTBQueue q >>= \case
      msg_@(Just Message {msgId})
        | msgId == msgId' || B.null msgId' -> (True,) <$> (tryReadTBQueue q >> tryPeekTBQueue q)
        | otherwise -> pure (False, msg_)
      _ -> pure (False, Nothing)

  deleteExpiredMsgs :: MsgQueue -> Int64 -> STM ()
  deleteExpiredMsgs (MsgQueue q) old = loop
    where
      loop = tryPeekTBQueue q >>= mapM_ delOldMsg
      delOldMsg Message {msgTs} =
        when (systemSeconds msgTs < old) $
          tryReadTBQueue q >> loop
