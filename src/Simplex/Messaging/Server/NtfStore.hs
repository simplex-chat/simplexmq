module Simplex.Messaging.Server.NtfStore where

newtype NtfStore = NtfStore (TMap NotifierId NtfQueue)

-- stores notifications that will be delivered to notification servers
data NtfQueue = NtfQueue
  { notifications :: TBQueue MsgNtf, -- notifications to deliver
    deliveredMsgs :: TVar (Set MsgId) -- delivered messages to filter out from undeliverd notifications
  }

data MsgNtf = MsgNtf MsgId C.CbNonce EncNMsgMeta

data NtfLogRecord = NLRv1 NotifierId MsgNtf

instance StrEncoding MsgNtf where
  strEncode (MsgNtf msgId nonce body) = strEncode (msgId, nonce, body)
  strP = MsgNtf <*> strP_ <*> strP_ <*> strP

instance StrEncoding NtfLogRecord where
  strEncode (NLRv1 nId ntf) = strEncode (Str "v1", nId, ntf)
  strP = "v1 " *> (NLRv1 <$> strP_ <*> strP)
