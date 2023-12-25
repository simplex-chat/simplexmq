{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.Control where

import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base64.URL as U
import Simplex.Messaging.Encoding.String

data ControlProtocol
  = CPSuspend
  | CPResume
  | CPClients
  | CPStats
  | CPStatsRTS
  | CPThreads
  | CPSockets
  | CPSocketThreads
  | CPDelete ByteString
  | CPSave
  | CPHelp
  | CPQuit
  | CPSkip

instance StrEncoding ControlProtocol where
  strEncode = \case
    CPSuspend -> "suspend"
    CPResume -> "resume"
    CPClients -> "clients"
    CPStats -> "stats"
    CPStatsRTS -> "stats-rts"
    CPThreads -> "threads"
    CPSockets -> "sockets"
    CPSocketThreads -> "socket-threads"
    CPDelete bs -> "delete " <> U.encode bs
    CPSave -> "save"
    CPHelp -> "help"
    CPQuit -> "quit"
    CPSkip -> ""
  strP =
    A.takeTill (== ' ') >>= \case
      "suspend" -> pure CPSuspend
      "resume" -> pure CPResume
      "clients" -> pure CPClients
      "stats" -> pure CPStats
      "stats-rts" -> pure CPStatsRTS
      "threads" -> pure CPThreads
      "sockets" -> pure CPSockets
      "socket-threads" -> pure CPSocketThreads
      "delete" -> CPDelete <$> (A.space *> base64urlP)
      "save" -> pure CPSave
      "help" -> pure CPHelp
      "quit" -> pure CPQuit
      "" -> pure CPSkip
      _ -> fail "bad ControlProtocol command"
