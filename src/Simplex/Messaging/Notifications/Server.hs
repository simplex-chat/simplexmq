{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Notifications.Server where

import Control.Monad.Except
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader
import Crypto.Random (MonadRandom)
import Data.ByteString.Char8 (ByteString)
import Data.Functor (($>))
import Network.Socket (ServiceName)
import Simplex.Messaging.Client.Agent
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Env
import Simplex.Messaging.Notifications.Server.Subscriptions
import Simplex.Messaging.Notifications.Transport
import Simplex.Messaging.Protocol (ErrorType (..), Transmission, encodeTransmission, tGet, tPut)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server
import Simplex.Messaging.Transport (ATransport (..), THandle (..), TProxy, Transport)
import Simplex.Messaging.Transport.Server (runTransportServer)
import Simplex.Messaging.Util
import UnliftIO.Exception
import UnliftIO.STM

runNtfServer :: (MonadRandom m, MonadUnliftIO m) => NtfServerConfig -> m ()
runNtfServer cfg = do
  started <- newEmptyTMVarIO
  runNtfServerBlocking started cfg

runNtfServerBlocking :: (MonadRandom m, MonadUnliftIO m) => TMVar Bool -> NtfServerConfig -> m ()
runNtfServerBlocking started cfg@NtfServerConfig {transports} = do
  env <- newNtfServerEnv cfg
  runReaderT ntfServer env
  where
    ntfServer :: (MonadUnliftIO m', MonadReader NtfEnv m') => m' ()
    ntfServer = do
      s <- asks subscriber
      ps <- asks pushServer
      raceAny_ (ntfSubscriber s : ntfPush ps : map runServer transports)

    runServer :: (MonadUnliftIO m', MonadReader NtfEnv m') => (ServiceName, ATransport) -> m' ()
    runServer (tcpPort, ATransport t) = do
      serverParams <- asks tlsServerParams
      runTransportServer started tcpPort serverParams (runClient t)

    runClient :: (Transport c, MonadUnliftIO m, MonadReader NtfEnv m) => TProxy c -> c -> m ()
    runClient _ h = do
      kh <- asks serverIdentity
      liftIO (runExceptT $ ntfServerHandshake h kh) >>= \case
        Right th -> runNtfClientTransport th
        Left _ -> pure ()

ntfSubscriber :: forall m. (MonadUnliftIO m, MonadReader NtfEnv m) => NtfSubscriber -> m ()
ntfSubscriber NtfSubscriber {subQ, smpAgent = ca@SMPClientAgent {msgQ, agentQ}} = do
  raceAny_ [subscribe, receiveSMP, receiveAgent]
  where
    subscribe :: m ()
    subscribe = forever $ do
      NtfSubsciption {smpQueue} <- atomically $ readTBQueue subQ
      let SMPQueueNtf {smpServer, notifierId, notifierKey} = smpQueue
      liftIO (runExceptT $ subscribeQueue ca smpServer ((SPNotifier, notifierId), notifierKey)) >>= \case
        Right _ -> pure () -- update subscription status
        Left e -> pure ()

    receiveSMP :: m ()
    receiveSMP = forever $ do
      (srv, ntfId, msg) <- atomically $ readTBQueue msgQ
      case msg of
        SMP.NMSG -> do
          -- check when the last NMSG was received from this queue
          -- update timestamp
          -- check what was the last hidden notification was sent (and whether to this queue)
          -- decide whether it should be sent as hidden or visible
          -- construct and possibly encrypt notification
          -- send it
          pure ()
        _ -> pure ()
      pure ()

    receiveAgent =
      forever $
        atomically (readTBQueue agentQ) >>= \case
          CAConnected _ -> pure ()
          CADisconnected srv subs -> do
            -- update subscription statuses
            pure ()
          CAReconnected _ -> pure ()
          CAResubscribed srv sub -> do
            -- update subscription status
            pure ()
          CASubError srv sub err -> do
            -- update subscription status
            pure ()

ntfPush :: (MonadUnliftIO m, MonadReader NtfEnv m) => NtfPushServer -> m ()
ntfPush NtfPushServer {pushQ} = forever $ do
  (NtfSubsciption {}, Notification {}) <- atomically $ readTBQueue pushQ
  pure ()

runNtfClientTransport :: (Transport c, MonadUnliftIO m, MonadReader NtfEnv m) => THandle c -> m ()
runNtfClientTransport th@THandle {sessionId} = do
  qSize <- asks $ clientQSize . config
  c <- atomically $ newNtfServerClient qSize sessionId
  s <- asks subscriber
  raceAny_ [send th c, client c s, receive th c]
    `finally` clientDisconnected c

clientDisconnected :: MonadUnliftIO m => NtfServerClient -> m ()
clientDisconnected NtfServerClient {connected} = atomically $ writeTVar connected False

receive :: (Transport c, MonadUnliftIO m, MonadReader NtfEnv m) => THandle c -> NtfServerClient -> m ()
receive th NtfServerClient {rcvQ, sndQ} = forever $ do
  (sig, signed, (corrId, subId, cmdOrError)) <- tGet th
  case cmdOrError of
    Left e -> write sndQ (corrId, subId, NRErr e)
    Right cmd ->
      verifyNtfTransmission sig signed subId cmd >>= \case
        VRCreate newSub -> write rcvQ $ NRCreate corrId newSub
        VRCommand sub -> write rcvQ $ NRCommand sub (corrId, subId, cmd)
        VRFail -> write sndQ (corrId, subId, NRErr AUTH)
  where
    write q t = atomically $ writeTBQueue q t

send :: (Transport c, MonadUnliftIO m) => THandle c -> NtfServerClient -> m ()
send h NtfServerClient {sndQ, sessionId} = forever $ do
  t <- atomically $ readTBQueue sndQ
  liftIO $ tPut h (Nothing, encodeTransmission sessionId t)

data VerificationResult = VRCreate NewNtfSubscription | VRCommand NtfSubsciption | VRFail

verifyNtfTransmission ::
  forall m. (MonadUnliftIO m, MonadReader NtfEnv m) => Maybe C.ASignature -> ByteString -> NtfSubsciptionId -> NtfCommand -> m VerificationResult
verifyNtfTransmission sig_ signed subId cmd = do
  st <- asks store
  case cmd of
    NCCreate newSub@NewNtfSubscription {smpQueue, verifyKey} -> verifyCreateCmd verifyKey newSub <$> atomically (getNtfSubViaSMPQueue st smpQueue)
    _ -> verifySubCmd <$> atomically (getNtfSub st subId)
  where
    verifyCreateCmd k newSub sub_
      | verifyCmdSignature sig_ signed k = case sub_ of
        Just sub -> if k == subVerifyKey sub then VRCommand sub else VRFail
        _ -> VRCreate newSub
      | otherwise = VRFail
    verifySubCmd = \case
      Just sub -> if verifyCmdSignature sig_ signed $ subVerifyKey sub then VRCommand sub else VRFail
      _ -> maybe False (dummyVerifyCmd signed) sig_ `seq` VRFail

client :: forall m. (MonadUnliftIO m, MonadReader NtfEnv m) => NtfServerClient -> NtfSubscriber -> m ()
client NtfServerClient {rcvQ, sndQ} NtfSubscriber {subQ} =
  forever $
    atomically (readTBQueue rcvQ)
      >>= processCommand
      >>= atomically . writeTBQueue sndQ
  where
    processCommand :: NtfRequest -> m (Transmission NtfResponse)
    processCommand = \case
      NRCreate corrId NewNtfSubscription {smpQueue, token, verifyKey, dhPubKey} -> do
        st <- asks store
        (pubDhKey, privDhKey) <- liftIO C.generateKeyPair'
        let dhSecret = C.dh' dhPubKey privDhKey
        sub <- atomically $ mkNtfSubsciption smpQueue token verifyKey dhSecret
        addSubRetry 3 st sub >>= \case
          Nothing -> pure (corrId, "", NRErr INTERNAL)
          Just sId -> do
            atomically $ writeTBQueue subQ sub
            pure (corrId, sId, NRSubId pubDhKey)
        where
          addSubRetry :: Int -> NtfSubscriptionsStore -> NtfSubsciption -> m (Maybe NtfSubsciptionId)
          addSubRetry 0 _ _ = pure Nothing
          addSubRetry n st sub = do
            sId <- getId
            -- create QueueRec record with these ids and keys
            atomically (addNtfSub st sId sub) >>= \case
              Nothing -> addSubRetry (n - 1) st sub
              _ -> pure $ Just sId
          getId :: m NtfSubsciptionId
          getId = do
            n <- asks $ subIdBytes . config
            gVar <- asks idsDrg
            atomically (randomBytes n gVar)
      NRCommand sub@NtfSubsciption {token, status} (corrId, subId, cmd) ->
        (corrId,subId,) <$> case cmd of
          NCCreate newSub -> do
            st <- asks store
            (pubDhKey, privDhKey) <- liftIO C.generateKeyPair'
            let dhSecret = C.dh' (dhPubKey newSub) privDhKey
            atomically (updateNtfSub st sub newSub dhSecret) >>= \case
              Nothing -> pure $ NRErr INTERNAL
              _ -> atomically $ do
                whenM ((== NSEnd) <$> readTVar status) $ writeTBQueue subQ sub
                pure $ NRSubId pubDhKey
          NCCheck -> NRStat <$> readTVarIO status
          NCToken t -> atomically (writeTVar token t) $> NROk
          NCDelete -> do
            st <- asks store
            atomically (deleteNtfSub st subId) $> NROk
