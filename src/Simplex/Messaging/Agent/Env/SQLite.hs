{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Env.SQLite where

import Control.Monad.IO.Unlift
import Crypto.Random
import Data.List.NonEmpty (NonEmpty)
import Network.Socket
import qualified Network.TLS as T
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
    rsaKeySize :: Int,
    cmdSignAlg :: C.SignAlg,
    connIdBytes :: Int,
    tbqSize :: Natural,
    dbFile :: FilePath,
    dbPoolSize :: Int,
    smpCfg :: SMPClientConfig,
    retryInterval :: RetryInterval,
    reconnectInterval :: RetryInterval,
    agentPrivateKeyFile :: FilePath,
    agentCertificateFile :: FilePath
  }

minute :: Int
minute = 60_000_000

defaultAgentConfig :: AgentConfig
defaultAgentConfig =
  AgentConfig
    { tcpPort = "5224",
      smpServers = undefined,
      rsaKeySize = 2048 `div` 8,
      cmdSignAlg = C.SignAlg C.SEd448,
      connIdBytes = 12,
      tbqSize = 16,
      dbFile = "smp-agent.db",
      dbPoolSize = 4,
      smpCfg = smpDefaultConfig,
      retryInterval =
        RetryInterval
          { initialInterval = 1_000_000,
            increaseAfter = minute,
            maxInterval = 10 * minute
          },
      reconnectInterval =
        RetryInterval
          { initialInterval = 1_000_000,
            increaseAfter = 10_000_000,
            maxInterval = 10_000_000
          },
      -- ! we do not generate these key and certificate
      agentPrivateKeyFile = "/etc/opt/simplex-agent/agent.key",
      agentCertificateFile = "/etc/opt/simplex-agent/agent.crt"
    }

data Env = Env
  { config :: AgentConfig,
    store :: SQLiteStore,
    idsDrg :: TVar ChaChaDRG,
    clientCounter :: TVar Int,
    reservedMsgSize :: Int,
    randomServer :: TVar StdGen,
    agentCredential :: T.Credential
  }

newSMPAgentEnv :: (MonadUnliftIO m, MonadRandom m) => AgentConfig -> m Env
newSMPAgentEnv cfg = do
  idsDrg <- newTVarIO =<< drgNew
  store <- liftIO $ createSQLiteStore (dbFile cfg) (dbPoolSize cfg) Migrations.app
  clientCounter <- newTVarIO 0
  randomServer <- newTVarIO =<< liftIO newStdGen
  agentCredential <- loadAgentCredential cfg
  return Env {config = cfg, store, idsDrg, clientCounter, reservedMsgSize, randomServer, agentCredential}
  where
    -- 1st rsaKeySize is used by the RSA signature in each command,
    -- 2nd - by encrypted message body header
    -- 3rd - by message signature
    -- smpCommandSize - is the estimated max size for SMP command, queueId, corrId
    reservedMsgSize = 3 * rsaKeySize cfg + smpCommandSize (smpCfg cfg)
    loadAgentCredential :: (MonadUnliftIO m') => AgentConfig -> m' T.Credential
    loadAgentCredential AgentConfig {agentPrivateKeyFile, agentCertificateFile} =
      liftIO (T.credentialLoadX509 agentPrivateKeyFile agentCertificateFile) >>= \case
        Right cert -> pure cert
        Left _ -> error "invalid credential"
