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
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (ATransport)
import Simplex.Messaging.Transport.Server (loadFingerprint, loadTLSServerParams)
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
    subscribers :: TMap RecipientId Client,
    ntfSubscribedQ :: TBQueue (NotifierId, Client),
    notifiers :: TMap NotifierId Client
  }

data Client = Client
  { subscriptions :: TMap RecipientId Sub,
    ntfSubscriptions :: TMap NotifierId (),
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
  subscribers <- TM.empty
  ntfSubscribedQ <- newTBQueue qSize
  notifiers <- TM.empty
  return Server {subscribedQ, subscribers, ntfSubscribedQ, notifiers}

newClient :: Natural -> ByteString -> STM Client
newClient qSize sessionId = do
  subscriptions <- TM.empty
  ntfSubscriptions <- TM.empty
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
  Fingerprint fp <- liftIO $ loadFingerprint caCertificateFile
  let serverIdentity = KeyHash fp
  return Env {config, server, serverIdentity, queueStore, msgStore, idsDrg, storeLog = s', tlsServerParams}
  where
    restoreQueues :: QueueStore -> StoreLog 'ReadMode -> m (StoreLog 'WriteMode)
    restoreQueues QueueStore {queues, senders, notifiers} s = do
      (qs, s') <- liftIO $ readWriteStoreLog s
      atomically $ do
        writeTVar queues =<< mapM newTVar qs
        writeTVar senders $ M.foldr' addSender M.empty qs
        writeTVar notifiers $ M.foldr' addNotifier M.empty qs
      pure s'
    addSender :: QueueRec -> Map SenderId RecipientId -> Map SenderId RecipientId
    addSender q = M.insert (senderId q) (recipientId q)
    addNotifier :: QueueRec -> Map NotifierId RecipientId -> Map NotifierId RecipientId
    addNotifier q = case notifier q of
      Nothing -> id
      Just (nId, _) -> M.insert nId (recipientId q)
