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

import Control.Logger.Simple
import Control.Monad.Except
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader
import Crypto.Random (MonadRandom)
import Data.ByteString.Char8 (ByteString)
import qualified Data.Text as T
import Network.Socket (ServiceName)
import Simplex.Messaging.Client.Agent
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Env
import Simplex.Messaging.Notifications.Server.Push.APNS
import Simplex.Messaging.Notifications.Server.Store
import Simplex.Messaging.Notifications.Transport
import Simplex.Messaging.Protocol (ErrorType (..), SignedTransmission, Transmission, encodeTransmission, tGet, tPut)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (ATransport (..), THandle (..), TProxy, Transport)
import Simplex.Messaging.Transport.Server (runTransportServer)
import Simplex.Messaging.Util
import UnliftIO (async, uninterruptibleCancel)
import UnliftIO.Concurrent (threadDelay)
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

ntfSubscriber :: forall m. MonadUnliftIO m => NtfSubscriber -> m ()
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
            Left _e -> pure ()

    receiveSMP :: m ()
    receiveSMP = forever $ do
      (_srv, _sessId, _ntfId, msg) <- atomically $ readTBQueue msgQ
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
          CADisconnected _srv _subs -> do
            -- update subscription statuses
            pure ()
          CAReconnected _ -> pure ()
          CAResubscribed _srv _sub -> do
            -- update subscription status
            pure ()
          CASubError _srv _sub _err -> do
            -- update subscription status
            pure ()

ntfPush :: MonadUnliftIO m => NtfPushServer -> m ()
ntfPush s@NtfPushServer {pushQ} = liftIO . forever . runExceptT $ do
  (tkn@NtfTknData {token = DeviceToken pp _, tknStatus}, ntf) <- atomically (readTBQueue pushQ)
  logDebug $ "sending push notification to " <> T.pack (show pp)
  status <- readTVarIO tknStatus
  case (status, ntf) of
    (_, PNVerification _) -> do
      -- TODO check token status
      deliverNotification pp tkn ntf
      atomically $ modifyTVar tknStatus $ \status' -> if status' == NTActive then NTActive else NTConfirmed
    (NTActive, PNCheckMessages) -> do
      deliverNotification pp tkn ntf
    _ -> do
      logError "bad notification token status"
  where
    deliverNotification :: PushProvider -> PushProviderClient
    deliverNotification pp tkn ntf = do
      deliver <- liftIO $ getPushClient s pp
      -- TODO retry later based on the error
      deliver tkn ntf `catchError` \e -> logError (T.pack $ "Push provider error (" <> show pp <> "): " <> show e) >> throwError e

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
  t@(_, _, (corrId, entId, cmdOrError)) <- tGet th
  logDebug "received transmission"
  case cmdOrError of
    Left e -> write sndQ (corrId, entId, NRErr e)
    Right cmd ->
      verifyNtfTransmission t cmd >>= \case
        VRVerified req -> write rcvQ req
        VRFailed -> write sndQ (corrId, entId, NRErr AUTH)
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
  st <- asks store
  case cmd of
    NtfCmd SToken c@(TNEW tkn@(NewNtfTkn _ k _)) -> do
      r_ <- atomically $ getNtfTokenRegistration st tkn
      pure $
        if verifyCmdSignature sig_ signed k
          then case r_ of
            Just t@NtfTknData {tknVerifyKey}
              | k == tknVerifyKey -> verifiedTknCmd t c
              | otherwise -> VRFailed
            _ -> VRVerified (NtfReqNew corrId (ANE SToken tkn))
          else VRFailed
    NtfCmd SToken c -> do
      t_ <- atomically $ getNtfToken st entId
      pure $ case t_ of
        Just t@NtfTknData {tknVerifyKey}
          | verifyCmdSignature sig_ signed tknVerifyKey -> verifiedTknCmd t c
          | otherwise -> VRFailed
        _ -> maybe False (dummyVerifyCmd signed) sig_ `seq` VRFailed
    _ -> pure VRFailed
  where
    verifiedTknCmd t c = VRVerified (NtfReqCmd SToken (NtfTkn t) (corrId, entId, c))

