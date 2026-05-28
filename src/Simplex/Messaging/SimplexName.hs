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
    SimplexTLD (..),
    SimplexNameType (..),
    fullDomainName,
    shortNameInfoStr,
  )
where

import Control.Applicative (optional, (<|>))
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.Attoparsec.Text as AT
import qualified Data.Aeson.TH as J
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
    nameTLD :: SimplexTLD,
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

instance StrEncoding SimplexNameInfo where
  strEncode info = "simplex:/name" <> strEncode (nameType info) <> encodeUtf8 (fullDomainName info)
  strP = optional "simplex:/name" *> (strP >>= nameP) <|> nameP NTPublicGroup
    where
      nameP nt = parseName nt . safeDecodeUtf8 <$?> A.takeWhile1 (not . A.isSpace)
      parseName nt s = AT.parseOnly (nameLabelP `AT.sepBy1` AT.char '.' <* AT.endOfInput) s >>= mkNameInfo nt
      nameLabelP = T.intercalate "-" <$> AT.takeWhile1 (\c -> isNameLetter c || isDigit c) `AT.sepBy1` AT.char '-'
      isNameLetter c = isAlpha c && not (c >= '\x00c0' && c <= '\x024f')
      mkNameInfo nt labels = case reverse labels of
        [] -> Left "empty name"
        [name]
          | nt == NTPublicGroup -> Right $ SimplexNameInfo nt TLDSimplex name []
          | otherwise -> Left "contact name requires TLD"
        tld : name : sub -> Right $ case tld of
          "simplex" -> SimplexNameInfo nt TLDSimplex name sub
          "testing" -> SimplexNameInfo nt TLDTesting name sub
          _ -> SimplexNameInfo nt TLDWeb (T.intercalate "." labels) []

fullDomainName :: SimplexNameInfo -> Text
fullDomainName SimplexNameInfo {nameTLD, domain, subDomain} = T.intercalate "." (reverse subDomain ++ [domain] ++ tld')
  where
    tld' = case nameTLD of
      TLDSimplex -> ["simplex"]
      TLDTesting -> ["testing"]
      TLDWeb -> []

shortNameInfoStr :: SimplexNameInfo -> Text
shortNameInfoStr = \case
  SimplexNameInfo {nameType = NTPublicGroup, nameTLD = TLDSimplex, domain, subDomain = []} -> "#" <> domain
  info -> pfx <> fullDomainName info
    where
      pfx = case nameType info of
        NTPublicGroup -> "#"
        NTContact -> "@"

$(J.deriveJSON (enumJSON $ dropPrefix "TLD") ''SimplexTLD)

$(J.deriveJSON (enumJSON $ dropPrefix "NT") ''SimplexNameType)

$(J.deriveJSON defaultJSON ''SimplexNameInfo)
