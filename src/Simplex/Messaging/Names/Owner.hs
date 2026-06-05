{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Simplex.Messaging.Names.Owner
  ( NameOwner,
    mkNameOwner,
    unNameOwner,
  )
where

import Control.Applicative ((<|>))
import qualified Data.Aeson as J
import qualified Data.ByteArray.Encoding as BAE
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1, encodeUtf8)

-- | 20-byte Ethereum address (NameRecord owner). Bare constructor not exported;
-- use `mkNameOwner` to enforce the 20-byte invariant.
newtype NameOwner = NameOwner ByteString
  deriving (Eq)

-- Render the 20 raw bytes as "0x"-prefixed lowercase hex so log lines /
-- traceShow output match the on-the-wire JSON form instead of Latin-1 garbage.
instance Show NameOwner where
  show (NameOwner bs) = "NameOwner 0x" <> B.unpack (BAE.convertToBase BAE.Base16 bs)

mkNameOwner :: ByteString -> Either String NameOwner
mkNameOwner bs
  | B.length bs == 20 = Right (NameOwner bs)
  | otherwise = Left "NameOwner must be 20 bytes"

unNameOwner :: NameOwner -> ByteString
unNameOwner (NameOwner bs) = bs
{-# INLINE unNameOwner #-}

instance J.ToJSON NameOwner where
  toJSON (NameOwner bs) = J.String $ "0x" <> decodeLatin1 (BAE.convertToBase BAE.Base16 bs)

instance J.FromJSON NameOwner where
  parseJSON = J.withText "NameOwner" $ \t -> do
    -- Accept "0x" and "0X" prefixes (matches the Server-side hex decoder).
    let hex = fromMaybe t (T.stripPrefix "0x" t <|> T.stripPrefix "0X" t)
    either fail pure $ BAE.convertFromBase BAE.Base16 (encodeUtf8 hex) >>= mkNameOwner
