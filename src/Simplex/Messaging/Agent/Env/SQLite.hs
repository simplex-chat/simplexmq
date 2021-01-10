{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Env.SQLite where

import Control.Monad.IO.Unlift
import Crypto.Random
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Network.Socket (HostName, ServiceName)
import Numeric.Natural
import Simplex.Messaging.Agent.ServerClient
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Server.Transmission (PublicKey, SenderId)
import qualified Simplex.Messaging.Server.Transmission as SMP
import UnliftIO.STM

data AgentConfig = AgentConfig
  { tcpPort :: ServiceName,
    tbqSize :: Natural,
    connIdBytes :: Int,
    dbFile :: String,
    smpTcpPort :: ServiceName,
    smpConfig :: ServerClientConfig
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
    servers :: TVar (Map (HostName, ServiceName) ServerClient),
    commands :: TVar (Map SMP.CorrId Request)
  }

data Request = Request
  { fromClient :: ATransmission Client,
    toSMP :: SMP.Transmission,
    state :: RequestState
  }

data RequestState
  = NEWRequestState
      { connAlias :: ConnAlias,
        smpServer :: SMPServer,
        rcvPrivateKey :: PrivateKey
      }
  | ConfSENDRequestState
      { connAlias :: ConnAlias,
        smpServer :: SMPServer,
        senderId :: SenderId,
        sndPrivateKey :: PrivateKey,
        encKey :: PublicKey
      }

newAgentClient :: Natural -> STM AgentClient
newAgentClient qSize = do
  rcvQ <- newTBQueue qSize
  sndQ <- newTBQueue qSize
  respQ <- newTBQueue qSize
  servers <- newTVar M.empty
  commands <- newTVar M.empty
  return AgentClient {rcvQ, sndQ, respQ, servers, commands}

newEnv :: (MonadUnliftIO m, MonadRandom m) => AgentConfig -> m Env
newEnv config = do
  idsDrg <- drgNew >>= newTVarIO
  db <- newSQLiteStore $ dbFile config
  return Env {config, idsDrg, db}
