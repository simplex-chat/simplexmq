{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE StrictData #-}

module Simplex.Messaging.Agent.Store.SQLite.DB
  ( Connection (..),
    open,
    close,
    execute,
    execute_,
    executeNamed,
    query,
    query_,
    queryNamed,
  )
where

import Control.Concurrent.STM
import Control.Monad (when)
import Data.Int (Int64)
import Database.SQLite.Simple (FromRow, NamedParam, Query, ToRow)
import qualified Database.SQLite.Simple as SQL
import Data.Time (diffUTCTime, getCurrentTime)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (diffToMilliseconds)

data Connection = Connection
  { conn :: SQL.Connection,
    slow :: TMap Query Int64
  }

timeIt :: TMap Query Int64 -> Query -> IO a -> IO a
timeIt slow sql a = do
  t <- getCurrentTime
  r <- a
  t' <- getCurrentTime
  let diff = diffToMilliseconds $ diffUTCTime t' t
      update = Just . maybe diff (max diff)
  atomically $ when (diff > 100) $ TM.alter update sql slow
  pure r

open :: String -> IO Connection
open f = do
  conn <- SQL.open f
  slow <- atomically $ TM.empty
  pure Connection {conn, slow}

close :: Connection -> IO ()
close = SQL.close . conn

execute :: ToRow q => Connection -> Query -> q -> IO ()
execute Connection {conn, slow} sql = timeIt slow sql . SQL.execute conn sql
{-# INLINE execute #-}

execute_ :: Connection -> Query -> IO ()
execute_ Connection {conn, slow} sql = timeIt slow sql $ SQL.execute_ conn sql
{-# INLINE execute_ #-}

executeNamed :: Connection -> Query -> [NamedParam] -> IO ()
executeNamed Connection {conn, slow} sql = timeIt slow sql . SQL.executeNamed conn sql
{-# INLINE executeNamed #-}

query :: (ToRow q, FromRow r) => Connection -> Query -> q -> IO [r]
query Connection {conn, slow} sql = timeIt slow sql . SQL.query conn sql
{-# INLINE query #-}

query_ :: FromRow r => Connection -> Query -> IO [r]
query_ Connection {conn, slow} sql = timeIt slow sql $ SQL.query_ conn sql
{-# INLINE query_ #-}

queryNamed :: FromRow r => Connection -> Query -> [NamedParam] -> IO [r]
queryNamed Connection {conn, slow} sql = timeIt slow sql . SQL.queryNamed conn sql
{-# INLINE queryNamed #-}
