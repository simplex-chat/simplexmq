{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.Names.Record
  ( NameRecord (..),
  )
where

import qualified Data.Aeson as J
import qualified Data.Aeson.TH as JQ
import qualified Data.ByteString.Char8 as B
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Simplex.Messaging.Names.Owner (NameOwner)
import Simplex.Messaging.Parsers (defaultJSON, dropPrefix)

-- | Resolved name record returned by the names role.
--   Wire format is JSON — change requires an SMP version bump.
--   JSON keys match the Python REST resolver (`snrc-resolve.py`).
--   Text fields use the empty string as the "unset" sentinel; coin fields
--   use JSON `null`. simplexContact / simplexChannel are arrays of links
--   (primary first, empty array when unset) so a name can advertise fallback
--   SMP servers. `owner` and `resolver` carry 20-byte addresses encoded as
--   `0x`-prefixed lowercase hex (see Names.Owner).
data NameRecord = NameRecord
  { nrName :: Text,
    nrNickname :: Text,
    nrWebsite :: Text,
    nrLocation :: Text,
    nrSimplexContact :: [Text],
    nrSimplexChannel :: [Text],
    nrEth :: Maybe Text,
    nrBtc :: Maybe Text,
    nrXmr :: Maybe Text,
    nrDot :: Maybe Text,
    nrOwner :: NameOwner,
    nrResolver :: NameOwner -- resolver address that produced the record
  }
  deriving (Eq, Show)

-- ToJSON / toEncoding TH-derived from a single Options value so both Aeson
-- paths emit byte-identical output in declaration order. omitNothingFields
-- is False so absent coin fields surface as JSON `null` (matches the Python
-- resolver output for unset coins).
$( JQ.deriveToJSON
    defaultJSON {J.omitNothingFields = False, J.fieldLabelModifier = dropPrefix "nr"}
    ''NameRecord
 )

-- Each link field holds up to maxLinks entries totalling at most maxLinkBytes
-- UTF-8 bytes -- the same byte budget as the former single-string field, so the
-- proxied NameRecord size is unchanged. Entries are ordered primary-first.
-- maxLinks matches the dApp's authoring cap (ens-app-v3 MultiUrlField
-- MULTI_URL_FIELD_CAP = 5); records with more entries are non-conforming.
maxLinks :: Int
maxLinks = 5

maxLinkBytes :: Int
maxLinkBytes = 1024

-- FromJSON is hand-rolled to enforce per-field UTF-8 byte-length caps that
-- TH derivation cannot express.
instance J.FromJSON NameRecord where
  parseJSON = J.withObject "NameRecord" $ \o -> do
    nrName <- o J..: "name" >>= capUtf8 "name" 255
    nrNickname <- o J..: "nickname" >>= capUtf8 "nickname" 255
    nrWebsite <- o J..: "website" >>= capUtf8 "website" 255
    nrLocation <- o J..: "location" >>= capUtf8 "location" 255
    nrSimplexContact <- o J..: "simplexContact" >>= capLinks "simplexContact"
    nrSimplexChannel <- o J..: "simplexChannel" >>= capLinks "simplexChannel"
    nrEth <- o J..:? "eth" >>= traverse (capUtf8 "eth" 255)
    nrBtc <- o J..:? "btc" >>= traverse (capUtf8 "btc" 255)
    nrXmr <- o J..:? "xmr" >>= traverse (capUtf8 "xmr" 255)
    nrDot <- o J..:? "dot" >>= traverse (capUtf8 "dot" 255)
    nrOwner <- o J..: "owner"
    nrResolver <- o J..: "resolver"
    pure NameRecord {nrName, nrNickname, nrWebsite, nrLocation, nrSimplexContact, nrSimplexChannel, nrEth, nrBtc, nrXmr, nrDot, nrOwner, nrResolver}
    where
      capUtf8 fld lim t
        | B.length (encodeUtf8 t) <= lim = pure t
        | otherwise = fail $ fld <> " exceeds " <> show lim <> " bytes UTF-8"
      capLinks fld links
        | length links > maxLinks =
            fail $ fld <> " exceeds " <> show maxLinks <> " entries"
        | sum (map (B.length . encodeUtf8) links) > maxLinkBytes =
            fail $ fld <> " entries exceed " <> show maxLinkBytes <> " bytes UTF-8"
        | otherwise = pure links
