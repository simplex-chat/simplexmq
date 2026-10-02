{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Server.Control
  ( ControlProtocol (..),
  )
where

import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Text (Text)
import Simplex.FileTransfer.Protocol (XFTPFileId)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (BasicAuth, BlockingInfo)
import Simplex.Messaging.Server.AddressStats (addressesArgs, addressesArgsP)

data ControlProtocol
  = CPAuth BasicAuth
  | CPStatsRTS
  | CPDelete XFTPFileId
  | CPBlock XFTPFileId BlockingInfo
  | CPAddresses Text (Maybe Int)
  | CPHelp
  | CPQuit
  | CPSkip

instance StrEncoding ControlProtocol where
  strEncode = \case
    CPAuth tok -> "auth " <> strEncode tok
    CPStatsRTS -> "stats-rts"
    CPDelete fId -> strEncode (Str "delete", fId)
    CPBlock fId info -> strEncode (Str "block", fId, info)
    CPAddresses name n_ -> "addresses " <> addressesArgs name n_
    CPHelp -> "help"
    CPQuit -> "quit"
    CPSkip -> ""
  strP =
    A.takeTill (== ' ') >>= \case
      "auth" -> CPAuth <$> _strP
      "stats-rts" -> pure CPStatsRTS
      "delete" -> CPDelete <$> _strP
      "block" -> CPBlock <$> _strP <*> _strP
      "addresses" -> uncurry CPAddresses <$> addressesArgsP
      "help" -> pure CPHelp
      "quit" -> pure CPQuit
      "" -> pure CPSkip
      _ -> fail "bad ControlProtocol command"
