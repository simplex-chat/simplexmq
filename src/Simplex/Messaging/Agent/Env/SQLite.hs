{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Env.SQLite where

import Control.Monad.IO.Unlift
import Crypto.Random
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Network.Socket
import Numeric.Natural
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Server.Transmission as SMP
import UnliftIO.STM

data AgentConfig = AgentConfig
  { tcpPort :: ServiceName,
    tbqSize :: Natural,
    connIdBytes :: Int,
    dbFile :: String,
    -- TODO smpTcpPort is currently not used, 5223 is hard-coded in Client.hs
    smpTcpPort :: ServiceName
  }

data Env = Env
  { config :: AgentConfig,
    idsDrg :: TVar ChaChaDRG,
    db :: SQLiteStore
  }

data AgentClient = AgentClient
  { rcvQ :: TBQueue (ATransmission Client),
    sndQ :: TBQueue (ATransmission Agent),
    respQ :: TBQueue SMP.TransmissionOrError,
    smpClients :: TVar (Map SMPServer SMPClient)
  }

newAgentClient :: Natural -> STM AgentClient
newAgentClient qSize = do
  rcvQ <- newTBQueue qSize
  sndQ <- newTBQueue qSize
  respQ <- newTBQueue qSize
  smpClients <- newTVar M.empty
  return AgentClient {rcvQ, sndQ, respQ, smpClients}

newEnv :: (MonadUnliftIO m, MonadRandom m) => AgentConfig -> m Env
newEnv config = do
  idsDrg <- drgNew >>= newTVarIO
  db <- newSQLiteStore $ dbFile config
  return Env {config, idsDrg, db}
