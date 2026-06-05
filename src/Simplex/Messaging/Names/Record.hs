{-# LANGUAGE LambdaCase #-}
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
import Simplex.Messaging.Parsers (defaultJSON)

-- | Resolved name record returned by the names role.
--   Wire format is JSON — change requires an SMP version bump.
--   JSON keys match the Python resolver (PR #1795 `snrc-resolve.py`) so the
--   same server can be backed by either the direct-ETH-RPC resolver or the
--   Python REST resolver without changing the wire format clients see.
data NameRecord = NameRecord
  { nrName :: Text,
    nrNickname :: Maybe Text,
    nrWebsite :: Maybe Text,
    nrLocation :: Maybe Text,
    nrSimplexContact :: Maybe Text,
    nrSimplexChannel :: Maybe Text,
    nrEth :: Maybe Text,
    nrBtc :: Maybe Text,
    nrXmr :: Maybe Text,
    nrDot :: Maybe Text,
    nrOwner :: NameOwner,
    nrResolver :: NameOwner -- SNRC contract address that produced the record
  }
  deriving (Eq, Show)

-- ToJSON / toEncoding are TH-derived from a single Options value so both Aeson
-- paths emit byte-identical output in declaration order. The default
-- fieldLabelModifier cannot express dot-keys ("simplex.contact",
-- "simplex.channel") or uppercase coin keys ("ETH", "BTC", "XMR", "DOT").
-- omitNothingFields is set to False to preserve the previous hand-rolled
-- shape (absent optionals emitted as JSON `null`); FromJSON tolerates both
-- missing and null keys for forward-compat with sparse Python output.
-- Options inlined at the splice site because TH stage restriction forbids a
-- module-local helper.
$( JQ.deriveToJSON
    defaultJSON
      { J.omitNothingFields = False,
        J.fieldLabelModifier = \case
          "nrName" -> "name"
          "nrNickname" -> "nickname"
          "nrWebsite" -> "website"
          "nrLocation" -> "location"
          "nrSimplexContact" -> "simplex.contact"
          "nrSimplexChannel" -> "simplex.channel"
          "nrEth" -> "ETH"
          "nrBtc" -> "BTC"
          "nrXmr" -> "XMR"
          "nrDot" -> "DOT"
          "nrOwner" -> "owner"
          "nrResolver" -> "resolver"
          s -> s
      }
    ''NameRecord
 )

-- FromJSON is hand-rolled to enforce per-field UTF-8 byte-length caps that the
-- TH derivation cannot express.
instance J.FromJSON NameRecord where
  parseJSON = J.withObject "NameRecord" $ \o -> do
    nrName <- o J..: "name" >>= capUtf8 "name" 255
    nrNickname <- o J..:? "nickname" >>= traverse (capUtf8 "nickname" 255)
    nrWebsite <- o J..:? "website" >>= traverse (capUtf8 "website" 255)
    nrLocation <- o J..:? "location" >>= traverse (capUtf8 "location" 255)
    nrSimplexContact <- o J..:? "simplex.contact" >>= traverse (capUtf8 "simplex.contact" 1024)
    nrSimplexChannel <- o J..:? "simplex.channel" >>= traverse (capUtf8 "simplex.channel" 1024)
    nrEth <- o J..:? "ETH" >>= traverse (capUtf8 "ETH" 255)
    nrBtc <- o J..:? "BTC" >>= traverse (capUtf8 "BTC" 255)
    nrXmr <- o J..:? "XMR" >>= traverse (capUtf8 "XMR" 255)
    nrDot <- o J..:? "DOT" >>= traverse (capUtf8 "DOT" 255)
    nrOwner <- o J..: "owner"
    nrResolver <- o J..: "resolver"
    pure NameRecord {nrName, nrNickname, nrWebsite, nrLocation, nrSimplexContact, nrSimplexChannel, nrEth, nrBtc, nrXmr, nrDot, nrOwner, nrResolver}
    where
      capUtf8 fld lim t
        | B.length (encodeUtf8 t) <= lim = pure t
        | otherwise = fail $ fld <> " exceeds " <> show lim <> " bytes UTF-8"
