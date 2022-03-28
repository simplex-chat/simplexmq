{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Client.Agent where

import Control.Concurrent (forkIO)
import Control.Concurrent.Async (Async, uninterruptibleCancel)
import Control.Logger.Simple
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Trans.Except
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (isNothing)
import Data.Set (Set)
import Data.Text.Encoding
import Numeric.Natural
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (QueueId, SMPServer (..))
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (tryE, whenM)
import System.Timeout (timeout)
import UnliftIO (async, forConcurrently_)
import UnliftIO.Exception (Exception)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

type SMPClientVar = TMVar (Either SMPClientError SMPClient)

data SMPClientAgentEvent
  = CAConnected SMPServer
  | CADisconnected SMPServer (Set SMPSub)
  | CAReconnected SMPServer
  | CAResubscribed SMPServer SMPSub
  | CASubError SMPSub SMPClientError
  | CAError SMPClientError

data SMPSubParty = SPRecipient | SPNotifier
  deriving (Eq, Ord)

data SMPSubscription = SMPSubscription SMPSub C.APrivateSignKey
  deriving (Eq)

type SMPSub = (SMPServer, SMPSubParty, QueueId)

data SMPClientAgentConfig = SMPClientAgentConfig
  { smpCfg :: SMPClientConfig,
    reconnectInterval :: RetryInterval,
    msgQSize :: Natural,
    agentQSize :: Natural
  }

data SMPClientAgent = SMPClientAgent
  { config :: SMPClientAgentConfig,
    msgQ :: TBQueue SMPServerTransmission,
    agentQ :: TBQueue SMPClientAgentEvent,
    smpClients :: TMap SMPServer SMPClientVar,
    srvSubs :: TMap SMPServer (TMap SMPSub SMPSubscription),
    pendingSrvSubs :: TMap SMPServer (TMap SMPSub SMPSubscription),
    subscriptions :: TMap SMPSub SMPServer,
    reconnections :: TVar [Async ()],
    asyncClients :: TVar [Async ()]
  }

newtype InternalException e = InternalException {unInternalException :: e}
  deriving (Eq, Show)

instance Exception e => Exception (InternalException e)

instance (MonadUnliftIO m, Exception e) => MonadUnliftIO (ExceptT e m) where
  withRunInIO :: ((forall a. ExceptT e m a -> IO a) -> IO b) -> ExceptT e m b
  withRunInIO exceptToIO =
    withExceptT unInternalException . ExceptT . E.try $
      withRunInIO $ \run ->
        exceptToIO $ run . (either (E.throwIO . InternalException) return <=< runExceptT)

newSMPClientAgent :: SMPClientAgentConfig -> STM SMPClientAgent
newSMPClientAgent config@SMPClientAgentConfig {msgQSize, agentQSize} = do
  msgQ <- newTBQueue msgQSize
  agentQ <- newTBQueue agentQSize
  smpClients <- TM.empty
  srvSubs <- TM.empty
  pendingSrvSubs <- TM.empty
  subscriptions <- TM.empty
  reconnections <- newTVar []
  asyncClients <- newTVar []
  pure SMPClientAgent {config, msgQ, agentQ, smpClients, srvSubs, pendingSrvSubs, subscriptions, reconnections, asyncClients}

getSMPServerClient' :: SMPClientAgent -> SMPServer -> ExceptT SMPClientError IO SMPClient
getSMPServerClient' ca@SMPClientAgent {config, smpClients, msgQ} srv =
  atomically getClientVar >>= either newSMPClient waitForSMPClient
  where
    getClientVar :: STM (Either SMPClientVar SMPClientVar)
    getClientVar = maybe (Left <$> newClientVar) (pure . Right) =<< TM.lookup srv smpClients

    newClientVar :: STM SMPClientVar
    newClientVar = do
      smpVar <- newEmptyTMVar
      TM.insert srv smpVar smpClients
      pure smpVar

    waitForSMPClient :: SMPClientVar -> ExceptT SMPClientError IO SMPClient
    waitForSMPClient smpVar = do
      let SMPClientConfig {tcpTimeout} = smpCfg config
      smpClient_ <- liftIO $ tcpTimeout `timeout` atomically (readTMVar smpVar)
      liftEither $ case smpClient_ of
        Just (Right smpClient) -> Right smpClient
        Just (Left e) -> Left e
        Nothing -> Left SMPResponseTimeout

    newSMPClient :: SMPClientVar -> ExceptT SMPClientError IO SMPClient
    newSMPClient smpVar = tryConnectClient pure tryConnectAsync
      where
        tryConnectClient :: (SMPClient -> ExceptT SMPClientError IO a) -> ExceptT SMPClientError IO () -> ExceptT SMPClientError IO a
        tryConnectClient successAction retryAction =
          tryE connectClient >>= \r -> case r of
            Right smp -> do
              logInfo . decodeUtf8 $ "Agent connected to " <> showServer srv
              atomically $ putTMVar smpVar r
              successAction smp
            Left e -> do
              if e == SMPNetworkError || e == SMPResponseTimeout
                then retryAction
                else atomically $ do
                  putTMVar smpVar (Left e)
                  TM.delete srv smpClients
              throwE e
        tryConnectAsync :: ExceptT SMPClientError IO ()
        tryConnectAsync = do
          a <- async connectAsync
          atomically $ modifyTVar' (asyncClients ca) (a :)
        connectAsync :: ExceptT SMPClientError IO ()
        connectAsync =
          withRetryInterval (reconnectInterval config) $ \loop ->
            void $ tryConnectClient (const reconnectClient) loop

    connectClient :: ExceptT SMPClientError IO SMPClient
    connectClient = ExceptT $ getSMPClient srv (smpCfg config) msgQ clientDisconnected

    clientDisconnected :: IO ()
    clientDisconnected = do
      removeClientAndSubs >>= (`forM_` serverDown)
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv

    removeClientAndSubs :: IO (Maybe (Map SMPSub SMPSubscription))
    removeClientAndSubs = atomically $ do
      TM.delete srv smpClients
      sVar_ <- TM.lookupDelete srv $ srvSubs ca
      forM sVar_ $ \sVar -> do
        ss <- readTVar sVar
        modifyTVar' (subscriptions ca) (`M.withoutKeys` M.keysSet ss)
        let ps = pendingSrvSubs ca
        TM.lookup srv ps >>= \case
          Just v -> TM.union ss v
          _ -> TM.insert srv sVar ps
        pure ss

    serverDown :: Map SMPSub SMPSubscription -> IO ()
    serverDown ss = unless (M.null ss) . void . runExceptT $ do
      notify . CADisconnected srv $ M.keysSet ss
      reconnectServer

    reconnectServer :: ExceptT SMPClientError IO ()
    reconnectServer = do
      a <- async tryReconnectClient
      atomically $ modifyTVar' (reconnections ca) (a :)

    tryReconnectClient :: ExceptT SMPClientError IO ()
    tryReconnectClient = do
      withRetryInterval (reconnectInterval config) $ \loop ->
        reconnectClient `catchE` const loop

    reconnectClient :: ExceptT SMPClientError IO ()
    reconnectClient = do
      withSMP ca srv $ \smp -> do
        cs <- atomically $ mapM readTVar =<< TM.lookup srv (pendingSrvSubs ca)
        forConcurrently_ (maybe [] M.assocs cs) $ \(s, sub) ->
          whenM (atomically $ isNothing <$> TM.lookup s (subscriptions ca)) $
            subscribe_ smp sub
              `catchE` \case
                e@SMPResponseTimeout -> throwE e
                e@SMPNetworkError -> throwE e
                e -> do
                  notify $ CASubError s e
                  atomically $ removePendingSubscription ca s
      where
        subscribe_ :: SMPClient -> SMPSubscription -> ExceptT SMPClientError IO ()
        subscribe_ smp sub@(SMPSubscription s _) = do
          smpSubscribe smp sub
          atomically $ addSubscription ca sub
          notify $ CAResubscribed srv s

    notify :: SMPClientAgentEvent -> ExceptT SMPClientError IO ()
    notify evt = atomically $ writeTBQueue (agentQ ca) evt

closeSMPClientAgent :: MonadUnliftIO m => SMPClientAgent -> m ()
closeSMPClientAgent c = liftIO $ do
  closeSMPServerClients c
  cancelActions $ reconnections c
  cancelActions $ asyncClients c

closeSMPServerClients :: SMPClientAgent -> IO ()
closeSMPServerClients c = readTVarIO (smpClients c) >>= mapM_ (forkIO . closeClient)
  where
    closeClient smpVar =
      atomically (readTMVar smpVar) >>= \case
        Right smp -> closeSMPClient smp `E.catch` \(_ :: E.SomeException) -> pure ()
        _ -> pure ()

cancelActions :: Foldable f => TVar (f (Async ())) -> IO ()
cancelActions as = readTVarIO as >>= mapM_ uninterruptibleCancel

withSMP :: SMPClientAgent -> SMPServer -> (SMPClient -> ExceptT SMPClientError IO a) -> ExceptT SMPClientError IO a
withSMP ca srv action = (getSMPServerClient' ca srv >>= action) `catchE` logSMPError
  where
    logSMPError :: SMPClientError -> ExceptT SMPClientError IO a
    logSMPError e = do
      liftIO $ putStrLn $ "SMP error (" <> show srv <> "): " <> show e
      throwE e

showServer :: SMPServer -> ByteString
showServer SMPServer {host, port} =
  B.pack $ host <> if null port then "" else ':' : port

smpSubscribe :: SMPClient -> SMPSubscription -> ExceptT SMPClientError IO ()
smpSubscribe smp (SMPSubscription (_, party, queueId) privKey) = subscribe_ smp privKey queueId
  where
    subscribe_ = case party of
      SPRecipient -> subscribeSMPQueue
      SPNotifier -> subscribeSMPQueueNotifications

addSubscription :: SMPClientAgent -> SMPSubscription -> STM ()
addSubscription ca sub@(SMPSubscription s@(srv, _, _) _) = do
  TM.insert s srv $ subscriptions ca
  addSubs_ sub $ srvSubs ca
  removePendingSubscription ca s

addPendingSubscription :: SMPClientAgent -> SMPSubscription -> STM ()
addPendingSubscription ca sub = addSubs_ sub $ pendingSrvSubs ca

addSubs_ :: SMPSubscription -> TMap SMPServer (TMap SMPSub SMPSubscription) -> STM ()
addSubs_ sub@(SMPSubscription s@(srv, _, _) _) subs =
  TM.lookup srv subs >>= \case
    Just m -> TM.insert s sub m
    _ -> TM.singleton s sub >>= \v -> TM.insert srv v subs

removeSubscription :: SMPClientAgent -> SMPSub -> STM ()
removeSubscription ca@SMPClientAgent {subscriptions} s = do
  TM.delete s subscriptions
  removeSubs_ (srvSubs ca) s

removePendingSubscription :: SMPClientAgent -> SMPSub -> STM ()
removePendingSubscription = removeSubs_ . pendingSrvSubs

removeSubs_ :: TMap SMPServer (TMap SMPSub SMPSubscription) -> SMPSub -> STM ()
removeSubs_ subs s@(srv, _, _) = TM.lookup srv subs >>= mapM_ (TM.delete s)
