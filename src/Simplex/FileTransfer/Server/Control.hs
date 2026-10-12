{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Server.Control
  ( ControlProtocol (..),
  )
where

import Control.Applicative (optional)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Text (Text)
import Simplex.FileTransfer.Protocol (XFTPFileId)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (BasicAuth, BlockingInfo)

data ControlProtocol
  = CPAuth BasicAuth
  | CPStatsRTS
  | CPDelete XFTPFileId
  | CPBlock XFTPFileId BlockingInfo
  | CPUsage Text (Maybe Int)
  | CPHelp
  | CPQuit
  | CPSkip

instance StrEncoding ControlProtocol where
  strEncode = \case
    CPAuth tok -> "auth " <> strEncode tok
    CPStatsRTS -> "stats-rts"
    CPDelete fId -> strEncode (Str "delete", fId)
    CPBlock fId info -> strEncode (Str "block", fId, info)
    CPUsage name n_ -> strEncode (Str "usage", name) <> maybe "" ((" " <>) . strEncode) n_
    CPHelp -> "help"
    CPQuit -> "quit"
    CPSkip -> ""
  strP =
    A.takeTill (== ' ') >>= \case
      "auth" -> CPAuth <$> _strP
      "stats-rts" -> pure CPStatsRTS
      "delete" -> CPDelete <$> _strP
      "block" -> CPBlock <$> _strP <*> _strP
      "usage" -> CPUsage <$> _strP <*> optional _strP
      "help" -> pure CPHelp
      "quit" -> pure CPQuit
      "" -> pure CPSkip
      _ -> fail "bad ControlProtocol command"