client :: forall m. (MonadUnliftIO m, MonadReader NtfEnv m) => NtfServerClient -> NtfSubscriber -> NtfPushServer -> m ()
client NtfServerClient {rcvQ, sndQ} NtfSubscriber {subQ = _} NtfPushServer {pushQ, intervalNotifiers} =
  forever $
    atomically (readTBQueue rcvQ)
      >>= processCommand
      >>= atomically . writeTBQueue sndQ
  where
    processCommand :: NtfRequest -> m (Transmission NtfResponse)
    processCommand = \case
      NtfReqNew corrId (ANE SToken newTkn@(NewNtfTkn _ _ dhPubKey)) -> do
        logDebug "TNEW - new token"
        st <- asks store
        ks@(srvDhPubKey, srvDhPrivKey) <- liftIO C.generateKeyPair'
        let dhSecret = C.dh' dhPubKey srvDhPrivKey
        tknId <- getId
        regCode <- getRegCode
        atomically $ do
          tkn <- mkNtfTknData tknId newTkn ks dhSecret regCode
          addNtfToken st tknId tkn
          writeTBQueue pushQ (tkn, PNVerification regCode)
        pure (corrId, "", NRId tknId srvDhPubKey)
      NtfReqCmd SToken (NtfTkn tkn@NtfTknData {ntfTknId, tknStatus, tknRegCode, tknDhSecret, tknDhKeys = (srvDhPubKey, srvDhPrivKey)}) (corrId, tknId, cmd) -> do
        status <- readTVarIO tknStatus
        (corrId,tknId,) <$> case cmd of
          TNEW (NewNtfTkn _ _ dhPubKey) -> do
            logDebug "TNEW - registered token"
            let dhSecret = C.dh' dhPubKey srvDhPrivKey
            -- it is required that DH secret is the same, to avoid failed verifications if notification is delaying
            if tknDhSecret == dhSecret
              then do
                atomically $ writeTBQueue pushQ (tkn, PNVerification tknRegCode)
                pure $ NRId ntfTknId srvDhPubKey
              else pure $ NRErr AUTH
          TVFY code -- this allows repeated verification for cases when client connection dropped before server response
            | (status == NTRegistered || status == NTConfirmed || status == NTActive) && tknRegCode == code -> do
              logDebug "TVFY - token verified"
              st <- asks store
              atomically $ writeTVar tknStatus NTActive
              tIds <- atomically $ removeInactiveTokenRegistrations st tkn
              forM_ tIds cancelInvervalNotifications
              pure NROk
            | otherwise -> do
              logDebug "TVFY - incorrect code or token status"
              pure $ NRErr AUTH
          TCHK -> pure $ NRTkn status
          TDEL -> do
            logDebug "TDEL"
            st <- asks store
            atomically $ deleteNtfToken st tknId
            cancelInvervalNotifications tknId
            pure NROk
          TCRN 0 -> do
            logDebug "TCRN 0"
            cancelInvervalNotifications tknId
            pure NROk
          TCRN int
            | int < 20 -> pure $ NRErr QUOTA
            | otherwise -> do
              logDebug "TCRN"
              atomically (TM.lookup tknId intervalNotifiers) >>= \case
                Nothing -> runIntervalNotifier int
                Just IntervalNotifier {interval, action} ->
                  unless (interval == int) $ do
                    uninterruptibleCancel action
                    runIntervalNotifier int
              pure NROk
            where
              runIntervalNotifier interval = do
                action <- async . intervalNotifier $ fromIntegral interval * 1000000 * 60
                let notifier = IntervalNotifier {action, token = tkn, interval}
                atomically $ TM.insert tknId notifier intervalNotifiers
                where
                  intervalNotifier delay = forever $ do
                    threadDelay delay
                    atomically $ writeTBQueue pushQ (tkn, PNCheckMessages)
      NtfReqNew corrId (ANE SSubscription _newSub) -> pure (corrId, "", NROk)
      NtfReqCmd SSubscription _sub (corrId, subId, cmd) ->
        (corrId,subId,) <$> case cmd of
          SNEW _newSub -> pure NROk
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
    cancelInvervalNotifications :: NtfTokenId -> m ()
    cancelInvervalNotifications tknId =
      atomically (TM.lookupDelete tknId intervalNotifiers)
        >>= mapM_ (uninterruptibleCancel . action)

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
