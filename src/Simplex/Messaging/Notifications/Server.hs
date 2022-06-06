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
import Data.Functor (($>))
import qualified Data.Text as T
import Data.Time.Clock.System (getSystemTime)
import Network.Socket (ServiceName)
import Simplex.Messaging.Client.Agent
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Env
import Simplex.Messaging.Notifications.Server.Push.APNS
import Simplex.Messaging.Notifications.Server.Store
import Simplex.Messaging.Notifications.Transport
import Simplex.Messaging.Protocol (ErrorType (..), SMPServer, SignedTransmission, Transmission, encodeTransmission, tGet, tPut)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (ATransport (..), THandle (..), TProxy, Transport (..))
import Simplex.Messaging.Transport.Server (runTransportServer)
import Simplex.Messaging.Util
import UnliftIO (async, uninterruptibleCancel)
import UnliftIO.Concurrent (forkFinally, threadDelay)
import UnliftIO.Exception
import UnliftIO.STM

runNtfServer :: (MonadRandom m, MonadUnliftIO m) => NtfServerConfig -> m ()
runNtfServer cfg = do
  started <- newEmptyTMVarIO
  runNtfServerBlocking started cfg

runNtfServerBlocking :: (MonadRandom m, MonadUnliftIO m) => TMVar Bool -> NtfServerConfig -> m ()
runNtfServerBlocking started cfg = runReaderT (ntfServer cfg started) =<< newNtfServerEnv cfg

ntfServer :: forall m. (MonadUnliftIO m, MonadReader NtfEnv m) => NtfServerConfig -> TMVar Bool -> m ()
ntfServer NtfServerConfig {transports} started = do
  s <- asks subscriber
  ps <- asks pushServer
  raceAny_ (ntfSubscriber s : ntfPush ps : map runServer transports)
  where
    runServer :: (ServiceName, ATransport) -> m ()
    runServer (tcpPort, ATransport t) = do
      serverParams <- asks tlsServerParams
      runTransportServer started tcpPort serverParams (runClient t)

    runClient :: Transport c => TProxy c -> c -> m ()
    runClient _ h = do
      kh <- asks serverIdentity
      liftIO (runExceptT $ ntfServerHandshake h kh) >>= \case
        Right th -> runNtfClientTransport th
        Left _ -> pure ()

ntfSubscriber :: forall m. (MonadUnliftIO m, MonadReader NtfEnv m) => NtfSubscriber -> m ()
ntfSubscriber NtfSubscriber {smpSubscribers, newSubQ, smpAgent = ca@SMPClientAgent {msgQ, agentQ}} = do
  raceAny_ [subscribe, receiveSMP, receiveAgent]
  where
    subscribe :: m ()
    subscribe =
      forever $
        atomically (readTBQueue newSubQ) >>= \case
          sub@(NtfSub NtfSubData {smpQueue = SMPQueueNtf {smpServer}}) -> do
            SMPSubscriber {newSubQ = subscriberSubQ} <- getSMPSubscriber smpServer
            atomically $ writeTBQueue subscriberSubQ sub

    getSMPSubscriber :: SMPServer -> m SMPSubscriber
    getSMPSubscriber smpServer =
      atomically (TM.lookup smpServer smpSubscribers) >>= maybe createSMPSubscriber pure
      where
        createSMPSubscriber = do
          qSize <- asks $ subQSize . config
          newSubscriber <- atomically $ newSMPSubscriber qSize
          atomically $ TM.insert smpServer newSubscriber smpSubscribers
          _ <- runSMPSubscriber newSubscriber `forkFinally` \_ -> atomically (TM.delete smpServer smpSubscribers >> failSubscriptions newSubscriber)
          pure newSubscriber
        -- TODO mark subscriptions as failed
        failSubscriptions _ = pure ()

    runSMPSubscriber :: SMPSubscriber -> m ()
    runSMPSubscriber SMPSubscriber {newSubQ = subscriberSubQ} =
      forever $
        atomically (peekTBQueue subscriberSubQ) >>= \case
          NtfSub NtfSubData {smpQueue, notifierKey} -> do
            let SMPQueueNtf {smpServer, notifierId} = smpQueue
            liftIO (runExceptT $ subscribeQueue ca smpServer ((SPNotifier, notifierId), notifierKey)) >>= \case
              Right _ -> do
                -- update subscription status
                _ <- atomically $ readTBQueue subscriberSubQ
                pure ()
              Left _e -> pure ()

    receiveSMP :: m ()
    receiveSMP = forever $ do
      (srv, _sessId, ntfId, msg) <- atomically $ readTBQueue msgQ
      case msg of
        SMP.NMSG -> do
          -- check when the last NMSG was received from this queue
          -- update timestamp
          -- check what was the last hidden notification was sent (and whether to this queue)
          -- decide whether it should be sent as hidden or visible
          -- construct and possibly encrypt notification
          -- send it
          NtfPushServer {pushQ} <- asks pushServer
          st <- asks store
          atomically $
            findNtfSubscriptionToken st (SMPQueueNtf srv ntfId)
              >>= mapM_ (\tkn -> writeTBQueue pushQ (tkn, PNMessage srv ntfId))
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
  ts <- liftIO getSystemTime
  c <- atomically $ newNtfServerClient qSize sessionId ts
  s <- asks subscriber
  ps <- asks pushServer
  expCfg <- asks $ inactiveClientExpiration . config
  raceAny_ ([send th c, client c s ps, receive th c] <> disconnectThread_ c expCfg)
    `finally` clientDisconnected c
  where
    disconnectThread_ c expCfg = maybe [] ((: []) . disconnectTransport th c activeAt) expCfg

