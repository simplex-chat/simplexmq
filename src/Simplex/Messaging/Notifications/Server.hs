{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Notifications.Server where

import Control.Concurrent (forkFinally)
import Control.Monad.Except
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader
import Crypto.Random (MonadRandom)
import qualified Data.Aeson as J
import Data.ByteString.Char8 (ByteString)
import Network.Socket (ServiceName)
import Simplex.Messaging.Client.Agent
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Env
import Simplex.Messaging.Notifications.Server.Env (NtfPushServer (pushClients))
import Simplex.Messaging.Notifications.Server.Subscriptions
import Simplex.Messaging.Notifications.Transport
import Simplex.Messaging.Protocol (ErrorType (..), SignedTransmission, Transmission, encodeTransmission, tGet, tPut)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server
import qualified Simplex.Messaging.TMap as TM
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
      atomically (readTBQueue subQ) >>= \case
        NtfSub NtfSubData {smpQueue} -> do
          let SMPQueueNtf {smpServer, notifierId, notifierKey} = smpQueue
          liftIO (runExceptT $ subscribeQueue ca smpServer ((SPNotifier, notifierId), notifierKey)) >>= \case
            Right _ -> pure () -- update subscription status
            Left e -> pure ()

    receiveSMP :: m ()
    receiveSMP = forever $ do
      (srv, sessId, ntfId, msg) <- atomically $ readTBQueue msgQ
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
ntfPush NtfPushServer {pushQ, pushClients} = forever $ do
  (NtfTknData {token, tknStatus}, ntf) <- atomically (readTBQueue pushQ)
  status <- readTVarIO tknStatus
  case (status, ntf) of
    (_, PNVerification _code) -> do
      -- TODO check token status
      deliverNotification token ntf
      -- liftIO $ print $ J.encode ntf
      -- TODO status update should happen after the token status successfully sent
      atomically $ writeTVar tknStatus NTConfirmed
    (NTActive, PNPeriodic) -> do
      deliverNotification token ntf
    -- liftIO $ print $ J.encode ntf
    _ -> do
      liftIO $ putStrLn "bad notification token status"
  where
    deliverNotification (DeviceToken provider token) notification = pure ()

--   do
--     withPushProviderClient provider $ \client -> client token notification
-- withPushProviderClient :: PushProvider -> ((NtfTknData -> PushNotification -> IO ()) -> IO ()) -> m ()
-- withPushProviderClient provider = do
--   maybe connectPushClient pure =<< atomically (mapM readTVar =<< TM.lookup provider pushClients)
--   where
--     connectPushClient ::
--     connectPushClient = do
--       forkIO
--         ( do
--             runHTTPS2Client host port client
--         )
--         `finally` atomically (TM.delete provider pushClients)

runNtfClientTransport :: (Transport c, MonadUnliftIO m, MonadReader NtfEnv m) => THandle c -> m ()
runNtfClientTransport th@THandle {sessionId} = do
  qSize <- asks $ clientQSize . config
  c <- atomically $ newNtfServerClient qSize sessionId
  s <- asks subscriber
  ps <- asks pushServer
  raceAny_ [send th c, client c s ps, receive th c]
    `finally` clientDisconnected c

clientDisconnected :: MonadUnliftIO m => NtfServerClient -> m ()
clientDisconnected NtfServerClient {connected} = atomically $ writeTVar connected False

receive :: (Transport c, MonadUnliftIO m, MonadReader NtfEnv m) => THandle c -> NtfServerClient -> m ()
receive th NtfServerClient {rcvQ, sndQ} = forever $ do
  t@(_, _, (corrId, subId, cmdOrError)) <- tGet th
  case cmdOrError of
    Left e -> write sndQ (corrId, subId, NRErr e)
    Right cmd ->
      verifyNtfTransmission t cmd >>= \case
        VRVerified req -> write rcvQ req
        VRFailed -> write sndQ (corrId, subId, NRErr AUTH)
  where
    write q t = atomically $ writeTBQueue q t

send :: (Transport c, MonadUnliftIO m) => THandle c -> NtfServerClient -> m ()
send h NtfServerClient {sndQ, sessionId} = forever $ do
  t <- atomically $ readTBQueue sndQ
  liftIO $ tPut h (Nothing, encodeTransmission sessionId t)

data VerificationResult = VRVerified NtfRequest | VRFailed

verifyNtfTransmission ::
  forall m. (MonadUnliftIO m, MonadReader NtfEnv m) => SignedTransmission NtfCmd -> NtfCmd -> m VerificationResult
verifyNtfTransmission (sig_, signed, (corrId, entId, _)) cmd = do
  case cmd of
    NtfCmd SToken (TNEW n@(NewNtfTkn _ k _)) ->
      -- TODO check that token is not already in store, if it is - verify that the saved key is the same
      pure $
        if verifyCmdSignature sig_ signed k
          then VRVerified (NtfReqNew corrId (ANE SToken n))
          else VRFailed
    NtfCmd SToken c -> do
      st <- asks store
      atomically (getNtfToken st entId) >>= \case
        Just r@(NtfTkn NtfTknData {tknVerifyKey}) ->
          pure $
            if verifyCmdSignature sig_ signed tknVerifyKey
              then VRVerified (NtfReqCmd SToken r (corrId, entId, c))
              else VRFailed
        _ -> pure VRFailed -- TODO dummy verification
    _ -> pure VRFailed

-- do
--   st <- asks store
--   case cmd of
--     NCSubCreate tokenId smpQueue -> verifyCreateCmd verifyKey newSub <$> atomically (getNtfSubViaSMPQueue st smpQueue)
--     _ -> verifySubCmd <$> atomically (getNtfSub st subId)
--   where
--     verifyCreateCmd k newSub sub_
--       | verifyCmdSignature sig_ signed k = case sub_ of
--         Just sub -> if k == subVerifyKey sub then VRCommand sub else VRFail
--         _ -> VRCreate newSub
--       | otherwise = VRFail
--     verifySubCmd = \case
--       Just sub -> if verifyCmdSignature sig_ signed $ subVerifyKey sub then VRCommand sub else VRFail
--       _ -> maybe False (dummyVerifyCmd signed) sig_ `seq` VRFail

client :: forall m. (MonadUnliftIO m, MonadReader NtfEnv m) => NtfServerClient -> NtfSubscriber -> NtfPushServer -> m ()
client NtfServerClient {rcvQ, sndQ} NtfSubscriber {subQ} NtfPushServer {pushQ} =
  forever $
    atomically (readTBQueue rcvQ)
      >>= processCommand
      >>= atomically . writeTBQueue sndQ
  where
    processCommand :: NtfRequest -> m (Transmission NtfResponse)
    processCommand = \case
      NtfReqNew corrId (ANE SToken newTkn@(NewNtfTkn _ _ dhPubKey)) -> do
        st <- asks store
        (srvDhPubKey, srvDrivDhKey) <- liftIO C.generateKeyPair'
        let dhSecret = C.dh' dhPubKey srvDrivDhKey
        tknId <- getId
        regCode <- getRegCode
        atomically $ do
          tkn <- mkNtfTknData newTkn dhSecret regCode
          addNtfToken st tknId tkn
          writeTBQueue pushQ (tkn, PNVerification regCode)
        pure (corrId, "", NRId tknId srvDhPubKey)
      NtfReqCmd SToken (NtfTkn NtfTknData {tknStatus, tknRegCode}) (corrId, tknId, cmd) -> do
        status <- readTVarIO tknStatus
        (corrId,tknId,) <$> case cmd of
          TNEW newTkn -> pure NROk -- TODO when duplicate token sent
          TVFY code -- this allows repeated verification for cases when client connection dropped before server response
            | (status == NTRegistered || status == NTConfirmed || status == NTActive) && tknRegCode == code -> do
              atomically $ writeTVar tknStatus NTActive
              pure NROk
            | otherwise -> pure $ NRErr AUTH
          TDEL -> pure NROk
          TCRN int -> pure NROk
      NtfReqNew corrId (ANE SSubscription newSub) -> pure (corrId, "", NROk)
      NtfReqCmd SSubscription sub (corrId, subId, cmd) ->
        (corrId,subId,) <$> case cmd of
          SNEW newSub -> pure NROk
          SCHK -> pure NROk
          SDEL -> pure NROk
          PING -> pure NRPong
    getId :: m NtfEntityId
    getId = getRandomBytes =<< asks (subIdBytes . config)
    getRegCode :: m NtfRegCode
    getRegCode = NtfRegCode <$> (getRandomBytes =<< asks (regCodeBytes . config))
    getRandomBytes :: Int -> m ByteString
    getRandomBytes n = do
      gVar <- asks idsDrg
      atomically (C.pseudoRandomBytes n gVar)

-- NReqCreate corrId tokenId smpQueue -> pure (corrId, "", NROk)
-- do
-- st <- asks store
-- (pubDhKey, privDhKey) <- liftIO C.generateKeyPair'
-- let dhSecret = C.dh' dhPubKey privDhKey
-- sub <- atomically $ mkNtfSubsciption smpQueue token verifyKey dhSecret
-- addSubRetry 3 st sub >>= \case
--   Nothing -> pure (corrId, "", NRErr INTERNAL)
--   Just sId -> do
--     atomically $ writeTBQueue subQ sub
--     pure (corrId, sId, NRSubId pubDhKey)
-- where
--   addSubRetry :: Int -> NtfSubscriptionsStore -> NtfSubsciption -> m (Maybe NtfSubsciptionId)
--   addSubRetry 0 _ _ = pure Nothing
--   addSubRetry n st sub = do
--     sId <- getId
--     -- create QueueRec record with these ids and keys
--     atomically (addNtfSub st sId sub) >>= \case
--       Nothing -> addSubRetry (n - 1) st sub
--       _ -> pure $ Just sId
--   getId :: m NtfSubsciptionId
--   getId = do
--     n <- asks $ subIdBytes . config
--     gVar <- asks idsDrg
--     atomically (randomBytes n gVar)
-- NReqCommand sub@NtfSubsciption {tokenId, subStatus} (corrId, subId, cmd) ->
--   (corrId,subId,) <$> case cmd of
--     NCSubCreate tokenId smpQueue -> pure NROk
-- do
--   st <- asks store
--   (pubDhKey, privDhKey) <- liftIO C.generateKeyPair'
--   let dhSecret = C.dh' (dhPubKey newSub) privDhKey
--   atomically (updateNtfSub st sub newSub dhSecret) >>= \case
--     Nothing -> pure $ NRErr INTERNAL
--     _ -> atomically $ do
--       whenM ((== NSEnd) <$> readTVar status) $ writeTBQueue subQ sub
--       pure $ NRSubId pubDhKey
-- NCSubCheck -> NRStat <$> readTVarIO subStatus
-- NCSubDelete -> do
--   st <- asks store
--   atomically (deleteNtfSub st subId) $> NROk
