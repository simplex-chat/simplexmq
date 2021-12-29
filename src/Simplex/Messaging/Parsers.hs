{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Parsers where

import Control.Monad.Trans.Except
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import Data.ByteString.Base64
import qualified Data.ByteString.Base64.URL as U
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isAlphaNum)
import Data.Time.Clock (UTCTime)
import Data.Time.ISO8601 (formatISO8601Millis, parseISO8601)
import Data.Typeable (Typeable)
import Data.Word (Word16, Word32)
import Database.SQLite.Simple (ResultError (..), SQLData (..))
import Database.SQLite.Simple.FromField (FieldParser, returnError)
import Database.SQLite.Simple.Internal (Field (..))
import Database.SQLite.Simple.Ok (Ok (Ok))
import Network.Transport.Internal (decodeWord16, decodeWord32, encodeWord16)
import Simplex.Messaging.Util ((<$?>))
import Text.Read (readMaybe)

base64P :: Parser ByteString
base64P = decode <$?> base64StringP

base64StringP :: Parser ByteString
base64StringP = paddedBase64 rawBase64P

base64UriP :: Parser ByteString
base64UriP = U.decode <$?> base64UriStringP

base64UriStringP :: Parser ByteString
base64UriStringP = paddedBase64 rawBase64UriP

paddedBase64 :: Parser ByteString -> Parser ByteString
paddedBase64 raw = (<>) <$> raw <*> pad
  where
    pad = A.takeWhile (== '=')

rawBase64P :: Parser ByteString
rawBase64P = A.takeWhile1 (\c -> isAlphaNum c || c == '+' || c == '/')

rawBase64UriP :: Parser ByteString
rawBase64UriP = A.takeWhile1 (\c -> isAlphaNum c || c == '-' || c == '_')

-- | format UTC time as YYYY-MM-DDTHH:mm:ss.sssZ - exactly 24 bytes
serializeTsISO8601 :: UTCTime -> ByteString
serializeTsISO8601 = B.pack . formatISO8601Millis
{-# INLINE serializeTsISO8601 #-}

tsISO8601P :: Parser UTCTime
tsISO8601P = maybe (fail "timestamp") pure . parseISO8601 . B.unpack =<< A.takeTill wordEnd

binaryTsISO8601P :: Parser UTCTime
binaryTsISO8601P = maybe (fail "timestamp") pure . parseISO8601 . B.unpack =<< A.take 24

word16P :: Parser Word16
word16P = decodeWord16 <$> A.take 2

word32P :: Parser Word32
word32P = decodeWord32 <$> A.take 4

encodeLenBytes :: ByteString -> ByteString
encodeLenBytes s =
  let len = fromIntegral $ B.length s
   in encodeWord16 len <> s

lenBytesP :: Parser ByteString
lenBytesP = A.take . fromIntegral =<< word16P

parse :: Parser a -> e -> (ByteString -> Either e a)
parse parser err = first (const err) . parseAll parser

parseAll :: Parser a -> (ByteString -> Either String a)
parseAll parser = A.parseOnly (parser <* A.endOfInput)

parseE :: (String -> e) -> Parser a -> (ByteString -> ExceptT e IO a)
parseE err parser = except . first err . parseAll parser

parseE' :: (String -> e) -> Parser a -> (ByteString -> ExceptT e IO a)
parseE' err parser = except . first err . A.parseOnly parser

parseRead :: Read a => Parser ByteString -> Parser a
parseRead = (>>= maybe (fail "cannot read") pure . readMaybe . B.unpack)

parseRead1 :: Read a => Parser a
parseRead1 = parseRead $ A.takeTill wordEnd

parseRead2 :: Read a => Parser a
parseRead2 = parseRead $ do
  w1 <- A.takeTill wordEnd <* A.char ' '
  w2 <- A.takeTill wordEnd
  pure $ w1 <> " " <> w2

wordEnd :: Char -> Bool
wordEnd c = c == ' ' || c == '\n'

parseString :: (ByteString -> Either String a) -> (String -> a)
parseString p = either error id . p . B.pack

blobFieldParser :: Typeable k => Parser k -> FieldParser k
blobFieldParser p = \case
  f@(Field (SQLBlob b) _) ->
    case parseAll p b of
      Right k -> Ok k
      Left e -> returnError ConversionFailed f ("couldn't parse field: " ++ e)
  f -> returnError ConversionFailed f "expecting SQLBlob column type"
