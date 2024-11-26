{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Server.Control where

import qualified Data.Attoparsec.ByteString.Char8 as A
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (BasicAuth)

data ControlProtocol
  = CPAuth BasicAuth
  | CPStats
  | CPStatsRTS
  | CPServerInfo
  | CPHelp
  | CPQuit
  | CPSkip

instance StrEncoding ControlProtocol where
  strEncode = \case
    CPAuth tok -> "auth " <> strEncode tok
    CPStats -> "stats"
    CPStatsRTS -> "stats-rts"
    CPServerInfo -> "server-info"
    CPHelp -> "help"
    CPQuit -> "quit"
    CPSkip -> ""
  strP =
    A.takeTill (== ' ') >>= \case
      "auth" -> CPAuth <$> _strP
      "stats" -> pure CPStats
      "stats-rts" -> pure CPStatsRTS
      "server-info" -> pure CPServerInfo
      "help" -> pure CPHelp
      "quit" -> pure CPQuit
      "" -> pure CPSkip
      _ -> fail "bad ControlProtocol command"
