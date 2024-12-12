{-# LANGUAGE CPP #-}

module Simplex.Messaging.Agent.Store.DB
  ( Connection,
    open,
    close,
    execute,
    execute_,
    executeMany,
    query,
    query_,
    executeNamed,
    queryNamed,
  )
where

#if defined(dbPostgres)
import Control.Monad (void)
import qualified Database.PostgreSQL.Simple as Postgres
#else
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as SQLiteDB
import qualified Database.SQLite.Simple as SQLite
import Database.SQLite.Simple (NamedParam, FromRow)
#endif

#if defined(dbPostgres)
type Connection = Postgres.Connection
#else
type Connection = SQLiteDB.Connection
#endif

#if defined(dbPostgres)
type Query = Postgres.Query
#else
type Query = SQLite.Query
#endif

-- TODO [postgres] cleanup
#if defined(dbPostgres)
open :: Postgres.ConnectInfo -> IO Connection
open = Postgres.connect
#else
open :: String -> IO Connection
open = SQLiteDB.open
#endif

close :: Connection -> IO ()
#if defined(dbPostgres)
close = Postgres.close
#else
close = SQLiteDB.close
#endif

#if defined(dbPostgres)
execute :: Postgres.ToRow q => Connection -> Query -> q -> IO ()
execute db q qs = void $ Postgres.execute db q qs
#else
execute :: SQLite.ToRow q => Connection -> Query -> q -> IO ()
execute = SQLiteDB.execute
#endif
{-# INLINE execute #-}

execute_ :: Connection -> Query -> IO ()
#if defined(dbPostgres)
execute_ db q = void $ Postgres.execute_ db q
#else
execute_ = SQLiteDB.execute_
#endif
{-# INLINE execute_ #-}

#if defined(dbPostgres)
executeMany :: Postgres.ToRow q => Connection -> Query -> [q] -> IO ()
executeMany db q qs = void $ Postgres.executeMany db q qs
#else
executeMany :: SQLite.ToRow q => Connection -> Query -> [q] -> IO ()
executeMany = SQLiteDB.executeMany
#endif
{-# INLINE executeMany #-}

#if defined(dbPostgres)
query :: (Postgres.ToRow q, Postgres.FromRow r) => Connection -> Query -> q -> IO [r]
query = Postgres.query
#else
query :: (SQLite.ToRow q, SQLite.FromRow r) => Connection -> Query -> q -> IO [r]
query = SQLiteDB.query
#endif
{-# INLINE query #-}

#if defined(dbPostgres)
query_ :: Postgres.FromRow r => Connection -> Query -> IO [r]
query_ = Postgres.query_
#else
query_ :: SQLite.FromRow r => Connection -> Query -> IO [r]
query_ = SQLiteDB.query_
#endif
{-# INLINE query_ #-}

-- TODO [postgres] change queries - postgres doesn't support
#if defined(dbPostgres)
executeNamed :: IO ()
executeNamed = undefined
#else
executeNamed :: Connection -> Query -> [NamedParam] -> IO ()
executeNamed = SQLiteDB.executeNamed
#endif
{-# INLINE executeNamed #-}

-- TODO [postgres] change queries - postgres doesn't support
#if defined(dbPostgres)
queryNamed :: IO ()
queryNamed = undefined
#else
queryNamed :: FromRow r => Connection -> Query -> [NamedParam] -> IO [r]
queryNamed = SQLiteDB.queryNamed
#endif
{-# INLINE queryNamed #-}
