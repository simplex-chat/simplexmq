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
import Data.Text (Text)
import Simplex.Messaging.Parsers (defaultJSON, dropPrefix)

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
