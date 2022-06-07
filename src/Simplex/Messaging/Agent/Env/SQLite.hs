{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Env.SQLite
  ( AgentConfig (..),
    InitialAgentServers (..),
    defaultAgentConfig,
    defaultReconnectInterval,
    Env (..),
    newSMPAgentEnv,
  )
where

import Control.Monad.IO.Unlift
import Crypto.Random
import Data.List.NonEmpty (NonEmpty)
import Data.Time.Clock (NominalDiffTime, nominalDay)
import Network.Socket
import Numeric.Natural
import Simplex.Messaging.Agent.Protocol (SMPServer, currentSMPAgentVersion, supportedSMPAgentVRange)
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store.SQLite
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Client (NtfServer)
import Simplex.Messaging.Transport (TLS, Transport (..))
import Simplex.Messaging.Version
import System.Random (StdGen, newStdGen)
import UnliftIO.STM

data InitialAgentServers = InitialAgentServers
  { smp :: NonEmpty SMPServer,
    ntf :: [NtfServer]
  }

data AgentConfig = AgentConfig
  { tcpPort :: ServiceName,
    cmdSignAlg :: C.SignAlg,
    connIdBytes :: Int,
    tbqSize :: Natural,
    dbFile :: FilePath,
    dbPoolSize :: Int,
    yesToMigrations :: Bool,
    smpCfg :: ProtocolClientConfig,
    ntfCfg :: ProtocolClientConfig,
    reconnectInterval :: RetryInterval,
    helloTimeout :: NominalDiffTime,
    resubscriptionConcurrency :: Int,
    caCertificateFile :: FilePath,
    privateKeyFile :: FilePath,
    certificateFile :: FilePath,
    smpAgentVersion :: Version,
    smpAgentVRange :: VersionRange
  }

defaultReconnectInterval :: RetryInterval
defaultReconnectInterval =
  RetryInterval
    { initialInterval = second,
      increaseAfter = 10 * second,
      maxInterval = 10 * second
    }
  where
    second = 1_000_000

defaultAgentConfig :: AgentConfig
defaultAgentConfig =
  AgentConfig
    { tcpPort = "5224",
      cmdSignAlg = C.SignAlg C.SEd448,
      connIdBytes = 12,
      tbqSize = 64,
      dbFile = "smp-agent.db",
      dbPoolSize = 4,
      yesToMigrations = False,
      smpCfg = defaultClientConfig {defaultTransport = ("5223", transport @TLS)},
      ntfCfg = defaultClientConfig {defaultTransport = ("443", transport @TLS)},
      reconnectInterval = defaultReconnectInterval,
      helloTimeout = 2 * nominalDay,
      resubscriptionConcurrency = 16,
      -- CA certificate private key is not needed for initialization
      -- ! we do not generate these
      caCertificateFile = "/etc/opt/simplex-agent/ca.crt",
      privateKeyFile = "/etc/opt/simplex-agent/agent.key",
      certificateFile = "/etc/opt/simplex-agent/agent.crt",
      smpAgentVersion = 1, -- currentSMPAgentVersion,
      smpAgentVRange = mkVersionRange 1 1 -- supportedSMPAgentVRange
    }

data Env = Env
  { config :: AgentConfig,
    store :: SQLiteStore,
    idsDrg :: TVar ChaChaDRG,
    clientCounter :: TVar Int,
    randomServer :: TVar StdGen
  }

newSMPAgentEnv :: (MonadUnliftIO m, MonadRandom m) => AgentConfig -> m Env
newSMPAgentEnv config@AgentConfig {dbFile, dbPoolSize, yesToMigrations} = do
  idsDrg <- newTVarIO =<< drgNew
  store <- liftIO $ createSQLiteStore dbFile dbPoolSize Migrations.app yesToMigrations
  clientCounter <- newTVarIO 0
  randomServer <- newTVarIO =<< liftIO newStdGen
  return Env {config, store, idsDrg, clientCounter, randomServer}
