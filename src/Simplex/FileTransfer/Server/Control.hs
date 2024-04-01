{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Server.Control where

import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString (ByteString)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (BasicAuth)

data CPClientRole = CPRNone | CPRUser | CPRAdmin

data ControlProtocol
  = CPAuth BasicAuth
  | CPStatsRTS
  | CPDelete ByteString
  | CPHelp
  | CPQuit
  | CPSkip

instance StrEncoding ControlProtocol where
  strEncode = \case
    CPAuth tok -> "auth " <> strEncode tok
    CPStatsRTS -> "stats-rts"
    CPDelete fId -> strEncode (Str "delete", fId)
    CPHelp -> "help"
    CPQuit -> "quit"
    CPSkip -> ""
  strP =
    A.takeTill (== ' ') >>= \case
      "auth" -> CPAuth <$> _strP
      "stats-rts" -> pure CPStatsRTS
      "delete" -> CPDelete <$> _strP
      "help" -> pure CPHelp
      "quit" -> pure CPQuit
      "" -> pure CPSkip
      _ -> fail "bad ControlProtocol command"
