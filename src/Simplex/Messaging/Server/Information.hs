{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.Server.Information where

import qualified Data.Aeson.TH as J
import Data.Int (Int64)
import Data.Text (Text)
import Simplex.Messaging.Agent.Protocol (ConnectionRequestUri, ConnectionMode (..))
import Simplex.Messaging.Parsers (defaultJSON, dropPrefix, enumJSON)

data ServerInformation = ServerInformation
  { config :: ServerPublicConfig,
    information :: Maybe ServerPublicInfo
  }

-- based on server configuration
data ServerPublicConfig = ServerPublicConfig
  { persistence :: ServerPersistenceMode,
    messageExpiration :: Maybe Int64,
    statsEnabled :: Bool,
    newQueuesAllowed :: Bool,
    basicAuthEnabled :: Bool -- server is private if enabled
  }

-- based on INFORMATION section of INI file
data ServerPublicInfo = ServerPublicInfo
  { sourceCode :: Text, -- note that this property is not optional, in line with AGPLv3 license
    usageConditions :: Maybe ServerConditions,
    operator :: Maybe Entity,
    website :: Maybe Text,
    adminContacts :: Maybe ServerContactAddress,
    complaintsContacts :: Maybe ServerContactAddress,
    hosting :: Maybe Entity,
    serverCountry :: Maybe Text
  }

data ServerPersistenceMode = SPMMemoryOnly | SPMQueues | SPMMessages

data ServerConditions = ServerConditions {conditions :: Text, amendments :: Maybe Text}

data Entity = Entity {name :: Text, country :: Maybe Text}

data ServerContactAddress = ServerContactAddress
  { simplex :: Maybe (ConnectionRequestUri 'CMContact),
    email :: Maybe Text, -- it is recommended that it matches DNS email address, if either is present
    pgp :: Maybe Text
  }

$(J.deriveJSON (enumJSON $ dropPrefix "SPM") ''ServerPersistenceMode)

$(J.deriveJSON defaultJSON ''ServerConditions)

$(J.deriveJSON defaultJSON ''Entity)

$(J.deriveJSON defaultJSON ''ServerContactAddress)

$(J.deriveJSON defaultJSON ''ServerPublicConfig)

$(J.deriveJSON defaultJSON ''ServerPublicInfo)

$(J.deriveJSON defaultJSON ''ServerInformation)
