{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Server.Control
  ()
where

import qualified Data.Attoparsec.ByteString.Char8 as A
import Simplex.FileTransfer.Protocol (XFTPFileId)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (BasicAuth, BlockingInfo)

data ControlProtocol
  = CPAuth BasicAuth
  | CPStatsRTS
  | CPDelete XFTPFileId
  | CPBlock XFTPFileId BlockingInfo
  | CPHelp
  | CPQuit
  | CPSkip

instance StrEncoding ControlProtocol where
  strEncode = \case
    CPAuth tok -> "auth " <> strEncode tok
    CPStatsRTS -> "stats-rts"
    CPDelete fId -> strEncode (Str "delete", fId)
    CPBlock fId info -> strEncode (Str "block", fId, info)
    CPHelp -> "help"
    CPQuit -> "quit"
    CPSkip -> ""
  strP =
    A.takeTill (== ' ') >>= \case
      "auth" -> CPAuth <$> _strP
      "stats-rts" -> pure CPStatsRTS
      "delete" -> CPDelete <$> _strP
      "block" -> CPBlock <$> _strP <*> _strP
      "help" -> pure CPHelp
      "quit" -> pure CPQuit
      "" -> pure CPSkip
      _ -> fail "bad ControlProtocol command"
