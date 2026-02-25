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
import Network.Socket (HostName, ServiceName)
import Simplex.Messaging.Encoding.String (StrEncoding (..))

data ServiceScheme = SSSimplex | SSAppServer SrvLoc
  deriving (Eq, Show)

instance StrEncoding ServiceScheme where
  strEncode = \case
    SSSimplex -> "simplex:"
    SSAppServer srv -> "https://" <> strEncode srv
  strP =
    "simplex:" $> SSSimplex
      <|> "https://" *> (SSAppServer <$> strP)

data SrvLoc = SrvLoc HostName ServiceName
  deriving (Eq, Ord, Show)

instance StrEncoding SrvLoc where
  strEncode (SrvLoc host port) = B.pack $ host <> if null port then "" else ':' : port
  strP = SrvLoc <$> host <*> (port <|> pure "")
    where
      host = B.unpack <$> A.takeWhile1 (A.notInClass ":#,;/ ")
      port = show <$> (A.char ':' *> (A.decimal :: A.Parser Int))

simplexChat :: ServiceScheme
simplexChat = SSAppServer $ SrvLoc "simplex.chat" ""
