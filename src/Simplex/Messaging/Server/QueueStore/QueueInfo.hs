{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.Server.QueueStore.QueueInfo where

import qualified Data.Aeson as J
import qualified Data.Aeson.TH as JQ
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Text (Text)
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Data.Time.Clock (UTCTime)
import Simplex.Messaging.Agent.Store.DB (FromField (..), ToField (..), fromTextField_)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Parsers (defaultJSON, dropPrefix, enumJSON)
import Simplex.Messaging.Util (eitherToMaybe, (<$?>))

data QueueInfo = QueueInfo
  { qiSnd :: Bool,
    qiNtf :: Bool,
    qiSub :: Maybe QSub,
    qiSize :: Int,
    qiMsg :: Maybe MsgInfo
  }
  deriving (Eq, Show)

data QSub = QSub
  { qSubThread :: QSubThread,
    qDelivered :: Maybe Text
  }
  deriving (Eq, Show)

data QSubThread = QNoSub | QSubPending | QSubThread | QProhibitSub
  deriving (Eq, Show)

data MsgInfo = MsgInfo
  { msgId :: Text,
    msgTs :: UTCTime,
    msgType :: MsgType
  }
  deriving (Eq, Show)

data MsgType = MTMessage | MTQuota
  deriving (Eq, Show)

data QueueMode = QMMessaging | QMContact deriving (Eq, Show)

instance Encoding QueueMode where
  smpEncode = \case
    QMMessaging -> "M"
    QMContact -> "C"
  smpP =
    A.anyChar >>= \case
      'M' -> pure QMMessaging
      'C' -> pure QMContact
      _ -> fail "bad QueueMode"

instance FromField QueueMode where fromField = fromTextField_ $ eitherToMaybe . smpDecode . encodeUtf8

instance ToField QueueMode where toField = toField . decodeLatin1 . smpEncode

$(JQ.deriveJSON (enumJSON $ dropPrefix "Q") ''QSubThread)

$(JQ.deriveJSON defaultJSON ''QSub)

$(JQ.deriveJSON (enumJSON $ dropPrefix "MT") ''MsgType)

$(JQ.deriveJSON defaultJSON ''MsgInfo)

$(JQ.deriveJSON defaultJSON ''QueueInfo)

instance Encoding QueueInfo where
  smpEncode = LB.toStrict . J.encode
  smpP = J.eitherDecodeStrict <$?> A.takeByteString
