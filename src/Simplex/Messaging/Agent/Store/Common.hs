{-# LANGUAGE CPP #-}

module Simplex.Messaging.Agent.Store.Common
  ( DBStore,
    withConnection,
    withConnection',
    withTransaction,
    withTransaction',
    withTransactionPriority,
  )
where

import Simplex.Messaging.Agent.Store.DB as DB
#if defined(dbPostgres)
import qualified Database.PostgreSQL.Simple as Postgres
import qualified Simplex.Messaging.Agent.Store.Postgres.Common as PostgresCommon
#else
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as SQLiteDB
import qualified Simplex.Messaging.Agent.Store.SQLite.Common as SQLiteCommon
import qualified Database.SQLite.Simple as SQLite
#endif

#if defined(dbPostgres)
type DBStore = PostgresCommon.PostgresStore
#else
type DBStore = SQLiteCommon.SQLiteStore
#endif

withConnection :: DBStore -> (DB.Connection -> IO a) -> IO a
#if defined(dbPostgres)
withConnection = PostgresCommon.withConnection
#else
withConnection = SQLiteCommon.withConnection
#endif
{-# INLINE withConnection #-}

withConnection' :: DBStore -> (DB.Connection -> IO a) -> IO a
#if defined(dbPostgres)
withConnection' = PostgresCommon.withConnection'
#else
withConnection' = SQLiteCommon.withConnection'
#endif
{-# INLINE withConnection' #-}

withTransaction' :: DBStore -> (DB.Connection -> IO a) -> IO a
#if defined(dbPostgres)
withTransaction' = PostgresCommon.withTransaction'
#else
withTransaction' = SQLiteCommon.withTransaction'
#endif
{-# INLINE withTransaction' #-}

withTransaction :: DBStore -> (DB.Connection -> IO a) -> IO a
#if defined(dbPostgres)
withTransaction = PostgresCommon.withTransaction
#else
withTransaction = SQLiteCommon.withTransaction
#endif
{-# INLINE withTransaction #-}

withTransactionPriority :: DBStore -> Bool -> (DB.Connection -> IO a) -> IO a
#if defined(dbPostgres)
withTransactionPriority = PostgresCommon.withTransactionPriority
#else
withTransactionPriority = SQLiteCommon.withTransactionPriority
#endif
{-# INLINE withTransactionPriority #-}
