{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Server.Expiration where

import Control.Monad.IO.Class
import Data.Int (Int64)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)

data ExpirationConfig = ExpirationConfig
  { -- time after which the entity can be expired, seconds
    ttl :: Int64,
    -- interval to check expiration, seconds
    checkInterval :: Int64
  }

expireBeforeEpoch :: ExpirationConfig -> IO Int64
expireBeforeEpoch ExpirationConfig {ttl} = subtract ttl . systemSeconds <$> liftIO getSystemTime
