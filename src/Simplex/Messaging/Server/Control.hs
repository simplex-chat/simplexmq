{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.Control where

import qualified Data.Attoparsec.ByteString.Char8 as A
import Simplex.Messaging.Encoding.String

data ControlProtocol
  = CPSuspend
  | CPResume
  | CPClients
  | CPStats
  | CPStatsRTS
  | CPSave
  | CPHelp
  | CPQuit

instance StrEncoding ControlProtocol where
  strEncode = \case
    CPSuspend -> "suspend"
    CPResume -> "resume"
    CPClients -> "clients"
    CPStats -> "stats"
    CPStatsRTS -> "stats-rts"
    CPSave -> "save"
    CPHelp -> "help"
    CPQuit -> "quit"
  strP =
    A.takeTill (== ' ') >>= \case
      "suspend" -> pure CPSuspend
      "resume" -> pure CPResume
      "clients" -> pure CPClients
      "stats" -> pure CPStats
      "stats-rts" -> pure CPStatsRTS
      "save" -> pure CPSave
      "help" -> pure CPHelp
      "quit" -> pure CPQuit
      _ -> fail "bad ControlProtocol command"
