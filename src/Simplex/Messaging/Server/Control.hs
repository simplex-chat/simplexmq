{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.Control where

import qualified Data.Attoparsec.ByteString.Char8 as A
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (BasicAuth, SenderId)

data CPClientRole = CPRNone | CPRUser | CPRAdmin
  deriving (Eq)

data ControlProtocol
  = CPAuth BasicAuth
  | CPSuspend
  | CPResume
  | CPClients
  | CPStats
  | CPStatsRTS
  | CPThreads
  | CPSockets
  | CPSocketThreads
  | CPServerInfo
  | CPDelete SenderId
  | CPSave
  | CPHelp
  | CPQuit
  | CPSkip

instance StrEncoding ControlProtocol where
  strEncode = \case
    CPAuth bs -> "auth " <> strEncode bs
    CPSuspend -> "suspend"
    CPResume -> "resume"
    CPClients -> "clients"
    CPStats -> "stats"
    CPStatsRTS -> "stats-rts"
    CPThreads -> "threads"
    CPSockets -> "sockets"
    CPSocketThreads -> "socket-threads"
    CPServerInfo -> "server-info"
    CPDelete bs -> "delete " <> strEncode bs
    CPSave -> "save"
    CPHelp -> "help"
    CPQuit -> "quit"
    CPSkip -> ""
  strP =
    A.takeTill (== ' ') >>= \case
      "auth" -> CPAuth <$> (A.space *> strP)
      "suspend" -> pure CPSuspend
      "resume" -> pure CPResume
      "clients" -> pure CPClients
      "stats" -> pure CPStats
      "stats-rts" -> pure CPStatsRTS
      "threads" -> pure CPThreads
      "sockets" -> pure CPSockets
      "socket-threads" -> pure CPSocketThreads
      "server-info" -> pure CPServerInfo
      "delete" -> CPDelete <$> (A.space *> strP)
      "save" -> pure CPSave
      "help" -> pure CPHelp
      "quit" -> pure CPQuit
      "" -> pure CPSkip
      _ -> fail "bad ControlProtocol command"
