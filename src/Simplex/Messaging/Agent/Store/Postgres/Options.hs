module Simplex.Messaging.Agent.Store.Postgres.Options
  ( DBOpts (..),
  ) where

import Data.ByteString (ByteString)
import Numeric.Natural

data DBOpts = DBOpts
  { connstr :: ByteString,
    schema :: ByteString,
    poolSize :: Natural,
    createSchema :: Bool
  }
  deriving (Show)
