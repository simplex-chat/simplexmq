{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Server.Env.STM where

import Control.Concurrent (ThreadId)
import Control.Monad.IO.Unlift
import Crypto.Random
import Data.ByteString.Char8 (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.X509.Validation (Fingerprint (..))
import Network.Socket (ServiceName)
import qualified Network.TLS as T
import Numeric.Natural
import Simplex.Messaging.Crypto (KeyHash (..))
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.MsgStore.STM
import Simplex.Messaging.Server.QueueStore (QueueRec (..))
import Simplex.Messaging.Server.QueueStore.STM
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.Transport (ATransport, loadFingerprint, loadTLSServerParams)
import System.IO (IOMode (..))
import UnliftIO.STM

data ServerConfig = ServerConfig
  { transports :: [(ServiceName, ATransport)],
    tbqSize :: Natural,
    serverTbqSize :: Natural,
    msgQueueQuota :: Natural,
    queueIdBytes :: Int,
    msgIdBytes :: Int,
    storeLog :: Maybe (StoreLog 'ReadMode),
    -- CA certificate private key is not needed for initialization
    caCertificateFile :: FilePath,
    privateKeyFile :: FilePath,
    certificateFile :: FilePath
  }

data Env = Env
  { config :: ServerConfig,
    server :: Server,
    serverIdentity :: KeyHash,
    queueStore :: QueueStore,
    msgStore :: STMMsgStore,
    idsDrg :: TVar ChaChaDRG,
    storeLog :: Maybe (StoreLog 'WriteMode),
    tlsServerParams :: T.ServerParams
  }

data Server = Server
  { subscribedQ :: TBQueue (RecipientId, Client),
    subscribers :: TVar (Map RecipientId Client),
    ntfSubscribedQ :: TBQueue (NotifierId, Client),
    notifiers :: TVar (Map NotifierId Client)
  }

data Client = Client
  { subscriptions :: TVar (Map RecipientId Sub),
    ntfSubscriptions :: TVar (Map NotifierId ()),
    rcvQ :: TBQueue (Transmission Cmd),
    sndQ :: TBQueue (Transmission BrokerMsg),
    sessionId :: ByteString,
    connected :: TVar Bool
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
  ntfSubscribedQ <- newTBQueue qSize
  notifiers <- newTVar M.empty
  return Server {subscribedQ, subscribers, ntfSubscribedQ, notifiers}

newClient :: Natural -> ByteString -> STM Client
newClient qSize sessionId = do
  subscriptions <- newTVar M.empty
  ntfSubscriptions <- newTVar M.empty
  rcvQ <- newTBQueue qSize
  sndQ <- newTBQueue qSize
  connected <- newTVar True
  return Client {subscriptions, ntfSubscriptions, rcvQ, sndQ, sessionId, connected}

newSubscription :: STM Sub
newSubscription = do
  delivered <- newEmptyTMVar
  return Sub {subThread = NoSub, delivered}

newEnv :: forall m. (MonadUnliftIO m, MonadRandom m) => ServerConfig -> m Env
newEnv config@ServerConfig {caCertificateFile, certificateFile, privateKeyFile} = do
  server <- atomically $ newServer (serverTbqSize config)
  queueStore <- atomically newQueueStore
  msgStore <- atomically newMsgStore
  idsDrg <- drgNew >>= newTVarIO
  s' <- restoreQueues queueStore `mapM` storeLog (config :: ServerConfig)
  tlsServerParams <- liftIO $ loadTLSServerParams caCertificateFile certificateFile privateKeyFile
  liftIO $ putStrLn "----------"
  liftIO $ print tlsServerParams
  liftIO $ putStrLn "----------"
  Fingerprint fp <- liftIO $ loadFingerprint caCertificateFile
  let serverIdentity = KeyHash fp
  return Env {config, server, serverIdentity, queueStore, msgStore, idsDrg, storeLog = s', tlsServerParams}
  where
    restoreQueues :: QueueStore -> StoreLog 'ReadMode -> m (StoreLog 'WriteMode)
    restoreQueues queueStore s = do
      (queues, s') <- liftIO $ readWriteStoreLog s
      atomically $
        modifyTVar queueStore $ \d ->
          d
            { queues,
              senders = M.foldr' addSender M.empty queues,
              notifiers = M.foldr' addNotifier M.empty queues
            }
      pure s'
    addSender :: QueueRec -> Map SenderId RecipientId -> Map SenderId RecipientId
    addSender q = M.insert (senderId q) (recipientId q)
    addNotifier :: QueueRec -> Map NotifierId RecipientId -> Map NotifierId RecipientId
    addNotifier q = case notifier q of
      Nothing -> id
      Just (nId, _) -> M.insert nId (recipientId q)
