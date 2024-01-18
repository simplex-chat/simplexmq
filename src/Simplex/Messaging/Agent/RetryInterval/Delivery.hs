{-# LANGUAGE NumericUnderscores #-}

module Simplex.Messaging.Agent.RetryInterval.Delivery where

import Data.Time.Clock (NominalDiffTime, nominalDay)
import Simplex.Messaging.Agent.RetryInterval

data MsgDeliveryConfig = MsgDeliveryConfig
  { messageRetryInterval :: RetryInterval,
    messageTimeout :: NominalDiffTime,
    messageConsecutiveRetries :: Int,
    quotaExceededRetryInterval :: RetryInterval,
    quotaExceededTimeout :: NominalDiffTime
  }

defaultMsgDeliveryConfig :: MsgDeliveryConfig
defaultMsgDeliveryConfig =
  MsgDeliveryConfig
    { messageRetryInterval =
        RetryInterval
          { initialInterval = 1_000000,
            increaseAfter = 10_000000,
            maxInterval = 60_000000
          },
      messageTimeout = 2 * nominalDay,
      messageConsecutiveRetries = 3,
      quotaExceededRetryInterval =
        RetryInterval
          { initialInterval = 180_000000, -- 3 minutes
            increaseAfter = 0,
            maxInterval = 3 * 3600_000000 -- 3 hours
          },
      quotaExceededTimeout = 7 * nominalDay
    }

-- if
--   | quota exceeded ->
--     | message expired -> send error, stop retries, check and fail other expired messages
--     | otherwise -> stop retries, update delay, store deliver_after
--   | timeout ->
--     | n < messageConsecutiveRetries -> loop
--     | message expired -> send error, stop retries, check and fail other expired messages
--     | otherwise -> stop retries, update delay, store deliver_after
