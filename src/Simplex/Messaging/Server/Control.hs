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
  | CPDump
  | CPHelp
  | CPQuit

instance StrEncoding ControlProtocol where
  strEncode = \case
    CPSuspend -> "suspend"
    CPResume -> "resume"
    CPClients -> "clients"
    CPStats -> "stats"
    CPDump -> "dump"
    CPHelp -> "help"
    CPQuit -> "quit"
  strP =
    A.takeTill (== ' ') >>= \case
      "suspend" -> pure CPSuspend
      "resume" -> pure CPResume
      "clients" -> pure CPClients
      "stats" -> pure CPStats
      "dump" -> pure CPDump
      "help" -> pure CPHelp
      "quit" -> pure CPQuit
      _ -> fail "bad ControlProtocol command"

-- suspendInactive :: TVar Bool -> TVar Bool -> STM ()
-- suspendInactive active suspended = do
--   a <- readTVar active
--   writeTVar suspended $! not a
--   unless a retry
