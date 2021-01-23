{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Simplex.Messaging.Server.MsgStore.STM where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Simplex.Messaging.Types
import Simplex.Messaging.Server.MsgStore
import UnliftIO.STM

newtype MsgQueue = MsgQueue {msgQueue :: TQueue Message}

newtype MsgStoreData = MsgStoreData {messages :: Map RecipientId MsgQueue}

type STMMsgStore = TVar MsgStoreData

newMsgStore :: STM STMMsgStore
newMsgStore = newTVar $ MsgStoreData M.empty

instance MonadMsgStore STMMsgStore MsgQueue STM where
  getMsgQueue :: STMMsgStore -> RecipientId -> STM MsgQueue
  getMsgQueue store rId = do
    m <- messages <$> readTVar store
    maybe (newQ m) return $ M.lookup rId m
    where
      newQ m' = do
        q <- MsgQueue <$> newTQueue
        writeTVar store . MsgStoreData $ M.insert rId q m'
        return q

  delMsgQueue :: STMMsgStore -> RecipientId -> STM ()
  delMsgQueue store rId =
    modifyTVar store $ MsgStoreData . M.delete rId . messages

instance MonadMsgQueue MsgQueue STM where
  writeMsg :: MsgQueue -> Message -> STM ()
  writeMsg = writeTQueue . msgQueue

  tryPeekMsg :: MsgQueue -> STM (Maybe Message)
  tryPeekMsg = tryPeekTQueue . msgQueue

  peekMsg :: MsgQueue -> STM Message
  peekMsg = peekTQueue . msgQueue

  -- atomic delete (== read) last and peek next message if available
  tryDelPeekMsg :: MsgQueue -> STM (Maybe Message)
  tryDelPeekMsg (MsgQueue q) = tryReadTQueue q >> tryPeekTQueue q
