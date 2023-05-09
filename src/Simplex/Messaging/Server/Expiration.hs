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

showTTL :: Int64 -> String
showTTL s
  | s' /= 0 = show s <> " seconds"
  | ms' /= 0 = show ms <> " minutes"
  | hs' /= 0 = show hs <> " hours"
  | otherwise = show ds <> " days"
  where
    (ms, s') = s `divMod` 60
    (hs, ms') = ms `divMod` 60
    (ds, hs') = hs `divMod` 24
