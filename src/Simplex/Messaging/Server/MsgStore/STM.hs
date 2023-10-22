{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Server.MsgStore.STM
  ( STMMsgStore,
    MsgQueue (..),
    newMsgStore,
    getMsgQueue,
    delMsgQueue,
    flushMsgQueue,
    snapshotMsgQueue,
    writeMsg,
    tryPeekMsg,
    peekMsg,
    tryDelMsg,
    tryDelPeekMsg,
    deleteExpiredMsgs,
  )
where

import Control.Concurrent.STM.TQueue (flushTQueue)
import Control.Monad (when)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Int (Int64)
import Data.Time.Clock.System (SystemTime (systemSeconds))
import Simplex.Messaging.Protocol (Message (..), MsgId, RecipientId)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import UnliftIO.STM

data MsgQueue = MsgQueue
  { msgQueue :: TQueue Message,
    quota :: Int,
    canWrite :: TVar Bool,
    size :: TVar Int
  }

type STMMsgStore = TMap RecipientId MsgQueue

newMsgStore :: STM STMMsgStore
newMsgStore = TM.empty

getMsgQueue :: STMMsgStore -> RecipientId -> Int -> STM MsgQueue
getMsgQueue st rId quota = maybe newQ pure =<< TM.lookup rId st
  where
    newQ = do
      msgQueue <- newTQueue
      canWrite <- newTVar True
      size <- newTVar 0
      let q = MsgQueue {msgQueue, quota, canWrite, size}
      TM.insert rId q st
      pure q

delMsgQueue :: STMMsgStore -> RecipientId -> STM ()
delMsgQueue st rId = TM.delete rId st

flushMsgQueue :: STMMsgStore -> RecipientId -> STM [Message]
flushMsgQueue st rId = TM.lookupDelete rId st >>= maybe (pure []) (flushTQueue . msgQueue)

snapshotMsgQueue :: STMMsgStore -> RecipientId -> STM [Message]
snapshotMsgQueue st rId = TM.lookup rId st >>= maybe (pure []) (snapshotTQueue . msgQueue)
  where
    snapshotTQueue q = do
      msgs <- flushTQueue q
      mapM_ (writeTQueue q) msgs
      pure msgs

writeMsg :: MsgQueue -> Message -> STM (Maybe Message)
writeMsg MsgQueue {msgQueue = q, quota, canWrite, size} msg = do
  canWrt <- readTVar canWrite
  empty <- isEmptyTQueue q
  if canWrt || empty
    then do
      canWrt' <- (quota >) <$> readTVar size
      writeTVar canWrite $! canWrt'
      modifyTVar' size (+ 1)
      if canWrt'
        then writeTQueue q msg $> Just msg
        else writeTQueue q msgQuota $> Nothing
    else pure Nothing
  where
    msgQuota = MessageQuota {msgId = msgId msg, msgTs = msgTs msg}

tryPeekMsg :: MsgQueue -> STM (Maybe Message)
tryPeekMsg = tryPeekTQueue . msgQueue
{-# INLINE tryPeekMsg #-}

peekMsg :: MsgQueue -> STM Message
peekMsg = peekTQueue . msgQueue
{-# INLINE peekMsg #-}

tryDelMsg :: MsgQueue -> MsgId -> STM (Maybe Message)
tryDelMsg mq msgId' =
  tryPeekMsg mq >>= \case
    msg_@(Just msg)
      | msgId msg == msgId' || B.null msgId' -> tryDeleteMsg mq >> pure msg_
      | otherwise -> pure Nothing
    _ -> pure Nothing

-- atomic delete (== read) last and peek next message if available
tryDelPeekMsg :: MsgQueue -> MsgId -> STM (Maybe Message, Maybe Message)
tryDelPeekMsg mq msgId' =
  tryPeekMsg mq >>= \case
    msg_@(Just msg)
      | msgId msg == msgId' || B.null msgId' -> (msg_,) <$> (tryDeleteMsg mq >> tryPeekMsg mq)
      | otherwise -> pure (Nothing, msg_)
    _ -> pure (Nothing, Nothing)

deleteExpiredMsgs :: MsgQueue -> Int64 -> STM ()
deleteExpiredMsgs mq old = loop
  where
    loop = tryPeekMsg mq >>= mapM_ delOldMsg
    delOldMsg = \case
      Message {msgTs} ->
        when (systemSeconds msgTs < old) $
          tryDeleteMsg mq >> loop
      _ -> pure ()

tryDeleteMsg :: MsgQueue -> STM ()
tryDeleteMsg MsgQueue {msgQueue = q, size} =
  tryReadTQueue q >>= \case
    Just _ -> modifyTVar' size (subtract 1)
    _ -> pure ()
