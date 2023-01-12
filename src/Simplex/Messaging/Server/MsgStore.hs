{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.MsgStore where

import Control.Applicative ((<|>))
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (Message (..), RcvMessage (..), RecipientId)

data MsgLogRecord = MLRv3 RecipientId Message | MLRv1 RecipientId RcvMessage

instance StrEncoding MsgLogRecord where
  strEncode = \case
    MLRv3 rId msg -> strEncode (Str "v3", rId, msg)
    MLRv1 rId msg -> strEncode (rId, msg)
  strP = "v3 " *> (MLRv3 <$> strP_ <*> strP) <|> MLRv1 <$> strP_ <*> strP
