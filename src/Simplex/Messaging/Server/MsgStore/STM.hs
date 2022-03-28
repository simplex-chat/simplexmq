{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Simplex.Messaging.Server.MsgStore.STM where

import Numeric.Natural
import Simplex.Messaging.Protocol (RecipientId)
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
