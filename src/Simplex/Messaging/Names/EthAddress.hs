{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Simplex.Messaging.Names.EthAddress
  ( EthAddress,
    mkEthAddress,
    unEthAddress,
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
import Simplex.Messaging.Encoding (Encoding (..))

-- | 20-byte Ethereum address (NameRecord owner / resolver). Bare constructor
-- not exported; use 'mkEthAddress' to enforce the 20-byte invariant. JSON form
-- is "0x"-prefixed lowercase hex (matches the resolver output).
newtype EthAddress = EthAddress {unEthAddress :: ByteString}
  deriving (Eq, Show)

mkEthAddress :: ByteString -> Either String EthAddress
mkEthAddress bs
  | B.length bs == 20 = Right (EthAddress bs)
  | otherwise = Left "EthAddress must be 20 bytes"

-- Wire: length-prefixed raw bytes (via the ByteString instance); parse enforces
-- the 20-byte invariant.
instance Encoding EthAddress where
  smpEncode = smpEncode . unEthAddress
  smpP = smpP >>= either fail pure . mkEthAddress

instance J.ToJSON EthAddress where
  toJSON (EthAddress bs) = J.String $ "0x" <> decodeLatin1 (BAE.convertToBase BAE.Base16 bs)

instance J.FromJSON EthAddress where
  parseJSON = J.withText "EthAddress" $ \t -> do
    -- Accept "0x" and "0X" prefixes (matches the server-side hex decoder).
    let hex = fromMaybe t (T.stripPrefix "0x" t <|> T.stripPrefix "0X" t)
    either fail pure $ BAE.convertFromBase BAE.Base16 (encodeUtf8 hex) >>= mkEthAddress
