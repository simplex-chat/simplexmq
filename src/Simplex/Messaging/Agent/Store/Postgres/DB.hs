{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.Postgres.DB
  ( BoolInt (..),
    PSQL.Binary (..),
    PSQL.Connection,
    FromField (..),
    ToField (..),
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
import Data.Int (Int64)
import Data.Word (Word16, Word32)
import Database.PostgreSQL.Simple (ResultError (..))
import qualified Database.PostgreSQL.Simple as PSQL
import Database.PostgreSQL.Simple.FromField (FromField (..), returnError)
import Database.PostgreSQL.Simple.ToField (ToField (..))

newtype BoolInt = BI {unBI :: Bool}

instance FromField BoolInt where
  fromField field dat = BI . (/= (0 :: Int)) <$> fromField field dat
  {-# INLINE fromField #-}

instance ToField BoolInt where
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

-- orphan instances

-- used in FileSize
instance FromField Word32 where
  fromField field dat = do
    i :: Int64 <- fromField field dat
    if i >= 0 && i <= fromIntegral (maxBound :: Word32)
      then pure (fromIntegral i :: Word32)
      else returnError ConversionFailed field "Negative value can't be converted to Word32"

-- used in Version
instance FromField Word16 where
  fromField field dat = do
    i :: Int64 <- fromField field dat
    if i >= 0 && i <= fromIntegral (maxBound :: Word16)
      then pure (fromIntegral i :: Word16)
      else returnError ConversionFailed field "Negative value can't be converted to Word16"
