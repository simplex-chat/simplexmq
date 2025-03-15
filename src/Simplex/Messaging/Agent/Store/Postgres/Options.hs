module Simplex.Messaging.Agent.Store.Postgres.Options where

import Data.ByteString (ByteString)
import Numeric.Natural

data DBOpts = DBOpts
  { connstr :: ByteString,
    schema :: ByteString,
    poolSize :: Natural,
    createSchema :: Bool
  }
  deriving (Show)
