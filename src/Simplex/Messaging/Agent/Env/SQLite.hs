{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Env.SQLite
  ( AgentConfig (..),
    defaultAgentConfig,
    Env (..),
    newSMPAgentEnv,
  )
where

import Control.Monad.IO.Unlift
import Crypto.Random
import Data.List.NonEmpty (NonEmpty)
import Data.Time.Clock (NominalDiffTime)
import Network.Socket
import Numeric.Natural
import Simplex.Messaging.Agent.Protocol (SMPServer)
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store.SQLite
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import System.Random (StdGen, newStdGen)
import UnliftIO.STM

data AgentConfig = AgentConfig
  { tcpPort :: ServiceName,
    smpServers :: NonEmpty SMPServer,
    cmdSignAlg :: C.SignAlg,
    connIdBytes :: Int,
    tbqSize :: Natural,
    dbFile :: FilePath,
    dbPoolSize :: Int,
    smpCfg :: SMPClientConfig,
    reconnectInterval :: RetryInterval,
    helloInterval :: RetryInterval,
    helloTimeout :: NominalDiffTime,
    caCertificateFile :: FilePath,
    privateKeyFile :: FilePath,
    certificateFile :: FilePath
  }

defaultAgentConfig :: AgentConfig
defaultAgentConfig =
  AgentConfig
    { tcpPort = "5224",
      smpServers = undefined, -- TODO move it elsewhere?
      cmdSignAlg = C.SignAlg C.SEd448,
      connIdBytes = 12,
      tbqSize = 16,
      dbFile = "smp-agent.db",
      dbPoolSize = 4,
      smpCfg = smpDefaultConfig,
      reconnectInterval =
        RetryInterval
          { initialInterval = second,
            increaseAfter = 10 * second,
            maxInterval = 10 * second
          },
      helloInterval =
        RetryInterval
          { initialInterval = second,
            increaseAfter = 10 * second,
            maxInterval = 10 * 60 * second
          },
      helloTimeout = 7 * 24 * 60 * 60,
      -- CA certificate private key is not needed for initialization
      -- ! we do not generate these
      caCertificateFile = "/etc/opt/simplex-agent/ca.crt",
      privateKeyFile = "/etc/opt/simplex-agent/agent.key",
      certificateFile = "/etc/opt/simplex-agent/agent.crt"
    }
  where
    second = 1_000_000

data Env = Env
  { config :: AgentConfig,
    store :: SQLiteStore,
    idsDrg :: TVar ChaChaDRG,
    clientCounter :: TVar Int,
    randomServer :: TVar StdGen
  }

newSMPAgentEnv :: (MonadUnliftIO m, MonadRandom m) => AgentConfig -> m Env
newSMPAgentEnv cfg = do
  idsDrg <- newTVarIO =<< drgNew
  store <- liftIO $ createSQLiteStore (dbFile cfg) (dbPoolSize cfg) Migrations.app
  clientCounter <- newTVarIO 0
  randomServer <- newTVarIO =<< liftIO newStdGen
  return Env {config = cfg, store, idsDrg, clientCounter, randomServer}
