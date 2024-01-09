{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.MsgStore where

import Control.Applicative ((<|>))
import qualified Data.ByteString as B
import Simplex.Messaging.Builder (Builder, byteString)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (Message (..), RcvMessage (..), RecipientId)

data MsgLogRecord = MLRv3 RecipientId Message | MLRv1 RecipientId RcvMessage

instance StrEncoding' MsgLogRecord where
  strEncode' = \case
    MLRv3 rId msg -> s (Str "v3", rId, B.empty) <> strEncode' msg
    MLRv1 rId msg -> s (rId, B.empty) <> strEncode' msg
    where
      s :: StrEncoding a => a -> Builder
      s = byteString . strEncode
  strP' = "v3 " *> (MLRv3 <$> strP_ <*> strP') <|> MLRv1 <$> strP_ <*> strP'
