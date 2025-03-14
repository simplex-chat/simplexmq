{-# LANGUAGE CPP #-}

module Simplex.Messaging.Server.Main.Options where

import qualified Data.List.NonEmpty as L
import Data.Text (Text)
import Network.Socket (HostName)
import Simplex.Messaging.Protocol (BasicAuth)
import Simplex.Messaging.Server.CLI (SignAlgorithm)
import Simplex.Messaging.Server.Information (ServerPublicInfo)
import Simplex.Messaging.Transport.Client (SocksProxy, TransportHost)

#if defined(dbServerPostgres)
import Simplex.Messaging.Agent.Store.Postgres.Common (DBOpts (..))
#endif

data InitOptions = InitOptions
  { enableStoreLog :: Bool,
#if defined(dbServerPostgres)
    dbOptions :: DBOpts,
#endif
    logStats :: Bool,
    signAlgorithm :: SignAlgorithm,
    ip :: HostName,
    fqdn :: Maybe HostName,
    password :: Maybe ServerPassword,
    controlPort :: Maybe Int,
    socksProxy :: Maybe SocksProxy,
    ownDomains :: Maybe (L.NonEmpty TransportHost),
    sourceCode :: Maybe Text,
    serverInfo :: ServerPublicInfo,
    operatorCountry :: Maybe Text,
    hostingCountry :: Maybe Text,
    webStaticPath :: Maybe FilePath,
    disableWeb :: Bool,
    scripted :: Bool
  }
  deriving (Show)

data ServerPassword = ServerPassword BasicAuth | SPRandom
  deriving (Show)