clientDisconnected :: MonadUnliftIO m => NtfServerClient -> m ()
clientDisconnected NtfServerClient {connected} = atomically $ writeTVar connected False

receive :: (Transport c, MonadUnliftIO m, MonadReader NtfEnv m) => THandle c -> NtfServerClient -> m ()
receive th NtfServerClient {rcvQ, sndQ, activeAt} = forever $ do
  t@(_, _, (corrId, entId, cmdOrError)) <- tGet th
  atomically . writeTVar activeAt =<< liftIO getSystemTime
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
send h@THandle {thVersion = v} NtfServerClient {sndQ, sessionId, activeAt} = forever $ do
  t <- atomically $ readTBQueue sndQ
  void . liftIO $ tPut h (Nothing, encodeTransmission v sessionId t)
  atomically . writeTVar activeAt =<< liftIO getSystemTime

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
      verifyToken t_ (`verifiedTknCmd` c)
    NtfCmd SSubscription c@(SNEW sub@(NewNtfSub tknId smpQueue _)) -> do
      s_ <- atomically $ findNtfSubscription st smpQueue
      case s_ of
        Nothing -> do
          -- TODO move active token check here to differentiate error
          t_ <- atomically $ getActiveNtfToken st tknId
          verifyToken' t_ $ VRVerified (NtfReqNew corrId (ANE SSubscription sub))
        Just s@NtfSubData {tokenId = subTknId} ->
          if subTknId == tknId
            then do
              -- TODO move active token check here to differentiate error
              t_ <- atomically $ getActiveNtfToken st subTknId
              verifyToken' t_ $ verifiedSubCmd s c
            else pure $ maybe False (dummyVerifyCmd signed) sig_ `seq` VRFailed
    NtfCmd SSubscription c -> do
      s_ <- atomically $ getNtfSubscription st entId
      case s_ of
        Just s@NtfSubData {tokenId = subTknId} -> do
          -- TODO move active token check here to differentiate error
          t_ <- atomically $ getActiveNtfToken st subTknId
          verifyToken' t_ $ verifiedSubCmd s c
        _ -> pure $ maybe False (dummyVerifyCmd signed) sig_ `seq` VRFailed
  where
    verifiedTknCmd t c = VRVerified (NtfReqCmd SToken (NtfTkn t) (corrId, entId, c))
    verifiedSubCmd s c = VRVerified (NtfReqCmd SSubscription (NtfSub s) (corrId, entId, c))
    verifyToken :: Maybe NtfTknData -> (NtfTknData -> VerificationResult) -> m VerificationResult
    verifyToken t_ positiveVerificationResult =
      pure $ case t_ of
        Just t@NtfTknData {tknVerifyKey} ->
          if verifyCmdSignature sig_ signed tknVerifyKey
            then positiveVerificationResult t
            else VRFailed
        _ -> maybe False (dummyVerifyCmd signed) sig_ `seq` VRFailed
    verifyToken' :: Maybe NtfTknData -> VerificationResult -> m VerificationResult
    verifyToken' t_ = verifyToken t_ . const

client :: forall m. (MonadUnliftIO m, MonadReader NtfEnv m) => NtfServerClient -> NtfSubscriber -> NtfPushServer -> m ()
client NtfServerClient {rcvQ, sndQ} NtfSubscriber {newSubQ} NtfPushServer {pushQ, intervalNotifiers} =
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
        pure (corrId, "", NRTknId tknId srvDhPubKey)
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
                pure $ NRTknId ntfTknId srvDhPubKey
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
      NtfReqNew corrId (ANE SSubscription newSub) -> do
        logDebug "SNEW - new subscription"
        st <- asks store
        subId <- getId
        atomically $ do
          sub <- mkNtfSubData newSub
          (corrId,"",)
            <$> ( addNtfSubscription st subId sub >>= \case
                    Just _ -> writeTBQueue newSubQ (NtfSub sub) $> NRSubId subId
                    _ -> pure $ NRErr AUTH
                )
      NtfReqCmd SSubscription (NtfSub NtfSubData {notifierKey = registeredNKey}) (corrId, subId, cmd) ->
        (corrId,subId,) <$> case cmd of
          SNEW (NewNtfSub _ _ notifierKey) -> do
            logDebug "SNEW - existing subscription"
            -- TODO retry if subscription failed, if pending or AUTH do nothing
            pure $
              if notifierKey == registeredNKey
                then NRSubId subId
                else NRErr AUTH
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
