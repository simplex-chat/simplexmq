{-# LANGUAGE CPP #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}

-- | BIP-44 paths, @m/44'/coin'/account'/0/0@: one account per key, at the hardened account level.
module Simplex.Messaging.Crypto.BIP44
  ( CoinType (..),
    AccountIndex,
    mkAccountIndex,
    unAccountIndex,
    bip44Path,
  )
where

import Data.Aeson (FromJSON (..), ToJSON)
import Data.Word (Word32)
import Simplex.Messaging.Agent.Store.DB (FromField (..), ToField (..))
import Simplex.Messaging.Crypto.BIP32 (hardened, isHardened)

#if defined(dbPostgres)
import Database.PostgreSQL.Simple.FromField (ResultError (..), returnError)
#else
import Database.SQLite.Simple (ResultError (..))
import Database.SQLite.Simple.FromField (returnError)
#endif

-- | SLIP-44 coin types.
data CoinType = Ethereum
  deriving (Eq, Show)

coinIndex :: CoinType -> Word32
coinIndex = \case
  Ethereum -> 60

-- | Below 2^31, so it can be hardened without colliding with another index.
newtype AccountIndex = AccountIndex Word32
  deriving (Eq, Ord, Show)
  deriving newtype (ToJSON, ToField)

unAccountIndex :: AccountIndex -> Word32
unAccountIndex (AccountIndex i) = i

mkAccountIndex :: Word32 -> Either String AccountIndex
mkAccountIndex i
  | isHardened i = Left "account index at or above 2^31"
  | otherwise = Right $ AccountIndex i

instance FromJSON AccountIndex where
  parseJSON v = parseJSON v >>= either fail pure . mkAccountIndex

#if defined(dbPostgres)
instance FromField AccountIndex where
  fromField f dat = fromField f dat >>= either (returnError ConversionFailed f) pure . mkAccountIndex
#else
instance FromField AccountIndex where
  fromField f = fromField f >>= either (returnError ConversionFailed f) pure . mkAccountIndex
#endif

bip44Path :: CoinType -> AccountIndex -> [Word32]
bip44Path coin (AccountIndex account) = [hardened 44, hardened (coinIndex coin), hardened account, 0, 0]
