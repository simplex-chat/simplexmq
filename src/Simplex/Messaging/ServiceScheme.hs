{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.ServiceScheme
  ( ServiceScheme (..),
    SrvLoc (..),
    simplexChat,
  ) where

import Control.Applicative ((<|>))
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Network.Socket (ServiceName)
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Transport.Client (TransportHost (..))

data ServiceScheme = SSSimplex | SSAppServer SrvLoc
  deriving (Eq, Show)

instance StrEncoding ServiceScheme where
  strEncode = \case
    SSSimplex -> "simplex:"
    SSAppServer srv -> "https://" <> strEncode srv
  strP =
    "simplex:" $> SSSimplex
      <|> "https://" *> (SSAppServer <$> strP)

data SrvLoc = SrvLoc TransportHost ServiceName
  deriving (Eq, Ord, Show)

instance StrEncoding SrvLoc where
  strEncode (SrvLoc host port) = case host of
    THIPv6 _ | not (null port) -> strEncode ('[',  host, ']') <> B.pack (':' : port)
    _ -> strEncode host
  strP = SrvLoc <$> strP <*> (port <|> pure "")
    where
      port = show <$> (A.char ':' *> (A.decimal :: A.Parser Int))

simplexChat :: ServiceScheme
simplexChat = SSAppServer $ SrvLoc "simplex.chat" ""
