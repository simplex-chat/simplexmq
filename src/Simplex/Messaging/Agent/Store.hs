{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Store
  ( ReceiveQueue (..),
    SendQueue (..),
    ConnType (..),
    Connection (..),
    SConnType (..),
    SomeConn (..),
    StoreError (..),
    MonadAgentStore (..),
  )
where

import Control.Exception (Exception)
import Data.Kind (Type)
import Data.Type.Equality
import Simplex.Messaging.Agent.Transmission
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Types (RecipientPrivateKey, SenderPrivateKey, SenderPublicKey)

data ReceiveQueue = ReceiveQueue
  { server :: SMPServer,
    rcvId :: SMP.RecipientId,
    connAlias :: ConnAlias,
    rcvPrivateKey :: RecipientPrivateKey,
    sndId :: Maybe SMP.SenderId,
    sndKey :: Maybe SenderPublicKey,
    decryptKey :: DecryptionKey,
    verifyKey :: Maybe VerificationKey,
    status :: QueueStatus
  }
  deriving (Eq, Show)

data SendQueue = SendQueue
  { server :: SMPServer,
    sndId :: SMP.SenderId,
    connAlias :: ConnAlias,
    sndPrivateKey :: SenderPrivateKey,
    encryptKey :: EncryptionKey,
    signKey :: SignatureKey,
    status :: QueueStatus
  }
  deriving (Eq, Show)

data ConnType = CSend | CReceive | CDuplex deriving (Eq, Show)

data Connection (d :: ConnType) where
  ReceiveConnection :: ConnAlias -> ReceiveQueue -> Connection CReceive
  SendConnection :: ConnAlias -> SendQueue -> Connection CSend
  DuplexConnection :: ConnAlias -> ReceiveQueue -> SendQueue -> Connection CDuplex

deriving instance Show (Connection d)

deriving instance Eq (Connection d)

data SConnType :: ConnType -> Type where
  SCReceive :: SConnType CReceive
  SCSend :: SConnType CSend
  SCDuplex :: SConnType CDuplex

deriving instance Eq (SConnType d)

deriving instance Show (SConnType d)

instance TestEquality SConnType where
  testEquality SCReceive SCReceive = Just Refl
  testEquality SCSend SCSend = Just Refl
  testEquality SCDuplex SCDuplex = Just Refl
  testEquality _ _ = Nothing

data SomeConn where
  SomeConn :: SConnType d -> Connection d -> SomeConn

instance Eq SomeConn where
  SomeConn d c == SomeConn d' c' = case testEquality d d' of
    Just Refl -> c == c'
    _ -> False

deriving instance Show SomeConn

data StoreError
  = SEInternal
  | SENotFound
  | SEBadConn
  | SEBadConnType ConnType
  | SEBadQueueStatus
  | SEBadQueueDirection
  | SENotImplemented -- TODO remove
  deriving (Eq, Show, Exception)

class Monad m => MonadAgentStore s m where
  createRcvConn :: s -> ReceiveQueue -> m ()
  createSndConn :: s -> SendQueue -> m ()
  getConn :: s -> ConnAlias -> m SomeConn
  getRcvQueue :: s -> SMPServer -> SMP.RecipientId -> m ReceiveQueue
  deleteConn :: s -> ConnAlias -> m ()
  upgradeRcvConnToDuplex :: s -> ConnAlias -> SendQueue -> m ()
  upgradeSndConnToDuplex :: s -> ConnAlias -> ReceiveQueue -> m ()
  removeSndAuth :: s -> ConnAlias -> m ()
  setRcvQueueStatus :: s -> ReceiveQueue -> QueueStatus -> m ()
  setSndQueueStatus :: s -> SendQueue -> QueueStatus -> m ()

  -- -- ? make data kind out of AMessage so that we can limit parameter to AMessage A_MSG?
  -- -- ? or just throw error / silently ignore other AMessage types?
  -- createRcvMsg :: s -> ConnAlias -> AMessage -> m ()
  -- createSndMsg :: s -> ConnAlias -> AMessage -> m ()

  -- -- TODO this will be removed
  -- createMsg :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> AMessage -> m ()

-- getLastMsg :: s -> ConnAlias -> QueueDirection -> m MessageDelivery
-- getMsg :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> m MessageDelivery
-- setMsgStatus :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> m ()
-- deleteMsg :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> m ()
