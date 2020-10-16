{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}

module Env.STM where

import ConnStore.STM
import Control.Concurrent
import Control.Concurrent.STM
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import MsgStore.STM
import Network.Socket (ServiceName)
import Numeric.Natural
import Transmission

data Env = Env
  { tcpPort :: ServiceName,
    queueSize :: Natural,
    server :: Server,
    connStore :: STMConnStore,
    msgStore :: STMMsgStore
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

newEnv :: String -> Natural -> STM Env
newEnv tcpPort queueSize = do
  server <- newServer queueSize
  connStore <- newConnStore
  msgStore <- newMsgStore
  return Env {tcpPort, queueSize, server, connStore, msgStore}
