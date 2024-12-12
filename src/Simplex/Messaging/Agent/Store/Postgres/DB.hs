module Simplex.Messaging.Agent.Store.Postgres.DB
  ( PSQL.Connection,
    PSQL.connect,
    PSQL.close,
    execute,
    execute_,
    executeMany,
    PSQL.query,
    PSQL.query_,
  )
where

import Control.Monad (void)
import qualified Database.PostgreSQL.Simple as PSQL

execute :: PSQL.ToRow q => PSQL.Connection -> PSQL.Query -> q -> IO ()
execute db q qs = void $ PSQL.execute db q qs
{-# INLINE execute #-}

execute_ :: PSQL.Connection -> PSQL.Query -> IO ()
execute_ db q = void $ PSQL.execute_ db q
{-# INLINE execute_ #-}

executeMany :: PSQL.ToRow q => PSQL.Connection -> PSQL.Query -> [q] -> IO ()
executeMany db q qs = void $ PSQL.executeMany db q qs
{-# INLINE executeMany #-}
