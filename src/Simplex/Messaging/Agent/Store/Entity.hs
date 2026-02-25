{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Agent.Store.Entity
  ( DBStored (..),
    DBEntityId,
    DBEntityId' (..),
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Aeson as J
import qualified Data.Aeson.Encoding as JE
import Data.Int (Int64)
import Data.Scientific (floatingOrInteger)
import Simplex.Messaging.Agent.Store.DB (FromField (..), ToField (..))

data DBStored = DBStored | DBNew

data SDBStored (s :: DBStored) where
  SDBStored :: SDBStored 'DBStored
  SDBNew :: SDBStored 'DBNew

deriving instance Show (SDBStored s)

class DBStoredI s where sdbStored :: SDBStored s

instance DBStoredI 'DBStored where sdbStored = SDBStored

instance DBStoredI 'DBNew where sdbStored = SDBNew

data DBEntityId' (s :: DBStored) where
  DBEntityId :: Int64 -> DBEntityId' 'DBStored
  DBNewEntity :: DBEntityId' 'DBNew

deriving instance Show (DBEntityId' s)

deriving instance Eq (DBEntityId' s)

type DBEntityId = DBEntityId' 'DBStored

type DBNewEntity = DBEntityId' 'DBNew

instance ToJSON (DBEntityId' s) where
  toEncoding = \case
    DBEntityId i -> toEncoding i
    DBNewEntity -> JE.null_
  toJSON = \case
    DBEntityId i -> toJSON i
    DBNewEntity -> J.Null

instance DBStoredI s => FromJSON (DBEntityId' s) where
  parseJSON v = case (v, sdbStored @s) of
    (J.Null, SDBNew) -> pure DBNewEntity
    (J.Number n, SDBStored) -> case floatingOrInteger n of
      Left (_ :: Double) -> fail "bad DBEntityId"
      Right i -> pure $ DBEntityId (fromInteger i)
    _ -> fail "bad DBEntityId"
  omittedField = case sdbStored @s of
    SDBStored -> Nothing
    SDBNew -> Just DBNewEntity

instance FromField DBEntityId where
#if defined(dbPostgres)
  fromField x dat = DBEntityId <$> fromField x dat
#else
  fromField x = DBEntityId <$> fromField x
#endif

instance ToField DBEntityId where toField (DBEntityId i) = toField i
