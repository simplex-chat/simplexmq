{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.Server.Information
  ( ServerInformation (..),
    ServerPublicConfig (..),
    ServerPublicInfo (..),
    ServerPersistenceMode (..),
    ServerConditions (..),
    HostingType (..),
    Entity (..),
    ServerContactAddress (..),
    PGPKey (..),
    emptyServerInfo,
    hasServerInfo,
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Aeson.TH as J
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import Simplex.Messaging.Agent.Protocol (ConnectionLink, ConnectionMode (..))
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (defaultJSON, dropPrefix, enumJSON)

data ServerInformation = ServerInformation
  { config :: ServerPublicConfig,
    information :: Maybe ServerPublicInfo
  }
  deriving (Show)

-- based on server configuration
data ServerPublicConfig = ServerPublicConfig
  { persistence :: ServerPersistenceMode,
    messageExpiration :: Maybe Int64,
    statsEnabled :: Bool,
    newQueuesAllowed :: Bool,
    basicAuthEnabled :: Bool -- server is private if enabled
  }
  deriving (Show)

-- based on INFORMATION section of INI file
data ServerPublicInfo = ServerPublicInfo
  { sourceCode :: Text, -- note that this property is not optional, in line with AGPLv3 license
    usageConditions :: Maybe ServerConditions,
    operator :: Maybe Entity,
    website :: Maybe Text,
    adminContacts :: Maybe ServerContactAddress,
    complaintsContacts :: Maybe ServerContactAddress,
    hosting :: Maybe Entity,
    hostingType :: Maybe HostingType,
    serverCountry :: Maybe Text
  }
  deriving (Show)

emptyServerInfo :: Text -> ServerPublicInfo
emptyServerInfo sourceCode =
  ServerPublicInfo
    { sourceCode,
      usageConditions = Nothing,
      operator = Nothing,
      website = Nothing,
      adminContacts = Nothing,
      complaintsContacts = Nothing,
      hosting = Nothing,
      hostingType = Nothing,
      serverCountry = Nothing
    }

hasServerInfo :: ServerPublicInfo -> Bool
hasServerInfo ServerPublicInfo {usageConditions, operator, website, adminContacts, complaintsContacts, hosting, hostingType, serverCountry} =
  isJust usageConditions || isJust operator || isJust website || isJust adminContacts || isJust complaintsContacts || isJust hosting || isJust hostingType || isJust serverCountry

data ServerPersistenceMode = SPMMemoryOnly | SPMQueues | SPMMessages
  deriving (Show)

data ServerConditions = ServerConditions {conditions :: Text, amendments :: Maybe Text}
  deriving (Show)

data HostingType = HTVirtual | HTDedicated | HTColocation | HTOwned
  deriving (Show)

instance StrEncoding HostingType where
  strEncode = \case
    HTVirtual -> "virtual"
    HTDedicated -> "dedicated"
    HTColocation -> "colocation"
    HTOwned -> "owned"
  strP =
    A.takeTill (== ' ') >>= \case
      "virtual" -> pure HTVirtual
      "dedicated" -> pure HTDedicated
      "colocation" -> pure HTColocation
      "owned" -> pure HTOwned
      _ -> fail "bad HostingType"

instance FromJSON HostingType where
  parseJSON = strParseJSON "HostingType"

instance ToJSON HostingType where
  toJSON = strToJSON
  toEncoding = strToJEncoding

data Entity = Entity {name :: Text, country :: Maybe Text}
  deriving (Show)

data ServerContactAddress = ServerContactAddress
  { simplex :: Maybe (ConnectionLink 'CMContact),
    email :: Maybe Text, -- it is recommended that it matches DNS email address, if either is present
    pgp :: Maybe PGPKey
  }
  deriving (Show)

data PGPKey = PGPKey {pkURI :: Text, pkFingerprint :: Text}
  deriving (Show)

$(J.deriveJSON (enumJSON $ dropPrefix "SPM") ''ServerPersistenceMode)

$(J.deriveJSON defaultJSON ''ServerConditions)

$(J.deriveJSON defaultJSON ''Entity)

$(J.deriveJSON defaultJSON ''PGPKey)

$(J.deriveJSON defaultJSON ''ServerContactAddress)

$(J.deriveJSON defaultJSON ''ServerPublicConfig)

$(J.deriveJSON defaultJSON ''ServerPublicInfo)

$(J.deriveJSON defaultJSON ''ServerInformation)
