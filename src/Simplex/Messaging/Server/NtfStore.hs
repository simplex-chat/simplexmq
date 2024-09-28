{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.NtfStore where

import Data.Time.Clock.System (SystemTime (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (EncNMsgMeta, MsgId, NotifierId)

data MsgNtf = MsgNtf MsgId SystemTime C.CbNonce EncNMsgMeta

data NtfLogRecord = NLRv1 NotifierId MsgNtf

instance StrEncoding MsgNtf where
  strEncode (MsgNtf msgId msgTs nonce body) = strEncode (msgId, msgTs, nonce, body)
  strP = MsgNtf <$> strP_ <*> strP_ <*> strP_ <*> strP

instance StrEncoding NtfLogRecord where
  strEncode (NLRv1 nId ntf) = strEncode (Str "v1", nId, ntf)
  strP = "v1 " *> (NLRv1 <$> strP_ <*> strP)
