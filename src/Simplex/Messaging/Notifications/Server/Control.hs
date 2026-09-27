{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Server.Control
  ( ControlProtocol (..),
  )
where

import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Text (Text)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (BasicAuth)
import Simplex.Messaging.Server.AddressStats (addressesArgs, addressesArgsP)

data ControlProtocol
  = CPAuth BasicAuth
  | CPStats
  | CPStatsRTS
  | CPServerInfo
  | CPAddresses Text (Maybe Int)
  | CPHelp
  | CPQuit
  | CPSkip

instance StrEncoding ControlProtocol where
  strEncode = \case
    CPAuth tok -> "auth " <> strEncode tok
    CPStats -> "stats"
    CPStatsRTS -> "stats-rts"
    CPServerInfo -> "server-info"
    CPAddresses name n_ -> "addresses " <> addressesArgs name n_
    CPHelp -> "help"
    CPQuit -> "quit"
    CPSkip -> ""
  strP =
    A.takeTill (== ' ') >>= \case
      "auth" -> CPAuth <$> _strP
      "stats" -> pure CPStats
      "stats-rts" -> pure CPStatsRTS
      "server-info" -> pure CPServerInfo
      "addresses" -> uncurry CPAddresses <$> addressesArgsP
      "help" -> pure CPHelp
      "quit" -> pure CPQuit
      "" -> pure CPSkip
      _ -> fail "bad ControlProtocol command"
