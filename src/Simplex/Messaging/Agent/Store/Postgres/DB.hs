{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.Postgres.DB
  ( BoolInt (..),
    PSQL.Connection,
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
import Database.PostgreSQL.Simple.FromField (FromField (..))
import Database.PostgreSQL.Simple.ToField (ToField (..))

newtype BoolInt v = BI {unBI :: Bool}

instance FromField (BoolInt v) where
  fromField field mData = do
    b :: Int <- fromField field mData
    pure $ BI (b /= 0)
  {-# INLINE fromField #-}

instance ToField (BoolInt v) where
  toField (BI b) = toField ((if b then 1 else 0) :: Int)
  {-# INLINE toField #-}

execute :: PSQL.ToRow q => PSQL.Connection -> PSQL.Query -> q -> IO ()
execute db q qs = void $ PSQL.execute db q qs
{-# INLINE execute #-}

execute_ :: PSQL.Connection -> PSQL.Query -> IO ()
execute_ db q = void $ PSQL.execute_ db q
{-# INLINE execute_ #-}

executeMany :: PSQL.ToRow q => PSQL.Connection -> PSQL.Query -> [q] -> IO ()
executeMany db q qs = void $ PSQL.executeMany db q qs
{-# INLINE executeMany #-}
