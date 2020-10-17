{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}

module Env.STM where

import ConnStore.STM
import Control.Concurrent (ThreadId)
import Control.Monad.IO.Unlift
import Crypto.Random
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import MsgStore.STM
import Network.Socket (ServiceName)
import Numeric.Natural
import Transmission
import UnliftIO.STM

data Config = Config
  { tcpPort :: ServiceName,
    queueSize :: Natural,
    connIdBytes :: Int,
    msgIdBytes :: Int
  }

data Env = Env
  { config :: Config,
    server :: Server,
    connStore :: STMConnStore,
    msgStore :: STMMsgStore,
    idsDrg :: TVar ChaChaDRG
  }

data Server = Server
  { subscribedQ :: TBQueue (RecipientId, Client),
    connections :: TVar (Map RecipientId Client)
  }

data Client = Client
  { connections :: TVar (Map RecipientId (Either () ThreadId)),
    rcvQ :: TBQueue Signed,
    sndQ :: TBQueue Signed
  }

newServer :: Natural -> STM Server
newServer qSize = do
  subscribedQ <- newTBQueue qSize
  connections <- newTVar M.empty
  return Server {subscribedQ, connections}

newClient :: Natural -> STM Client
newClient qSize = do
  connections <- newTVar M.empty
  rcvQ <- newTBQueue qSize
  sndQ <- newTBQueue qSize
  return Client {connections, rcvQ, sndQ}

newEnv :: (MonadUnliftIO m, MonadRandom m) => Config -> m Env
newEnv config = do
  server <- atomically $ newServer (queueSize config)
  connStore <- atomically newConnStore
  msgStore <- atomically newMsgStore
  idsDrg <- drgNew >>= newTVarIO
  return Env {config, server, connStore, msgStore, idsDrg}
