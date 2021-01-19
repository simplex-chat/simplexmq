{-# LANGUAGE DeriveAnyClass #-}

module Simplex.Messaging.Agent.Store.Types where

import Control.Exception

data StoreError
  = SEInternal
  | SENotFound
  | SEBadConn
  | SEBadQueueStatus
  | SEBadQueueDirection
  | SENotImplemented -- TODO remove
  deriving (Eq, Show, Exception)
