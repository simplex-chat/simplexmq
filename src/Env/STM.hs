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
    connStore :: ConnStore,
    msgStore :: STMMsgStore,
    idsDrg :: TVar ChaChaDRG
  }

data Server = Server
  { subscribedQ :: TBQueue (RecipientId, Client),
    subscribers :: TVar (Map RecipientId Client)
  }

data Client = Client
  { subscriptions :: TVar (Map RecipientId Sub),
    rcvQ :: TBQueue Signed,
    sndQ :: TBQueue Signed
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

newEnv :: (MonadUnliftIO m, MonadRandom m) => Config -> m Env
newEnv config = do
  server <- atomically $ newServer (queueSize config)
  connStore <- atomically newConnStore
  msgStore <- atomically newMsgStore
  idsDrg <- drgNew >>= newTVarIO
  return Env {config, server, connStore, msgStore, idsDrg}
