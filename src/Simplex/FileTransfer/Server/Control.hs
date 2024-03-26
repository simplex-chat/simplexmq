{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Server.Control where

import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString (ByteString)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String

data ControlProtocol
  = CPStatsRTS
  | CPDelete ByteString C.APublicAuthKey
  | CPHelp
  | CPQuit
  | CPSkip

instance StrEncoding ControlProtocol where
  strEncode = \case
    CPStatsRTS -> "stats-rts"
    CPDelete fId fKey -> strEncode (Str "delete", fId, fKey)
    CPHelp -> "help"
    CPQuit -> "quit"
    CPSkip -> ""
  strP =
    A.takeTill (== ' ') >>= \case
      "stats-rts" -> pure CPStatsRTS
      "delete" -> CPDelete <$> _strP <*> _strP
      "help" -> pure CPHelp
      "quit" -> pure CPQuit
      "" -> pure CPSkip
      _ -> fail "bad ControlProtocol command"
