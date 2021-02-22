{-# LANGUAGE DeriveAnyClass #-}

module Simplex.Messaging.Agent.Types.ErrorTypes where

import Numeric.Natural
import Simplex.Messaging.Agent.Types.ConnTypes (ConnType)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Types (ErrorType)
import UnliftIO.Exception

data AgentErrorType
  = UNKNOWN
  | PROHIBITED
  | SYNTAX Int
  | BROKER Natural
  | SMP ErrorType
  | CRYPTO C.CryptoError
  | SIZE
  | STORE StoreError
  | INTERNAL -- etc. TODO SYNTAX Natural
  deriving (Eq, Show, Exception)

data StoreError
  = SEInternal
  | SENotFound
  | SEBadConn
  | SEBadConnType ConnType
  | SEBadQueueStatus
  | SEBadQueueDirection
  | SENotImplemented -- TODO remove
  deriving (Eq, Show, Exception)
