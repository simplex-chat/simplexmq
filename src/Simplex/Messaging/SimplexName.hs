{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}

-- | SimpleX name shape — parsed surface form for `@contact.simplex`,
-- `#group`, and similar. Shared between the agent (which receives names
-- from the user) and the server (which validates them on the RSLV path).
module Simplex.Messaging.SimplexName
  ( SimplexNameInfo (..),
    SimplexNameDomain (..),
    SimplexTLD (..),
    SimplexNameType (..),
    fullDomainName,
    shortNameInfoStr,
  )
where

import Control.Applicative (optional, (<|>))
import qualified Data.Aeson.TH as J
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.Attoparsec.Text as AT
import Data.Char (isAlpha, isDigit)
import Data.Functor (($>))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (defaultJSON, dropPrefix, enumJSON)
import Simplex.Messaging.Util (safeDecodeUtf8, (<$?>))

data SimplexNameInfo = SimplexNameInfo
  { nameType :: SimplexNameType,
    nameDomain :: SimplexNameDomain
  }
  deriving (Eq, Show)

data SimplexNameDomain = SimplexNameDomain
  { nameTLD :: SimplexTLD,
    domain :: Text,
    subDomain :: [Text] -- parent to child: ["b", "a"] for a.b.domain.simplex
  }
  deriving (Eq, Show)

data SimplexTLD = TLDSimplex | TLDTesting | TLDWeb
  deriving (Eq, Show)

data SimplexNameType = NTPublicGroup | NTContact
  deriving (Eq, Show)

instance StrEncoding SimplexNameType where
  strEncode = \case
    NTPublicGroup -> "#"
    NTContact -> "@"
  strP = A.char '#' $> NTPublicGroup <|> A.char '@' $> NTContact

nameLabelP :: AT.Parser Text
nameLabelP = T.intercalate "-" <$> AT.takeWhile1 (\c -> isNameLetter c || isDigit c) `AT.sepBy1` AT.char '-'
  where
    isNameLetter c = isAlpha c && not (c >= '\x00c0' && c <= '\x024f')

instance StrEncoding SimplexNameInfo where
  strEncode SimplexNameInfo {nameType, nameDomain} =
    "simplex:/name" <> strEncode nameType <> strEncode nameDomain
  strP = optional "simplex:/name" *> ((strP >>= infoP) <|> infoP NTPublicGroup)
    where
      infoP NTPublicGroup = SimplexNameInfo NTPublicGroup <$> (strP <|> bareName)
      infoP NTContact = SimplexNameInfo NTContact <$> strP
      bareName = parseBare . safeDecodeUtf8 <$?> A.takeWhile1 (not . A.isSpace)
      parseBare s = (\name -> SimplexNameDomain TLDSimplex name []) <$> AT.parseOnly (nameLabelP <* AT.endOfInput) s

instance StrEncoding SimplexNameDomain where
  strEncode = encodeUtf8 . fullDomainName
  strP = parseDomain . safeDecodeUtf8 <$?> A.takeWhile1 (not . A.isSpace)
    where
      parseDomain s = AT.parseOnly (nameLabelP `AT.sepBy1` AT.char '.' <* AT.endOfInput) s >>= mkDomain
      -- TLD label compared lowercase: DNS labels are case-insensitive, and a
      -- mixed-case `foo.SIMPLEX` would otherwise fall through to TLDWeb and
      -- route through `registry_tld_all` instead of `registry_tld_simplex`.
      mkDomain labels = case reverse labels of
        [] -> Left "empty name"
        [_] -> Left "domain requires TLD"
        tld : name : sub -> Right $ case T.toLower tld of
          "simplex" -> SimplexNameDomain TLDSimplex name sub
          "testing" -> SimplexNameDomain TLDTesting name sub
          _ -> SimplexNameDomain TLDWeb (T.intercalate "." labels) []

fullDomainName :: SimplexNameDomain -> Text
fullDomainName SimplexNameDomain {nameTLD, domain, subDomain} = T.intercalate "." (reverse subDomain ++ [domain] ++ tld')
  where
    tld' = case nameTLD of
      TLDSimplex -> ["simplex"]
      TLDTesting -> ["testing"]
      TLDWeb -> []

shortNameInfoStr :: SimplexNameInfo -> Text
shortNameInfoStr = \case
  SimplexNameInfo {nameType = NTPublicGroup, nameDomain = SimplexNameDomain {nameTLD = TLDSimplex, domain, subDomain = []}} -> "#" <> domain
  info -> pfx <> fullDomainName (nameDomain info)
    where
      pfx = case nameType info of
        NTPublicGroup -> "#"
        NTContact -> "@"

$(J.deriveJSON (enumJSON $ dropPrefix "TLD") ''SimplexTLD)

$(J.deriveJSON (enumJSON $ dropPrefix "NT") ''SimplexNameType)

$(J.deriveJSON defaultJSON ''SimplexNameDomain)

$(J.deriveJSON defaultJSON ''SimplexNameInfo)
