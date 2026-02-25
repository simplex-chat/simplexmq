module Simplex.Messaging.Server.QueueStore.Postgres.Config
  ( PostgresStoreCfg (..),
  ) where

import Data.Int (Int64)
import Simplex.Messaging.Agent.Store.Postgres.Options (DBOpts)
import Simplex.Messaging.Agent.Store.Shared (MigrationConfirmation)

data PostgresStoreCfg = PostgresStoreCfg
  { dbOpts :: DBOpts,
    dbStoreLogPath :: Maybe FilePath,
    confirmMigrations :: MigrationConfirmation,
    deletedTTL :: Int64
  }
