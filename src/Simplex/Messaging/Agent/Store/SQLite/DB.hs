{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.Agent.Store.SQLite.DB
  ( Connection (..),
    SlowQueryStats (..),
    open,
    close,
    execute,
    execute_,
    executeNamed,
    executeMany,
    query,
    query_,
    queryNamed,
  )
where

import Control.Concurrent.STM
import Control.Monad (when)
import qualified Data.Aeson.TH as J
import Data.Int (Int64)
import Data.Time (diffUTCTime, getCurrentTime)
import Database.SQLite.Simple (FromRow, NamedParam, Query, ToRow)
import qualified Database.SQLite.Simple as SQL
import Simplex.Messaging.Parsers (defaultJSON)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (diffToMilliseconds)

data Connection = Connection
  { conn :: SQL.Connection,
    slow :: TMap Query SlowQueryStats
  }

data SlowQueryStats = SlowQueryStats
  { count :: Int64,
    timeMax :: Int64,
    timeAvg :: Int64
  }
  deriving (Show)

timeIt :: TMap Query SlowQueryStats -> Query -> IO a -> IO a
timeIt slow sql a = do
  t <- getCurrentTime
  r <- a
  t' <- getCurrentTime
  let diff = diffToMilliseconds $ diffUTCTime t' t
  atomically $ when (diff > 50) $ TM.alter (updateQueryStats diff) sql slow
  pure r
  where
    updateQueryStats :: Int64 -> Maybe SlowQueryStats -> Maybe SlowQueryStats
    updateQueryStats diff Nothing = Just $ SlowQueryStats 1 diff diff
    updateQueryStats diff (Just SlowQueryStats {count, timeMax, timeAvg}) =
      Just $
        SlowQueryStats
          { count = count + 1,
            timeMax = max timeMax diff,
            timeAvg = (timeAvg * count + diff) `div` (count + 1)
          }

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

executeMany :: ToRow q => Connection -> Query -> [q] -> IO ()
executeMany Connection {conn, slow} sql = timeIt slow sql . SQL.executeMany conn sql
{-# INLINE executeMany #-}

query :: (ToRow q, FromRow r) => Connection -> Query -> q -> IO [r]
query Connection {conn, slow} sql = timeIt slow sql . SQL.query conn sql
{-# INLINE query #-}

query_ :: FromRow r => Connection -> Query -> IO [r]
query_ Connection {conn, slow} sql = timeIt slow sql $ SQL.query_ conn sql
{-# INLINE query_ #-}

queryNamed :: FromRow r => Connection -> Query -> [NamedParam] -> IO [r]
queryNamed Connection {conn, slow} sql = timeIt slow sql . SQL.queryNamed conn sql
{-# INLINE queryNamed #-}

$(J.deriveJSON defaultJSON ''SlowQueryStats)
