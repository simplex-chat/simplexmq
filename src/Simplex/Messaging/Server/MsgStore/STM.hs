{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Server.MsgStore.STM
  ( STMMsgStore,
    MsgQueue,
    newMsgStore,
  )
where

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

data MsgQueue = MsgQueue {msgQueue :: TBQueue Message, quota :: Natural, lastMsg :: TVar (Maybe Message)}

type STMMsgStore = TMap RecipientId MsgQueue

newMsgStore :: STM STMMsgStore
newMsgStore = TM.empty

instance MonadMsgStore STMMsgStore MsgQueue STM where
  getMsgQueue :: STMMsgStore -> RecipientId -> Natural -> STM MsgQueue
  getMsgQueue st rId quota = maybe newQ pure =<< TM.lookup rId st
    where
      newQ = do
        msgQueue <- newTBQueue (quota + 1)
        lastMsg <- newTVar Nothing
        let q = MsgQueue {msgQueue, quota, lastMsg}
        TM.insert rId q st
        pure q

  delMsgQueue :: STMMsgStore -> RecipientId -> STM ()
  delMsgQueue st rId = TM.delete rId st

  flushMsgQueue :: STMMsgStore -> RecipientId -> STM [Message]
  flushMsgQueue st rId = TM.lookupDelete rId st >>= maybe (pure []) (flushTBQueue . msgQueue)

instance MonadMsgQueue MsgQueue STM where
  isFull :: MsgQueue -> STM Bool
  isFull MsgQueue {msgQueue, quota} = (quota <=) <$> lengthTBQueue msgQueue

  writeMsg :: MsgQueue -> Message -> STM ()
  writeMsg MsgQueue {msgQueue, lastMsg} msg = do
    writeTBQueue msgQueue msg
    writeTVar lastMsg $ Just msg

  lastQueueMsg :: MsgQueue -> STM (Maybe Message)
  lastQueueMsg MsgQueue {msgQueue, lastMsg} = do
    len <- lengthTBQueue msgQueue
    if len == 0 then pure Nothing else readTVar lastMsg

  tryPeekMsg :: MsgQueue -> STM (Maybe Message)
  tryPeekMsg = tryPeekTBQueue . msgQueue

  peekMsg :: MsgQueue -> STM Message
  peekMsg = peekTBQueue . msgQueue

  tryDelMsg :: MsgQueue -> MsgId -> STM Bool
  tryDelMsg MsgQueue {msgQueue = q} msgId' =
    tryPeekTBQueue q >>= \case
      Just msg
        | msgId msg == msgId' || B.null msgId' -> tryReadTBQueue q $> True
        | otherwise -> pure False
      _ -> pure False

  -- atomic delete (== read) last and peek next message if available
  tryDelPeekMsg :: MsgQueue -> MsgId -> STM (Bool, Maybe Message)
  tryDelPeekMsg MsgQueue {msgQueue = q} msgId' =
    tryPeekTBQueue q >>= \case
      msg_@(Just msg)
        | msgId msg == msgId' || B.null msgId' -> (True,) <$> (tryReadTBQueue q >> tryPeekTBQueue q)
        | otherwise -> pure (False, msg_)
      _ -> pure (False, Nothing)

  deleteExpiredMsgs :: MsgQueue -> Int64 -> STM ()
  deleteExpiredMsgs MsgQueue {msgQueue = q} old = loop
    where
      loop = tryPeekTBQueue q >>= mapM_ delOldMsg
      delOldMsg = \case
        Message {msgTs} ->
          when (systemSeconds msgTs < old) $
            tryReadTBQueue q >> loop
        _ -> pure ()
