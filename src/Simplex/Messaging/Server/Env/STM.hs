{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Server.Env.STM where

import Control.Concurrent (ThreadId)
import Control.Monad.IO.Unlift
import Crypto.Random
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Network.Socket (ServiceName)
import Numeric.Natural
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.MsgStore.STM
import Simplex.Messaging.Server.QueueStore.STM
import UnliftIO.STM

data ServerConfig = ServerConfig
  { tcpPort :: ServiceName,
    tbqSize :: Natural,
    queueIdBytes :: Int,
    msgIdBytes :: Int,
    serverKeyPair :: C.KeyPair 'C.FullRSAKey
    -- serverId :: ByteString
  }

data Env = Env
  { config :: ServerConfig,
    server :: Server,
    queueStore :: QueueStore,
    msgStore :: STMMsgStore,
    idsDrg :: TVar ChaChaDRG
  }

data Server = Server
  { subscribedQ :: TBQueue (RecipientId, Client),
    subscribers :: TVar (Map RecipientId Client)
  }

data Client = Client
  { subscriptions :: TVar (Map RecipientId Sub),
    rcvQ :: TBQueue Transmission,
    sndQ :: TBQueue Transmission
  }

data SubscriptionThread = NoSub | SubPending | SubThread ThreadId

data Sub = Sub
  { subThread :: SubscriptionThread,
    delivered :: TMVar ()
  }

newServer :: Natural -> STM Server
newServer qSize = do
  subscribedQ <- newTBQueue qSize
  subscribers <- newTVar M.empty
  return Server {subscribedQ, subscribers}

newClient :: Natural -> STM Client
newClient qSize = do
  subscriptions <- newTVar M.empty
  rcvQ <- newTBQueue qSize
  sndQ <- newTBQueue qSize
  return Client {subscriptions, rcvQ, sndQ}

newSubscription :: STM Sub
newSubscription = do
  delivered <- newEmptyTMVar
  return Sub {subThread = NoSub, delivered}

newEnv :: (MonadUnliftIO m, MonadRandom m) => ServerConfig -> m Env
newEnv config = do
  server <- atomically $ newServer (tbqSize config)
  queueStore <- atomically newQueueStore
  msgStore <- atomically newMsgStore
  idsDrg <- drgNew >>= newTVarIO
  return Env {config, server, queueStore, msgStore, idsDrg}
