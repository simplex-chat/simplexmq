{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.SimplexName
  ( SimplexNameInfo (..),
    SimplexDomain (..),
    SimplexTLD (..),
    SimplexNameType (..),
    fullDomainName,
    LabelHash (..),
    labelHash,
    labelHashText,
    shortNameInfoStr,
  )
where

import Control.Applicative (optional, (<|>))
import Crypto.Hash (Digest, hash)
import Crypto.Hash.Algorithms (Keccak_256)
import qualified Data.Aeson.TH as J
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.Attoparsec.Text as AT
import qualified Data.ByteArray as BA
import qualified Data.ByteArray.Encoding as BAE
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isDigit)
import Data.Functor (($>))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Simplex.Messaging.Agent.Store.DB (FromField (..), ToField (..), fromTextField_)
import Simplex.Messaging.Encoding (Encoding (..))
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (defaultJSON, dropPrefix, enumJSON)
import Simplex.Messaging.Util (eitherToMaybe, safeDecodeUtf8, (<$?>))

data SimplexNameInfo = SimplexNameInfo
  { nameType :: SimplexNameType,
    nameDomain :: SimplexDomain
  }
  deriving (Eq, Show)

data SimplexDomain = SimplexDomain
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
nameLabelP = do
  label <- T.intercalate "-" <$> AT.takeWhile1 (\c -> isNameLetter c || isDigit c) `AT.sepBy1` AT.char '-'
  -- DNS label limit: each dot-separated component is at most 63 bytes (labels
  -- are ASCII, so character count == byte count)
  if T.length label > 63 then fail "name label exceeds 63 bytes" else pure label
  where
    -- ASCII letters only. SNRC contracts hash byte sequences via keccak; ENS
    -- uses UTS-46 + Punycode for IDN, which we do not implement. Admitting
    -- Cyrillic / Greek / etc. via Data.Char.isAlpha would (a) make namehash
    -- diverge from any IDN-aware registrar and (b) allow homograph spoofing
    -- (Cyrillic а vs ASCII a hash to different on-chain records).
    isNameLetter c = c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'

-- | A second-level label sent as its keccak256 hash, so a router never learns
-- the name. ENS's bracket form: brackets are outside the name character set, so
-- it cannot collide with a real name. 66 chars, so exempt from the label limit.
-- | The registry's key for a label, and what BaseRegistrarImplementation.labelOf
-- is keyed on. Always 32 bytes, so it is never told from a name by its shape.
newtype LabelHash = LabelHash ByteString
  deriving (Eq, Show)

instance Encoding LabelHash where
  smpEncode (LabelHash h) = h
  smpP = LabelHash <$> A.take 32

-- | keccak-256 of the lowercased label. Only a second-level label is a registry
-- key: subname labels are needed as text to reach the record.
labelHash :: Text -> LabelHash
labelHash label = LabelHash $ BA.convert (hash (encodeUtf8 (T.toLower label)) :: Digest Keccak_256)

-- | How the backing resolver is addressed for a hashed label: ENS's encoding
-- for a label whose text is unknown. The SMP protocol never parses this form -
-- it tags the choice instead - so the brackets live here alone.
labelHashText :: LabelHash -> Text
labelHashText (LabelHash h) = "[" <> decodeLatin1 (BAE.convertToBase BAE.Base16 h) <> "]"

-- | Cap the name at 253 bytes (DNS full-domain limit)
boundedNonSpace :: A.Parser ByteString
boundedNonSpace = do
  bs <- A.scan (0 :: Int) $ \i c ->
    if i <= 253 && not (A.isSpace c) then Just (i + 1) else Nothing
  if B.null bs
    then fail "expected non-empty name token"
    else if B.length bs > 253 then fail "name exceeds 253 bytes" else pure bs

instance StrEncoding SimplexNameInfo where
  strEncode SimplexNameInfo {nameType, nameDomain} =
    strEncode nameType <> strEncode nameDomain
  strP = optional "simplex:/name" *> ((strP >>= infoP) <|> infoP NTPublicGroup)
    where
      infoP NTPublicGroup = SimplexNameInfo NTPublicGroup <$> (strP <|> bareName)
      infoP NTContact = SimplexNameInfo NTContact <$> strP
      bareName = parseBare . safeDecodeUtf8 <$?> boundedNonSpace
      parseBare s = (\name -> SimplexDomain TLDSimplex (T.toLower name) []) <$> AT.parseOnly (nameLabelP <* AT.endOfInput) s

instance StrEncoding SimplexDomain where
  strEncode = encodeUtf8 . fullDomainName
  strP = parseDomain . safeDecodeUtf8 <$?> boundedNonSpace
    where
      parseDomain s = AT.parseOnly (nameLabelP `AT.sepBy1` AT.char '.' <* AT.endOfInput) s >>= mkDomain
      mkDomain labels = case reverse lowered of
        [] -> Left "empty name"
        [_] -> Left "domain requires TLD"
        "simplex" : name : sub -> Right (SimplexDomain TLDSimplex name sub)
        "testing" : name : sub -> Right (SimplexDomain TLDTesting name sub)
        _ -> Right (SimplexDomain TLDWeb (T.intercalate "." lowered) [])
        where
          lowered = map T.toLower labels

instance Encoding SimplexDomain where
  smpEncode = strEncode
  smpP = strP

instance Encoding SimplexTLD where
  smpEncode = \case
    TLDSimplex -> "s"
    TLDTesting -> "t"
    TLDWeb -> "w"
  smpP =
    A.anyChar >>= \case
      's' -> pure TLDSimplex
      't' -> pure TLDTesting
      'w' -> pure TLDWeb
      _ -> fail "bad SimplexTLD"

fullDomainName :: SimplexDomain -> Text
fullDomainName SimplexDomain {nameTLD, domain, subDomain} = T.intercalate "." (reverse subDomain ++ [domain] ++ tld')
  where
    tld' = case nameTLD of
      TLDSimplex -> ["simplex"]
      TLDTesting -> ["testing"]
      TLDWeb -> []

shortNameInfoStr :: SimplexNameInfo -> Text
shortNameInfoStr = \case
  SimplexNameInfo {nameType = NTPublicGroup, nameDomain = SimplexDomain {nameTLD = TLDSimplex, domain, subDomain = []}} -> "#" <> domain
  info -> pfx <> fullDomainName (nameDomain info)
    where
      pfx = case nameType info of
        NTPublicGroup -> "#"
        NTContact -> "@"

instance ToField SimplexDomain where toField = toField . decodeLatin1 . strEncode

instance FromField SimplexDomain where fromField = fromTextField_ (eitherToMaybe . strDecode . encodeUtf8)

$(J.deriveJSON (enumJSON $ dropPrefix "TLD") ''SimplexTLD)

$(J.deriveJSON (enumJSON $ dropPrefix "NT") ''SimplexNameType)

$(J.deriveJSON defaultJSON ''SimplexDomain)

$(J.deriveJSON defaultJSON ''SimplexNameInfo)
