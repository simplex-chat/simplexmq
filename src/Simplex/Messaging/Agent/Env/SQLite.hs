{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Env.SQLite where

import Control.Monad.IO.Unlift
import Crypto.Random
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import qualified Database.SQLite.Simple as DB
import Network.Socket (HostName, ServiceName)
import Numeric.Natural
import Simplex.Messaging.Agent.ServerClient
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite.Schema
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Server.Transmission (PublicKey)
import qualified Simplex.Messaging.Server.Transmission as SMP
import UnliftIO.STM

data AgentConfig = AgentConfig
  { tcpPort :: ServiceName,
    tbqSize :: Natural,
    connIdBytes :: Int,
    dbFile :: String,
    smpConfig :: ServerClientConfig
  }

data Env = Env
  { config :: AgentConfig,
    idsDrg :: TVar ChaChaDRG,
    db :: DB.Connection
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

data RequestState = NEWRequestState
  { recipientKey :: PublicKey,
    recipientPrivateKey :: PrivateKey
  }

newAgentClient :: Natural -> STM AgentClient
newAgentClient qSize = do
  rcvQ <- newTBQueue qSize
  sndQ <- newTBQueue qSize
  respQ <- newTBQueue qSize
  servers <- newTVar M.empty
  commands <- newTVar M.empty
  return AgentClient {rcvQ, sndQ, respQ, servers, commands}

openDB :: MonadUnliftIO m => AgentConfig -> m DB.Connection
openDB AgentConfig {dbFile} = liftIO $ do
  db <- DB.open dbFile
  createSchema db
  return db

newEnv :: (MonadUnliftIO m, MonadRandom m) => AgentConfig -> m Env
newEnv config = do
  idsDrg <- drgNew >>= newTVarIO
  db <- openDB config
  return Env {config, idsDrg, db}
