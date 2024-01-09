{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.MsgStore where

import Control.Applicative ((<|>))
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import qualified Data.ByteString.Lazy.Internal as LB
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (Message (..), RcvMessage (..), RecipientId)

data MsgLogRecord = MLRv3 RecipientId Message | MLRv1 RecipientId RcvMessage

instance StrEncoding' MsgLogRecord where
  strEncode' = \case
    MLRv3 rId msg -> ch (Str "v3", rId, B.empty) msg
    MLRv1 rId msg -> ch (rId, B.empty) msg
    where
      ch :: (StrEncoding a, StrEncoding' b) => a -> b -> LB.ByteString
      ch a b = LB.chunk (strEncode a) (strEncode' b)
  strP' = "v3 " *> (MLRv3 <$> strP_ <*> strP') <|> MLRv1 <$> strP_ <*> strP'
