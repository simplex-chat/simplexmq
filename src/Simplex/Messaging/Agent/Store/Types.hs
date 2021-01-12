{-# LANGUAGE DeriveAnyClass #-}

module Simplex.Messaging.Agent.Store.Types where

import Control.Exception

data ConnType = CSend | CReceive | CDuplex deriving (Eq, Show)

data StoreError
  = SEInternal
  | SENotFound
  | SEBadConn
  | SEBadConnType ConnType
  | SEBadQueueStatus
  deriving (Eq, Show, Exception)
