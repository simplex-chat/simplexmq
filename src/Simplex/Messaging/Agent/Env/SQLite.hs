{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Env.SQLite
  ( AgentMonad,
    AgentConfig (..),
    InitialAgentServers (..),
    NetworkConfig (..),
    defaultAgentConfig,
    defaultReconnectInterval,
    Env (..),
    newSMPAgentEnv,
    NtfSupervisor (..),
    NtfSupervisorCommand (..),
  )
where

import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random
import Data.List.NonEmpty (NonEmpty)
import Data.Time.Clock (NominalDiffTime, nominalDay)
import Data.Word (Word16)
import Network.Socket
import Numeric.Natural
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store.SQLite
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import Simplex.Messaging.Client
import Simplex.Messaging.Client.Agent ()
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Types
import Simplex.Messaging.Protocol (NtfServer, supportedSMPClientVRange)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (TLS, Transport (..))
import Simplex.Messaging.Transport.Client (defaultSMPPort)
import Simplex.Messaging.Version
import System.Random (StdGen, newStdGen)
import UnliftIO (Async)
import UnliftIO.STM

-- | Agent monad with MonadReader Env and MonadError AgentErrorType
type AgentMonad m = (MonadUnliftIO m, MonadReader Env m, MonadError AgentErrorType m)

data InitialAgentServers = InitialAgentServers
  { smp :: NonEmpty SMPServer,
    ntf :: [NtfServer],
    netCfg :: NetworkConfig
  }

data AgentConfig = AgentConfig
  { tcpPort :: ServiceName,
    cmdSignAlg :: C.SignAlg,
    connIdBytes :: Int,
    tbqSize :: Natural,
    dbFile :: FilePath,
    yesToMigrations :: Bool,
    smpCfg :: ProtocolClientConfig,
    ntfCfg :: ProtocolClientConfig,
    reconnectInterval :: RetryInterval,
    messageRetryInterval :: RetryInterval,
    messageTimeout :: NominalDiffTime,
    helloTimeout :: NominalDiffTime,
    ntfCron :: Word16,
    ntfWorkerDelay :: Int,
    ntfSMPWorkerDelay :: Int,
    ntfSubCheckInterval :: NominalDiffTime,
    ntfMaxMessages :: Int,
    caCertificateFile :: FilePath,
    privateKeyFile :: FilePath,
    certificateFile :: FilePath,
    smpAgentVRange :: VersionRange,
    smpClientVRange :: VersionRange
  }

defaultReconnectInterval :: RetryInterval
defaultReconnectInterval =
  RetryInterval
    { initialInterval = 2_000000,
      increaseAfter = 10_000000,
      maxInterval = 180_000000
    }

defaultMessageRetryInterval :: RetryInterval
defaultMessageRetryInterval =
  RetryInterval
    { initialInterval = 1_000000,
      increaseAfter = 10_000000,
      maxInterval = 60_000000
    }

defaultAgentConfig :: AgentConfig
defaultAgentConfig =
  AgentConfig
    { tcpPort = "5224",
      cmdSignAlg = C.SignAlg C.SEd448,
      connIdBytes = 12,
      tbqSize = 64,
      dbFile = "smp-agent.db",
      yesToMigrations = False,
      smpCfg = defaultClientConfig {defaultTransport = (show defaultSMPPort, transport @TLS)},
      ntfCfg = defaultClientConfig {defaultTransport = ("443", transport @TLS)},
      reconnectInterval = defaultReconnectInterval,
      messageRetryInterval = defaultMessageRetryInterval,
      messageTimeout = 2 * nominalDay,
      helloTimeout = 2 * nominalDay,
      ntfCron = 20, -- minutes
      ntfWorkerDelay = 100000, -- microseconds
      ntfSMPWorkerDelay = 500000, -- microseconds
      ntfSubCheckInterval = nominalDay,
      ntfMaxMessages = 4,
      -- CA certificate private key is not needed for initialization
      -- ! we do not generate these
      caCertificateFile = "/etc/opt/simplex-agent/ca.crt",
      privateKeyFile = "/etc/opt/simplex-agent/agent.key",
      certificateFile = "/etc/opt/simplex-agent/agent.crt",
      smpAgentVRange = supportedSMPAgentVRange,
      smpClientVRange = supportedSMPClientVRange
    }

data Env = Env
  { config :: AgentConfig,
    store :: SQLiteStore,
    idsDrg :: TVar ChaChaDRG,
    clientCounter :: TVar Int,
    randomServer :: TVar StdGen,
    ntfSupervisor :: NtfSupervisor
  }

newSMPAgentEnv :: (MonadUnliftIO m, MonadRandom m) => AgentConfig -> m Env
newSMPAgentEnv config@AgentConfig {dbFile, yesToMigrations} = do
  idsDrg <- newTVarIO =<< drgNew
  store <- liftIO $ createSQLiteStore dbFile Migrations.app yesToMigrations
  clientCounter <- newTVarIO 0
  randomServer <- newTVarIO =<< liftIO newStdGen
  ntfSupervisor <- atomically . newNtfSubSupervisor $ tbqSize config
  return Env {config, store, idsDrg, clientCounter, randomServer, ntfSupervisor}

data NtfSupervisor = NtfSupervisor
  { ntfTkn :: TVar (Maybe NtfToken),
    ntfSubQ :: TBQueue (ConnId, NtfSupervisorCommand),
    ntfWorkers :: TMap NtfServer (TMVar (), Async ()),
    ntfSMPWorkers :: TMap SMPServer (TMVar (), Async ())
  }

data NtfSupervisorCommand = NSCCreate | NSCDelete | NSCSmpDelete | NSCNtfWorker NtfServer | NSCNtfSMPWorker SMPServer
  deriving (Show)

newNtfSubSupervisor :: Natural -> STM NtfSupervisor
newNtfSubSupervisor qSize = do
  ntfTkn <- newTVar Nothing
  ntfSubQ <- newTBQueue qSize
  ntfWorkers <- TM.empty
  ntfSMPWorkers <- TM.empty
  pure NtfSupervisor {ntfTkn, ntfSubQ, ntfWorkers, ntfSMPWorkers}
