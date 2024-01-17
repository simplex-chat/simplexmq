{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Server.Control where

import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString (ByteString)
import Simplex.Messaging.Encoding.String

data ControlProtocol
  = CPStatsRTS
  | CPDelete ByteString
  | CPHelp
  | CPQuit
  | CPSkip

instance StrEncoding ControlProtocol where
  strEncode = \case
    CPStatsRTS -> "stats-rts"
    CPDelete bs -> "delete " <> strEncode bs
    CPHelp -> "help"
    CPQuit -> "quit"
    CPSkip -> ""
  strP =
    A.takeTill (== ' ') >>= \case
      "stats-rts" -> pure CPStatsRTS
      "delete" -> CPDelete <$> (A.space *> strP)
      "help" -> pure CPHelp
      "quit" -> pure CPQuit
      "" -> pure CPSkip
      _ -> fail "bad ControlProtocol command"
