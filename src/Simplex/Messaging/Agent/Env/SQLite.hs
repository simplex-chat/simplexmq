{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Env.SQLite where

import Control.Monad.IO.Unlift
import Crypto.Random
import Data.List.NonEmpty (NonEmpty)
import Network.Socket
import Numeric.Natural
import Simplex.Messaging.Agent.Protocol (SMPServer)
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Client
import System.Random (StdGen, newStdGen)
import UnliftIO.STM

data AgentConfig = AgentConfig
  { tcpPort :: ServiceName,
    smpServers :: NonEmpty SMPServer,
    rsaKeySize :: Int,
    connIdBytes :: Int,
    tbqSize :: Natural,
    dbFile :: FilePath,
    smpCfg :: SMPClientConfig
  }

data Env = Env
  { config :: AgentConfig,
    idsDrg :: TVar ChaChaDRG,
    clientCounter :: TVar Int,
    reservedMsgSize :: Int,
    randomServer :: TVar StdGen
  }

newSMPAgentEnv :: (MonadUnliftIO m, MonadRandom m) => AgentConfig -> m Env
newSMPAgentEnv config = do
  idsDrg <- newTVarIO =<< drgNew
  _ <- createSQLiteStore $ dbFile config
  clientCounter <- newTVarIO 0
  randomServer <- newTVarIO =<< liftIO newStdGen
  return Env {config, idsDrg, clientCounter, reservedMsgSize, randomServer}
  where
    -- 1st rsaKeySize is used by the RSA signature in each command,
    -- 2nd - by encrypted message body header
    -- 3rd - by message signature
    -- smpCommandSize - is the estimated max size for SMP command, queueId, corrId
    reservedMsgSize = 3 * rsaKeySize config + smpCommandSize (smpCfg config)
