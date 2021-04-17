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
import Text.Read (readMaybe)

base64P :: Parser ByteString
base64P = either fail pure . decode =<< base64StringP

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

parseRead :: Read a => Parser a
parseRead = maybe (fail "unknown error") pure . readMaybe . B.unpack =<< A.takeTill (== ' ')
