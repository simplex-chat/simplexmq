{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.Names.Record
  ( NameRecord (..),
    NameRegistration (..),
    NamePricing (..),
    USDCents (..),
    NameReservedReason (..),
    oldRegistration,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Aeson as J
import qualified Data.Aeson.TH as JQ
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (defaultJSON, dropPrefix, sumTypeJSON)
import Simplex.Messaging.SystemTime (SystemSeconds)

-- | Resolved name record returned by the names role. JSON keys match the
--   resolver REST output; both FromJSON (resolver -> server) and ToJSON
--   (server diagnostics) are TH-derived from one Options value, so the Haskell
--   type IS the schema. Text fields use the empty string as the "unset"
--   sentinel; coin fields use JSON null. simplexContact / simplexChannel are
--   arrays of links (primary first, empty when unset) so a name can advertise
--   fallback SMP servers. owner / resolver are 0x-hex Ethereum addresses, kept
--   verbatim as text (the resolver is the source of truth for their validity).
--   The only size bound is the SMP transport block (enforced by the framing).
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
    nrOwner :: Text,
    nrResolver :: Text -- resolver address (0x hex) that produced the record
  }
  deriving (Eq, Show)

-- omitNothingFields False so absent coin fields surface as JSON null (matches
-- the resolver output for unset coins).
$( JQ.deriveJSON
    defaultJSON {J.omitNothingFields = False, J.fieldLabelModifier = dropPrefix "nr"}
    ''NameRecord
 )

-- | US cents, rounded up so a quote is never below what is charged.
newtype USDCents = USDCents Int64
  deriving (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

-- | What the registry holds for a name.
data NameRegistration
  = -- | Held by someone. Always carries a record, empty where none was set.
    NRRegistered
      { -- | absent only from a v20/v21 router, which sent the record alone
        expires :: Maybe SystemSeconds,
        -- | unix seconds, > expires: until here only the owner may renew
        graceUntil :: Maybe SystemSeconds,
        -- | held back as well, which is why it will not free up at expiry
        reservedReason_ :: Maybe NameReservedReason,
        nameRecord :: NameRecord
      }
  | -- | Held by nobody, and registrable now.
    NRAvailable {pricing :: NamePricing}
  | -- | Held back by the registry, and not for sale at its price.
    NRReserved {reservedReason :: NameReservedReason}
  deriving (Eq, Show)

-- | Enough to price the name locally, which the router cannot do behind a hash.
data NamePricing = NamePricing
  { -- | US cents per year, for the lengths the registry prices specially
    registrationPrices :: Map Int USDCents,
    -- | US cents per year for every other length
    basePrice :: USDCents,
    -- | characters; the registry refuses shorter labels
    minLabelLength :: Int
  }
  deriving (Eq, Show)

-- | Why the registry holds a name back.
data NameReservedReason
  = -- | held for SimpleX
    NRRInternal
  | NRRTrademark
  | NRRCommunity
  | -- | added to the registry after this version, and still reserved
    NRRUnknown Text
  deriving (Eq, Show)

instance TextEncoding NameReservedReason where
  textEncode = \case
    NRRInternal -> "internal"
    NRRTrademark -> "trademark"
    NRRCommunity -> "community"
    NRRUnknown t -> t
  textDecode = Just . reservedReasonOf

-- | A reason this version has no word for keeps its own.
reservedReasonOf :: Text -> NameReservedReason
reservedReasonOf = \case
  "internal" -> NRRInternal
  "trademark" -> NRRTrademark
  "community" -> NRRCommunity
  t -> NRRUnknown t

instance ToJSON NameReservedReason where
  toJSON = textToJSON
  toEncoding = textToEncoding

instance FromJSON NameReservedReason where
  parseJSON = textParseJSON "NameReservedReason"

-- | What a v20/v21 router's answer amounts to.
oldRegistration :: NameRecord -> NameRegistration
oldRegistration nameRecord =
  NRRegistered {expires = Nothing, graceUntil = Nothing, reservedReason_ = Nothing, nameRecord}

$(JQ.deriveJSON defaultJSON ''NamePricing)

$(JQ.deriveJSON (sumTypeJSON $ dropPrefix "NR") ''NameRegistration)
