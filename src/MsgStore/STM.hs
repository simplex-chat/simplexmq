{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module MsgStore.STM where

import Control.Monad.IO.Unlift
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import MsgStore
import Transmission
import UnliftIO.STM

newtype MsgQueue = MsgQueue {msgQueue :: TQueue Message}

newtype MsgStoreData = MsgStoreData {messages :: Map RecipientId MsgQueue}

type STMMsgStore = TVar MsgStoreData

newMsgStore :: STM STMMsgStore
newMsgStore = newTVar $ MsgStoreData M.empty

instance MonadUnliftIO m => MonadMsgStore STMMsgStore MsgQueue m where
  getMsgQueue :: STMMsgStore -> RecipientId -> m MsgQueue
  getMsgQueue store rId = atomically $ do
    m <- messages <$> readTVar store
    maybe (newQ m) return $ M.lookup rId m
    where
      newQ m' = do
        q <- MsgQueue <$> newTQueue
        writeTVar store . MsgStoreData $ M.insert rId q m'
        return q

  delMsgQueue :: STMMsgStore -> RecipientId -> m ()
  delMsgQueue store rId = atomically $ do
    m <- messages <$> readTVar store
    writeTVar store . MsgStoreData $ M.delete rId m

instance MonadUnliftIO m => MonadMsgQueue MsgQueue m where
  writeMsg :: MsgQueue -> Message -> m ()
  writeMsg (MsgQueue q) msg = atomically $ writeTQueue q msg

  tryPeekMsg :: MsgQueue -> m (Maybe Message)
  tryPeekMsg = atomically . tryPeekTQueue . msgQueue

  peekMsg :: MsgQueue -> m Message
  peekMsg = atomically . peekTQueue . msgQueue

  -- atomic delete (== read) last and peek next message if available
  tryDelPeekMsg :: MsgQueue -> m (Maybe Message)
  tryDelPeekMsg (MsgQueue q) =
    atomically $
      tryReadTQueue q >> tryPeekTQueue q
