{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Simplex.Messaging.Parsers where

import Control.Monad.Trans.Except
import qualified Data.Aeson as J
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isAlphaNum, toLower)
import Data.String
import Data.Text (Text)
import qualified Data.Text as T
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
base64P = decode <$?> paddedBase64 rawBase64P

paddedBase64 :: Parser ByteString -> Parser ByteString
paddedBase64 raw = (<>) <$> raw <*> pad
  where
    pad = A.takeWhile (== '=')

rawBase64P :: Parser ByteString
rawBase64P = A.takeWhile1 (\c -> isAlphaNum c || c == '+' || c == '/')

-- rawBase64UriP :: Parser ByteString
-- rawBase64UriP = A.takeWhile1 (\c -> isAlphaNum c || c == '-' || c == '_')

tsISO8601P :: Parser UTCTime
tsISO8601P = maybe (fail "timestamp") pure . parseISO8601 . B.unpack =<< A.takeTill wordEnd

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
blobFieldParser = blobFieldDecoder . parseAll

blobFieldDecoder :: Typeable k => (ByteString -> Either String k) -> FieldParser k
blobFieldDecoder dec = \case
  f@(Field (SQLBlob b) _) ->
    case dec b of
      Right k -> Ok k
      Left e -> returnError ConversionFailed f ("couldn't parse field: " ++ e)
  f -> returnError ConversionFailed f "expecting SQLBlob column type"

fromTextField_ :: Typeable a => (Text -> Maybe a) -> Field -> Ok a
fromTextField_ fromText = \case
  f@(Field (SQLText t) _) ->
    case fromText t of
      Just x -> Ok x
      _ -> returnError ConversionFailed f ("invalid text: " <> T.unpack t)
  f -> returnError ConversionFailed f "expecting SQLText column type"

fstToLower :: String -> String
fstToLower "" = ""
fstToLower (h : t) = toLower h : t

dropPrefix :: String -> String -> String
dropPrefix pfx s =
  let (p, rest) = splitAt (length pfx) s
   in fstToLower $ if p == pfx then rest else s

enumJSON :: (String -> String) -> J.Options
enumJSON tagModifier =
  J.defaultOptions
    { J.constructorTagModifier = tagModifier,
      J.allNullaryToStringTag = True
    }

-- used in platform-specific encoding, includes tag for single-field encoding of sum types to allow conversion to tagged objects
sumTypeJSON :: (String -> String) -> J.Options
#if defined(darwin_HOST_OS) && defined(swiftJSON)
sumTypeJSON = singleFieldJSON_ $ Just SingleFieldJSONTag
#else
sumTypeJSON = taggedObjectJSON
#endif

pattern SingleFieldJSONTag :: (Eq a, IsString a) => a
pattern SingleFieldJSONTag = "_owsf"

taggedObjectJSON :: (String -> String) -> J.Options
taggedObjectJSON tagModifier =
  J.defaultOptions
    { J.sumEncoding = J.TaggedObject TaggedObjectJSONTag TaggedObjectJSONData,
      J.tagSingleConstructors = True,
      J.constructorTagModifier = tagModifier,
      J.allNullaryToStringTag = False,
      J.nullaryToObject = True,
      J.omitNothingFields = True
    }

pattern TaggedObjectJSONTag :: (Eq a, IsString a) => a
pattern TaggedObjectJSONTag = "type"

pattern TaggedObjectJSONData :: (Eq a, IsString a) => a
pattern TaggedObjectJSONData = "data"

-- used in platform independent encoding, doesn't include tag for single-field encoding of sum types
singleFieldJSON :: (String -> String) -> J.Options
singleFieldJSON = singleFieldJSON_ Nothing

singleFieldJSON_ :: Maybe String -> (String -> String) -> J.Options
singleFieldJSON_ objectTag tagModifier =
  J.defaultOptions
    { J.sumEncoding = J.ObjectWithSingleField objectTag,
      J.tagSingleConstructors = True,
      J.constructorTagModifier = tagModifier,
      J.allNullaryToStringTag = False,
      J.nullaryToObject = True,
      J.omitNothingFields = True
    }

defaultJSON :: J.Options
defaultJSON = J.defaultOptions {J.omitNothingFields = True}
