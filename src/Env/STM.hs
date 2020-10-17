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

data Env = Env
  { tcpPort :: ServiceName,
    queueSize :: Natural,
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

newEnv :: (MonadUnliftIO m, MonadRandom m) => String -> Natural -> m Env
newEnv tcpPort queueSize = do
  server <- atomically $ newServer queueSize
  connStore <- atomically newConnStore
  msgStore <- atomically newMsgStore
  idsDrg <- drgNew >>= newTVarIO
  return Env {tcpPort, queueSize, server, connStore, msgStore, idsDrg}
