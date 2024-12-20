{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.Agent.Store.SQLite.DB
  ( BoolInt (..),
    Binary (..),
    Connection (..),
    SlowQueryStats (..),
    open,
    close,
    execute,
    execute_,
    executeMany,
    query,
    query_,
  )
where

import Control.Concurrent.STM
import Control.Exception
import Control.Monad (when)
import qualified Data.Aeson.TH as J
import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import Data.Time (diffUTCTime, getCurrentTime)
import Database.SQLite.Simple (FromRow, Query, ToRow)
import qualified Database.SQLite.Simple as SQL
import Database.SQLite.Simple.FromField (FromField (..))
import Database.SQLite.Simple.ToField (ToField (..))
import Simplex.Messaging.Parsers (defaultJSON)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (diffToMilliseconds, tshow)

newtype BoolInt = BI {unBI :: Bool}
  deriving newtype (FromField, ToField)

newtype Binary = Binary {fromBinary :: ByteString}
  deriving newtype (FromField, ToField)

data Connection = Connection
  { conn :: SQL.Connection,
    slow :: TMap Query SlowQueryStats
  }

data SlowQueryStats = SlowQueryStats
  { count :: Int64,
    timeMax :: Int64,
    timeAvg :: Int64,
    errs :: Map Text Int
  }
  deriving (Show)

timeIt :: TMap Query SlowQueryStats -> Query -> IO a -> IO a
timeIt slow sql a = do
  t <- getCurrentTime
  r <-
    a `catch` \e -> do
      atomically $ TM.alter (Just . updateQueryErrors e) sql slow
      throwIO e
  t' <- getCurrentTime
  let diff = diffToMilliseconds $ diffUTCTime t' t
  when (diff > 1) $ atomically $ TM.alter (updateQueryStats diff) sql slow
  pure r
  where
    updateQueryErrors :: SomeException -> Maybe SlowQueryStats -> SlowQueryStats
    updateQueryErrors e Nothing = SlowQueryStats 0 0 0 $ M.singleton (tshow e) 1
    updateQueryErrors e (Just stats@SlowQueryStats {errs}) =
      stats {errs = M.alter (Just . maybe 1 (+ 1)) (tshow e) errs}
    updateQueryStats :: Int64 -> Maybe SlowQueryStats -> Maybe SlowQueryStats
    updateQueryStats diff Nothing = Just $ SlowQueryStats 1 diff diff M.empty
    updateQueryStats diff (Just SlowQueryStats {count, timeMax, timeAvg, errs}) =
      Just $
        SlowQueryStats
          { count = count + 1,
            timeMax = max timeMax diff,
            timeAvg = (timeAvg * count + diff) `div` (count + 1),
            errs
          }

open :: String -> IO Connection
open f = do
  conn <- SQL.open f
  slow <- TM.emptyIO
  pure Connection {conn, slow}

close :: Connection -> IO ()
close = SQL.close . conn

execute :: ToRow q => Connection -> Query -> q -> IO ()
execute Connection {conn, slow} sql = timeIt slow sql . SQL.execute conn sql
{-# INLINE execute #-}

execute_ :: Connection -> Query -> IO ()
execute_ Connection {conn, slow} sql = timeIt slow sql $ SQL.execute_ conn sql
{-# INLINE execute_ #-}

executeMany :: ToRow q => Connection -> Query -> [q] -> IO ()
executeMany Connection {conn, slow} sql = timeIt slow sql . SQL.executeMany conn sql
{-# INLINE executeMany #-}

query :: (ToRow q, FromRow r) => Connection -> Query -> q -> IO [r]
query Connection {conn, slow} sql = timeIt slow sql . SQL.query conn sql
{-# INLINE query #-}

query_ :: FromRow r => Connection -> Query -> IO [r]
query_ Connection {conn, slow} sql = timeIt slow sql $ SQL.query_ conn sql
{-# INLINE query_ #-}

$(J.deriveJSON defaultJSON ''SlowQueryStats)
