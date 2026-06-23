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
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isDigit)
import Data.Functor (($>))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Simplex.Messaging.Agent.Store.DB (ToField (..))
import Simplex.Messaging.Encoding (Encoding (..))
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
    -- ASCII letters only. SNRC contracts hash byte sequences via keccak; ENS
    -- uses UTS-46 + Punycode for IDN, which we do not implement. Admitting
    -- Cyrillic / Greek / etc. via Data.Char.isAlpha would (a) make namehash
    -- diverge from any IDN-aware registrar and (b) allow homograph spoofing
    -- (Cyrillic а vs ASCII a hash to different on-chain records).
    isNameLetter c = c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'

-- | DoS defense for the bare-name / bare-domain entry points. The outer
-- parser would otherwise `takeWhile1 (not . isSpace)` unbounded, allowing
-- a crafted multi-megabyte token to be decoded and re-parsed before any
-- validation. Cap at 253 bytes (DNS full-domain limit) — generous against
-- any realistic SimpleX name — and forces the surrounding `parseOnly`
-- (which requires consuming all input) to fail on oversized inputs.
boundedNonSpace :: A.Parser ByteString
boundedNonSpace = do
  bs <- A.scan (0 :: Int) $ \i c ->
    if i < 253 && not (A.isSpace c) then Just (i + 1) else Nothing
  if B.null bs then fail "expected non-empty name token" else pure bs

instance StrEncoding SimplexNameInfo where
  strEncode SimplexNameInfo {nameType, nameDomain} =
    "simplex:/name" <> strEncode nameType <> strEncode nameDomain
  strP = optional "simplex:/name" *> ((strP >>= infoP) <|> infoP NTPublicGroup)
    where
      infoP NTPublicGroup = SimplexNameInfo NTPublicGroup <$> (strP <|> bareName)
      infoP NTContact = SimplexNameInfo NTContact <$> strP
      bareName = parseBare . safeDecodeUtf8 <$?> boundedNonSpace
      parseBare s = (\name -> SimplexNameDomain TLDSimplex (T.toLower name) []) <$> AT.parseOnly (nameLabelP <* AT.endOfInput) s

instance StrEncoding SimplexNameDomain where
  strEncode = encodeUtf8 . fullDomainName
  strP = parseDomain . safeDecodeUtf8 <$?> boundedNonSpace
    where
      parseDomain s = AT.parseOnly (nameLabelP `AT.sepBy1` AT.char '.' <* AT.endOfInput) s >>= mkDomain
      -- All labels lowercased: DNS labels are case-insensitive, and namehash is
      -- byte-defined — preserving original case would make `Alice.simplex` and
      -- `alice.simplex` resolve to different on-chain records. A mixed-case TLD
      -- would also fall through to TLDWeb and route through the `tldAll`
      -- catch-all entry instead of the TLDSimplex registry.
      mkDomain labels = case reverse lowered of
        [] -> Left "empty name"
        [_] -> Left "domain requires TLD"
        "simplex" : name : sub -> Right (SimplexNameDomain TLDSimplex name sub)
        "testing" : name : sub -> Right (SimplexNameDomain TLDTesting name sub)
        _ -> Right (SimplexNameDomain TLDWeb (T.intercalate "." lowered) [])
        where
          lowered = map T.toLower labels

-- Wire encoding for the RSLV command: the domain is the trailing field, so it
-- encodes as the raw StrEncoding bytes (no length prefix) and parses to end.
instance Encoding SimplexNameDomain where
  smpEncode = strEncode
  smpP = strP

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

-- | Stored as TEXT. The matching `FromField` instance is intentionally not
-- defined: existing consumers want soft-decode semantics (parse failure
-- degrades to `Nothing` rather than failing the row), which doesn't
-- compose with `fromTextField_`. Add a `FromField` instance here only
-- when a consumer wants the row-fail behaviour and document the divide.
instance ToField SimplexNameInfo where toField = toField . decodeLatin1 . strEncode

$(J.deriveJSON (enumJSON $ dropPrefix "TLD") ''SimplexTLD)

$(J.deriveJSON (enumJSON $ dropPrefix "NT") ''SimplexNameType)

$(J.deriveJSON defaultJSON ''SimplexNameDomain)

$(J.deriveJSON defaultJSON ''SimplexNameInfo)
