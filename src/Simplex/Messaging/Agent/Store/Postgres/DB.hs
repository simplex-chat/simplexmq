module Simplex.Messaging.Agent.Store.Postgres.DB
  ( PSQL.Connection,
    PSQL.connect,
    PSQL.close,
    Simplex.Messaging.Agent.Store.Postgres.DB.execute,
    Simplex.Messaging.Agent.Store.Postgres.DB.execute_,
    Simplex.Messaging.Agent.Store.Postgres.DB.executeMany,
    PSQL.query,
    PSQL.query_,
  )
where

import Control.Monad (void)
import Database.PostgreSQL.Simple as PSQL

execute :: PSQL.ToRow q => Connection -> Query -> q -> IO ()
execute db q qs = void $ PSQL.execute db q qs
{-# INLINE execute #-}

execute_ :: Connection -> Query -> IO ()
execute_ db q = void $ PSQL.execute_ db q
{-# INLINE execute_ #-}

executeMany :: PSQL.ToRow q => Connection -> Query -> [q] -> IO ()
executeMany db q qs = void $ PSQL.executeMany db q qs
{-# INLINE executeMany #-}
