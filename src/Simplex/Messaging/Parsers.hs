{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Parsers where

import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isAlphaNum)
import Data.Time.Clock (UTCTime)
import Data.Time.ISO8601 (parseISO8601)
import Data.Typeable (Typeable)
import Database.SQLite.Simple (ResultError (..), SQLData (..))
import Database.SQLite.Simple.FromField (FieldParser, returnError)
import Database.SQLite.Simple.Internal (Field (..))
import Database.SQLite.Simple.Ok (Ok (Ok))
import Simplex.Messaging.Util ((<$?>))
import Text.Read (readMaybe)

base64P :: Parser ByteString
base64P = decode <$?> base64StringP

base64StringP :: Parser ByteString
base64StringP = do
  str <- A.takeWhile1 (\c -> isAlphaNum c || c == '+' || c == '/')
  pad <- A.takeWhile (== '=')
  pure $ str <> pad

tsISO8601P :: Parser UTCTime
tsISO8601P = maybe (fail "timestamp") pure . parseISO8601 . B.unpack =<< A.takeTill (== ' ')

parse :: Parser a -> e -> (ByteString -> Either e a)
parse parser err = first (const err) . parseAll parser

parseAll :: Parser a -> (ByteString -> Either String a)
parseAll parser = A.parseOnly (parser <* A.endOfInput)

parseRead :: Read a => Parser ByteString -> Parser a
parseRead = (>>= maybe (fail "cannot read") pure . readMaybe . B.unpack)

parseRead1 :: Read a => Parser a
parseRead1 = parseRead $ A.takeTill (== ' ')

parseRead2 :: Read a => Parser a
parseRead2 = parseRead $ do
  w1 <- A.takeTill (== ' ') <* A.char ' '
  w2 <- A.takeTill (== ' ')
  pure $ w1 <> " " <> w2

blobFieldParser :: Typeable k => Parser k -> FieldParser k
blobFieldParser p = \case
  f@(Field (SQLBlob b) _) ->
    case parseAll p b of
      Right k -> Ok k
      Left e -> returnError ConversionFailed f ("couldn't parse field: " ++ e)
  f -> returnError ConversionFailed f "expecting SQLBlob column type"
