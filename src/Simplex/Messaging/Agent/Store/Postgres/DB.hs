{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.Postgres.DB
  ( BoolInt (..),
    PSQL.Binary (..),
    PSQL.Connection,
    FromField (..),
    ToField (..),
    SQLError,
    PSQL.connect,
    PSQL.close,
    execute,
    execute_,
    executeMany,
    query,
    query_,
    blobFieldDecoder,
    fromTextField_,
  )
where

import qualified Control.Exception as E
import Control.Monad (void)
import qualified Data.ByteString as B
import Data.ByteString.Char8 (ByteString)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)
import Data.Typeable (Typeable)
import Data.Word (Word16, Word32)
import Database.PostgreSQL.Simple (Connection, ResultError (..), SqlError (..), FromRow, ToRow)
import qualified Database.PostgreSQL.Simple as PSQL
import Database.PostgreSQL.Simple.FromField (Field (..), FieldParser, FromField (..), returnError)
import Database.PostgreSQL.Simple.ToField (ToField (..))
import Database.PostgreSQL.Simple.TypeInfo.Static (textOid, varcharOid)
import Database.PostgreSQL.Simple.Types (Query (..))

newtype BoolInt = BI {unBI :: Bool}

type SQLError = SqlError

instance FromField BoolInt where
  fromField field dat = BI . (/= (0 :: Int)) <$> fromField field dat
  {-# INLINE fromField #-}

instance ToField BoolInt where
  toField (BI b) = toField ((if b then 1 else 0) :: Int)
  {-# INLINE toField #-}

execute :: ToRow q => PSQL.Connection -> Query -> q -> IO ()
execute db q qs = void $ PSQL.execute db q qs `E.catch` addSql q
{-# INLINE execute #-}

execute_ :: PSQL.Connection -> Query -> IO ()
execute_ db q = void $ PSQL.execute_ db q `E.catch` addSql q
{-# INLINE execute_ #-}

executeMany :: ToRow q => PSQL.Connection -> Query -> [q] -> IO ()
executeMany db q qs = void $ PSQL.executeMany db q qs `E.catch` addSql q
{-# INLINE executeMany #-}

query :: (ToRow q, FromRow r) => PSQL.Connection -> Query -> q -> IO [r]
query db q qs = PSQL.query db q qs `E.catch` addSql q
{-# INLINE query #-}

query_ :: FromRow r => Connection -> Query -> IO [r]
query_ db q = PSQL.query_ db q `E.catch` addSql q
{-# INLINE query_ #-}

addSql :: Query -> SqlError -> IO r
addSql q e@SqlError {sqlErrorHint = hint} =
  E.throwIO e {sqlErrorHint = if B.null hint then fromQuery q else hint <> ", " <> fromQuery q}

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

blobFieldDecoder :: Typeable k => (ByteString -> Either String k) -> FieldParser k
blobFieldDecoder dec f val = do
  x <- fromField f val
  case dec x of
    Right k -> pure k
    Left e -> returnError ConversionFailed f ("couldn't parse field: " ++ e)

fromTextField_ :: Typeable a => (Text -> Maybe a) -> FieldParser a
fromTextField_ fromText f val =
  if typeOid f `elem` [textOid, varcharOid]
    then case val of
      Just t -> case fromText $ decodeUtf8 t of
        Just x -> pure x
        _ -> returnError ConversionFailed f "invalid text value"
      Nothing -> returnError UnexpectedNull f "NULL value found for non-NULL field"
    else returnError Incompatible f "expecting TEXT or VARCHAR column type"
