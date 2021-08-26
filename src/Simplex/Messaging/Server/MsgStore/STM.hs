{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Simplex.Messaging.Server.MsgStore.STM where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Numeric.Natural
import Simplex.Messaging.Protocol (RecipientId)
import Simplex.Messaging.Server.MsgStore
import UnliftIO.STM

newtype MsgQueue = MsgQueue {msgQueue :: TBQueue Message}

newtype MsgStoreData = MsgStoreData {messages :: Map RecipientId MsgQueue}

type STMMsgStore = TVar MsgStoreData

newMsgStore :: STM STMMsgStore
newMsgStore = newTVar $ MsgStoreData M.empty

instance MonadMsgStore STMMsgStore MsgQueue STM where
  getMsgQueue :: STMMsgStore -> RecipientId -> Natural -> STM MsgQueue
  getMsgQueue store rId quota = do
    m <- messages <$> readTVar store
    maybe (newQ m) return $ M.lookup rId m
    where
      newQ m' = do
        q <- MsgQueue <$> newTBQueue quota
        writeTVar store . MsgStoreData $ M.insert rId q m'
        return q

  delMsgQueue :: STMMsgStore -> RecipientId -> STM ()
  delMsgQueue store rId =
    modifyTVar store $ MsgStoreData . M.delete rId . messages

instance MonadMsgQueue MsgQueue STM where
  isFull :: MsgQueue -> STM Bool
  isFull = isFullTBQueue . msgQueue

  writeMsg :: MsgQueue -> Message -> STM ()
  writeMsg = writeTBQueue . msgQueue

  tryPeekMsg :: MsgQueue -> STM (Maybe Message)
  tryPeekMsg = tryPeekTBQueue . msgQueue

  peekMsg :: MsgQueue -> STM Message
  peekMsg = peekTBQueue . msgQueue

  -- atomic delete (== read) last and peek next message if available
  tryDelPeekMsg :: MsgQueue -> STM (Maybe Message)
  tryDelPeekMsg (MsgQueue q) = tryReadTBQueue q >> tryPeekTBQueue q
