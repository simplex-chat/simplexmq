{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.QueueStore where

import Data.Int (Int64)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import qualified Database.RocksDB as R

testRocksDBFun :: IO ()
testRocksDBFun = do
  R.withDB "/tmp/rocks.db" conf $ \db ->
    R.put db "k" "v"
  where
    conf = R.Config
      { R.createIfMissing = True,
        R.errorIfExists = False,
        R.paranoidChecks = True,
        R.maxFiles = Nothing,
        R.prefixLength = Nothing,
        R.bloomFilter = False
      }

data QueueRec = QueueRec
  { recipientId :: !RecipientId,
    recipientKey :: !RcvPublicAuthKey,
    rcvDhSecret :: !RcvDhSecret,
    senderId :: !SenderId,
    senderKey :: !(Maybe SndPublicAuthKey),
    sndSecure :: !SenderCanSecure,
    notifier :: !(Maybe NtfCreds),
    status :: !ServerQueueStatus,
    updatedAt :: !(Maybe RoundedSystemTime)
  }
  deriving (Show)

data NtfCreds = NtfCreds
  { notifierId :: !NotifierId,
    notifierKey :: !NtfPublicAuthKey,
    rcvNtfDhSecret :: !RcvNtfDhSecret
  }
  deriving (Show)

instance StrEncoding NtfCreds where
  strEncode NtfCreds {notifierId, notifierKey, rcvNtfDhSecret} = strEncode (notifierId, notifierKey, rcvNtfDhSecret)
  strP = do
    (notifierId, notifierKey, rcvNtfDhSecret) <- strP
    pure NtfCreds {notifierId, notifierKey, rcvNtfDhSecret}

data ServerQueueStatus = QueueActive | QueueOff deriving (Eq, Show)

newtype RoundedSystemTime = RoundedSystemTime Int64
  deriving (Eq, Ord, Show)

instance StrEncoding RoundedSystemTime where
  strEncode (RoundedSystemTime t) = strEncode t
  strP = RoundedSystemTime <$> strP

getRoundedSystemTime :: Int64 -> IO RoundedSystemTime
getRoundedSystemTime prec = (\t -> RoundedSystemTime $ (systemSeconds t `div` prec) * prec) <$> getSystemTime

getSystemDate :: IO RoundedSystemTime
getSystemDate = getRoundedSystemTime 86400
