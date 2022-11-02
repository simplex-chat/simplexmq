{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Notifications.Server where

import Control.Concurrent.STM (stateTVar)
import Control.Logger.Simple
import Control.Monad.Except
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader
import Crypto.Random (MonadRandom)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.List (intercalate)
import Data.Map.Strict (Map)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import Data.Time.Clock.System (getSystemTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Network.Socket (ServiceName)
import Simplex.Messaging.Client (ProtocolClientError (..))
import Simplex.Messaging.Client.Agent
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Env
import Simplex.Messaging.Notifications.Server.Push.APNS (PNMessageData (..), PushNotification (..), PushProviderError (..))
import Simplex.Messaging.Notifications.Server.Stats
import Simplex.Messaging.Notifications.Server.Store
import Simplex.Messaging.Notifications.Server.StoreLog
import Simplex.Messaging.Notifications.Transport
import Simplex.Messaging.Protocol (ErrorType (..), ProtocolServer (host), SMPServer, SignedTransmission, Transmission, encodeTransmission, tGet, tPut)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server
import Simplex.Messaging.Server.Stats
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (ATransport (..), THandle (..), TProxy, Transport (..))
import Simplex.Messaging.Transport.Server (runTransportServer)
import Simplex.Messaging.Util
import System.Exit (exitFailure)
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering)
import System.Mem.Weak (deRefWeak)
import UnliftIO (IOMode (..), async, uninterruptibleCancel, withFile)
import UnliftIO.Concurrent (forkIO, killThread, mkWeakThreadId, threadDelay)
import UnliftIO.Directory (doesFileExist, renameFile)
import UnliftIO.Exception
import UnliftIO.STM
import GHC.Conc (unsafeIOToSTM)

runNtfServer :: (MonadRandom m, MonadUnliftIO m) => NtfServerConfig -> m ()
runNtfServer cfg = do
  started <- newEmptyTMVarIO
  runNtfServerBlocking started cfg

runNtfServerBlocking :: (MonadRandom m, MonadUnliftIO m) => TMVar Bool -> NtfServerConfig -> m ()
runNtfServerBlocking started cfg = runReaderT (ntfServer cfg started) =<< newNtfServerEnv cfg

ntfServer :: forall m. (MonadUnliftIO m, MonadReader NtfEnv m) => NtfServerConfig -> TMVar Bool -> m ()
ntfServer cfg@NtfServerConfig {transports} started = do
  restoreServerStats
  s <- asks subscriber
  ps <- asks pushServer
  subs <- readTVarIO =<< asks (subscriptions . store)
  void . forkIO $ resubscribe s subs
  raceAny_ (ntfSubscriber s : ntfPush ps : map runServer transports <> serverStatsThread_ cfg) `finally` stopServer
  where
    runServer :: (ServiceName, ATransport) -> m ()
    runServer (tcpPort, ATransport t) = do
      serverParams <- asks tlsServerParams
      runTransportServer started tcpPort serverParams (runClient t)

    runClient :: Transport c => TProxy c -> c -> m ()
    runClient _ h = do
      kh <- asks serverIdentity
      liftIO (runExceptT $ ntfServerHandshake h kh supportedNTFServerVRange) >>= \case
        Right th -> runNtfClientTransport th
        Left _ -> pure ()

    stopServer :: m ()
    stopServer = do
      withNtfLog closeStoreLog
      saveServerStats
      asks (smpSubscribers . subscriber) >>= readTVarIO >>= mapM_ (\SMPSubscriber {subThreadId} -> readTVarIO subThreadId >>= mapM_ (liftIO . deRefWeak >=> mapM_ killThread))

    serverStatsThread_ :: NtfServerConfig -> [m ()]
    serverStatsThread_ NtfServerConfig {logStatsInterval = Just interval, logStatsStartTime, serverStatsLogFile} =
      [logServerStats logStatsStartTime interval serverStatsLogFile]
    serverStatsThread_ _ = []

    logServerStats :: Int -> Int -> FilePath -> m ()
    logServerStats startAt logInterval statsFilePath = do
      initialDelay <- (startAt -) . fromIntegral . (`div` 1000000_000000) . diffTimeToPicoseconds . utctDayTime <$> liftIO getCurrentTime
      liftIO $ putStrLn $ "server stats log enabled: " <> statsFilePath
      threadDelay $ 1000000 * (initialDelay + if initialDelay < 0 then 86400 else 0)
      NtfServerStats {fromTime, tknCreated, tknVerified, tknDeleted, subCreated, subDeleted, ntfReceived, ntfDelivered, activeTokens, activeSubs} <- asks serverStats
      let interval = 1000000 * logInterval
      withFile statsFilePath AppendMode $ \h -> liftIO $ do
        hSetBuffering h LineBuffering
        forever $ do
          ts <- getCurrentTime
          fromTime' <- atomically $ swapTVar fromTime ts
          tknCreated' <- atomically $ swapTVar tknCreated 0
          tknVerified' <- atomically $ swapTVar tknVerified 0
          tknDeleted' <- atomically $ swapTVar tknDeleted 0
          subCreated' <- atomically $ swapTVar subCreated 0
          subDeleted' <- atomically $ swapTVar subDeleted 0
          ntfReceived' <- atomically $ swapTVar ntfReceived 0
          ntfDelivered' <- atomically $ swapTVar ntfDelivered 0
          tkn <- atomically $ periodStatCounts activeTokens ts
          sub <- atomically $ periodStatCounts activeSubs ts
          hPutStrLn h $
            intercalate
              ","
              [ iso8601Show $ utctDay fromTime',
                show tknCreated',
                show tknVerified',
                show tknDeleted',
                show subCreated',
                show subDeleted',
                show ntfReceived',
                show ntfDelivered',
                dayCount tkn,
                weekCount tkn,
                monthCount tkn,
                dayCount sub,
                weekCount sub,
                monthCount sub
              ]
          threadDelay interval

resubscribe :: (MonadUnliftIO m, MonadReader NtfEnv m) => NtfSubscriber -> Map NtfSubscriptionId NtfSubData -> m ()
resubscribe NtfSubscriber {newSubQ} subs = do
  d <- asks $ resubscribeDelay . config
  forM_ subs $ \sub@NtfSubData {} ->
    whenM (ntfShouldSubscribe <$> readTVarIO (subStatus sub)) $ do
      atomically $ writeTBQueue newSubQ $ NtfSub sub
      threadDelay d
  liftIO $ logInfo "SMP connections resubscribed"

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
            atomically $ writeTQueue subscriberSubQ sub

    getSMPSubscriber :: SMPServer -> m SMPSubscriber
    getSMPSubscriber smpServer =
      atomically (TM.lookup smpServer smpSubscribers) >>= maybe createSMPSubscriber pure
      where
        createSMPSubscriber = do
          sub@SMPSubscriber {subThreadId} <- atomically newSMPSubscriber
          atomically $ TM.insert smpServer sub smpSubscribers
          tId <- mkWeakThreadId =<< forkIO (runSMPSubscriber sub)
          atomically . writeTVar subThreadId $ Just tId
          pure sub

    runSMPSubscriber :: SMPSubscriber -> m ()
    runSMPSubscriber SMPSubscriber {newSubQ = subscriberSubQ} =
      forever $
        atomically (peekTQueue subscriberSubQ)
          >>= \(NtfSub NtfSubData {smpQueue, notifierKey}) -> do
            updateSubStatus smpQueue NSPending
            let SMPQueueNtf {smpServer, notifierId} = smpQueue
            liftIO (runExceptT $ subscribeQueue ca smpServer ((SPNotifier, notifierId), notifierKey)) >>= \case
              Right _ -> do
                updateSubStatus smpQueue NSActive
                void . atomically $ readTQueue subscriberSubQ
              Left err -> do
                handleSubError smpQueue err
                case err of
                  PCEResponseTimeout -> pure ()
                  PCENetworkError -> pure ()
                  _ -> void . atomically $ readTQueue subscriberSubQ

    receiveSMP :: m ()
    receiveSMP = forever $ do
      (srv, _, _, ntfId, msg) <- atomically $ readTBQueue msgQ
      let smpQueue = SMPQueueNtf srv ntfId
      case msg of
        SMP.NMSG nmsgNonce encNMsgMeta -> do
          ntfTs <- liftIO getSystemTime
          st <- asks store
          NtfPushServer {pushQ} <- asks pushServer
          stats <- asks serverStats
          atomically $ updatePeriodStats (activeSubs stats) ntfId
          atomically $
            findNtfSubscriptionToken st smpQueue
              >>= mapM_
                ( \tkn -> do
                    writeTBQueue pushQ (tkn, PNMessage PNMessageData {smpQueue, ntfTs, nmsgNonce, encNMsgMeta})
                    unsafeIOToSTM . putStrLn $ "notification queued APNS " <> show ntfId
                )
          incNtfStat ntfReceived
        SMP.END -> updateSubStatus smpQueue NSEnd
        _ -> pure ()
      pure ()

    receiveAgent =
      forever $
        atomically (readTBQueue agentQ) >>= \case
          CAConnected _ -> pure ()
          CADisconnected srv subs -> do
            logInfo $ "SMP server disconnected " <> showServer' srv <> " (" <> tshow (length subs) <> ") subscriptions"
            forM_ subs $ \(_, ntfId) -> do
              let smpQueue = SMPQueueNtf srv ntfId
              updateSubStatus smpQueue NSInactive
          CAReconnected srv ->
            logInfo $ "SMP server reconnected " <> showServer' srv
          CAResubscribed srv sub -> do
            let ntfId = snd sub
                smpQueue = SMPQueueNtf srv ntfId
            updateSubStatus smpQueue NSActive
          CASubError srv (_, ntfId) err -> do
            logError $ "SMP subscription error on server " <> showServer' srv <> ": " <> tshow err
            handleSubError (SMPQueueNtf srv ntfId) err
      where
        showServer' = decodeLatin1 . strEncode . host

    handleSubError :: SMPQueueNtf -> ProtocolClientError -> m ()
    handleSubError smpQueue = \case
      PCEProtocolError AUTH -> updateSubStatus smpQueue NSAuth
      PCEProtocolError e -> updateErr "SMP error " e
      PCEIOError e -> updateErr "IOError " e
      PCEResponseError e -> updateErr "ResponseError " e
      PCEUnexpectedResponse r -> updateErr "UnexpectedResponse " r
      PCETransportError e -> updateErr "TransportError " e
      PCESignatureError e -> updateErr "SignatureError " e
      PCEIncompatibleHost -> updateSubStatus smpQueue $ NSErr "IncompatibleHost"
      PCEResponseTimeout -> pure ()
      PCENetworkError -> pure ()
      where
        updateErr :: Show e => ByteString -> e -> m ()
        updateErr errType e = updateSubStatus smpQueue . NSErr $ errType <> bshow e

    updateSubStatus smpQueue status = do
      st <- asks store
      atomically (findNtfSubscription st smpQueue)
        >>= mapM_
          ( \NtfSubData {ntfSubId, subStatus} -> do
              atomically $ writeTVar subStatus status
              withNtfLog $ \sl -> logSubscriptionStatus sl ntfSubId status
          )

ntfPush :: forall m. (MonadUnliftIO m, MonadReader NtfEnv m) => NtfPushServer -> m ()
ntfPush s@NtfPushServer {pushQ} = forever $ do
  (tkn@NtfTknData {ntfTknId, token = DeviceToken pp _, tknStatus}, ntf) <- atomically (readTBQueue pushQ)
  liftIO $ logDebug $ "sending push notification to " <> T.pack (show pp)
  status <- readTVarIO tknStatus
  case (status, ntf) of
    (_, PNVerification _) ->
      -- TODO check token status
      deliverNotification pp tkn ntf >>= \case
        Right _ -> do
          status_ <- atomically $ stateTVar tknStatus $ \status' -> if status' == NTActive then (Nothing, NTActive) else (Just NTConfirmed, NTConfirmed)
          forM_ status_ $ \status' -> withNtfLog $ \sl -> logTokenStatus sl ntfTknId status'
        _ -> pure ()
    (NTActive, PNCheckMessages) ->
      void $ deliverNotification pp tkn ntf
    (NTActive, PNMessage {}) -> do
      stats <- asks serverStats
      atomically $ updatePeriodStats (activeTokens stats) ntfTknId
      void $ deliverNotification pp tkn ntf
      incNtfStat ntfDelivered
    _ ->
      liftIO $ logError "bad notification token status"
  where
    deliverNotification :: PushProvider -> NtfTknData -> PushNotification -> m (Either PushProviderError ())
    deliverNotification pp tkn@NtfTknData {ntfTknId, tknStatus} ntf = do
      deliver <- liftIO $ getPushClient s pp
      liftIO (runExceptT $ deliver tkn ntf) >>= \case
        Right _ -> pure $ Right ()
        Left e -> case e of
          PPConnection _ -> retryDeliver
          PPRetryLater -> retryDeliver
          -- TODO alert
          PPCryptoError _ -> err e
          PPResponseError _ _ -> err e
          PPTokenInvalid -> updateTknStatus NTInvalid >> err e
          PPPermanentError -> err e
      where
        retryDeliver :: m (Either PushProviderError ())
        retryDeliver = do
          deliver <- liftIO $ newPushClient s pp
          liftIO (runExceptT $ deliver tkn ntf) >>= either err (pure . Right)
        updateTknStatus :: NtfTknStatus -> m ()
        updateTknStatus status = do
          atomically $ writeTVar tknStatus status
          withNtfLog $ \sl -> logTokenStatus sl ntfTknId status
        err e = logError (T.pack $ "Push provider error (" <> show pp <> "): " <> show e) $> Left e

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
  ts <- tGet th
  forM_ ts $ \t@(_, _, (corrId, entId, cmdOrError)) -> do
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
  void . liftIO $ tPut h [(Nothing, encodeTransmission v sessionId t)]
  atomically . writeTVar activeAt =<< liftIO getSystemTime

-- instance Show a => Show (TVar a) where
--   show x = unsafePerformIO $ show <$> readTVarIO x

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
client NtfServerClient {rcvQ, sndQ} NtfSubscriber {newSubQ, smpAgent = ca} NtfPushServer {pushQ, intervalNotifiers} =
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
        tkn <- atomically $ mkNtfTknData tknId newTkn ks dhSecret regCode
        atomically $ addNtfToken st tknId tkn
        atomically $ writeTBQueue pushQ (tkn, PNVerification regCode)
        withNtfLog (`logCreateToken` tkn)
        incNtfStat tknCreated
        pure (corrId, "", NRTknId tknId srvDhPubKey)
      NtfReqCmd SToken (NtfTkn tkn@NtfTknData {ntfTknId, tknStatus, tknRegCode, tknDhSecret, tknDhKeys = (srvDhPubKey, srvDhPrivKey), tknCronInterval}) (corrId, tknId, cmd) -> do
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
              withNtfLog $ \s -> logTokenStatus s tknId NTActive
              incNtfStat tknVerified
              pure NROk
            | otherwise -> do
              logDebug "TVFY - incorrect code or token status"
              pure $ NRErr AUTH
          TCHK -> do
            logDebug "TCHK"
            pure $ NRTkn status
          TRPL token' -> do
            logDebug "TRPL - replace token"
            st <- asks store
            regCode <- getRegCode
            atomically $ do
              removeTokenRegistration st tkn
              writeTVar tknStatus NTRegistered
              let tkn' = tkn {token = token', tknRegCode = regCode}
              addNtfToken st tknId tkn'
              writeTBQueue pushQ (tkn', PNVerification regCode)
            withNtfLog $ \s -> logUpdateToken s tknId token' regCode
            incNtfStat tknDeleted
            incNtfStat tknCreated
            pure NROk
          TDEL -> do
            logDebug "TDEL"
            st <- asks store
            qs <- atomically $ deleteNtfToken st tknId
            forM_ qs $ \SMPQueueNtf {smpServer, notifierId} ->
              atomically $ removeSubscription ca smpServer (SPNotifier, notifierId)
            cancelInvervalNotifications tknId
            withNtfLog (`logDeleteToken` tknId)
            incNtfStat tknDeleted
            pure NROk
          TCRN 0 -> do
            logDebug "TCRN 0"
            atomically $ writeTVar tknCronInterval 0
            cancelInvervalNotifications tknId
            withNtfLog $ \s -> logTokenCron s tknId 0
            pure NROk
          TCRN int
            | int < 20 -> pure $ NRErr QUOTA
            | otherwise -> do
              logDebug "TCRN"
              atomically $ writeTVar tknCronInterval int
              atomically (TM.lookup tknId intervalNotifiers) >>= \case
                Nothing -> runIntervalNotifier int
                Just IntervalNotifier {interval, action} ->
                  unless (interval == int) $ do
                    uninterruptibleCancel action
                    runIntervalNotifier int
              withNtfLog $ \s -> logTokenCron s tknId int
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
        sub <- atomically $ mkNtfSubData subId newSub
        resp <-
          atomically (addNtfSubscription st subId sub) >>= \case
            Just _ -> atomically (writeTBQueue newSubQ $ NtfSub sub) $> NRSubId subId
            _ -> pure $ NRErr AUTH
        withNtfLog (`logCreateSubscription` sub)
        incNtfStat subCreated
        pure (corrId, "", resp)
      NtfReqCmd SSubscription (NtfSub NtfSubData {smpQueue = SMPQueueNtf {smpServer, notifierId}, notifierKey = registeredNKey, subStatus}) (corrId, subId, cmd) -> do
        status <- readTVarIO subStatus
        (corrId,subId,) <$> case cmd of
          SNEW (NewNtfSub _ _ notifierKey) -> do
            logDebug "SNEW - existing subscription"
            -- TODO retry if subscription failed, if pending or AUTH do nothing
            pure $
              if notifierKey == registeredNKey
                then NRSubId subId
                else NRErr AUTH
          SCHK -> do
            logDebug "SCHK"
            pure $ NRSub status
          SDEL -> do
            logDebug "SDEL"
            st <- asks store
            atomically $ deleteNtfSubscription st subId
            atomically $ removeSubscription ca smpServer (SPNotifier, notifierId)
            withNtfLog (`logDeleteSubscription` subId)
            incNtfStat subDeleted
            pure NROk
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

withNtfLog :: (MonadUnliftIO m, MonadReader NtfEnv m) => (StoreLog 'WriteMode -> IO a) -> m ()
withNtfLog action = liftIO . mapM_ action =<< asks storeLog

incNtfStat :: (MonadUnliftIO m, MonadReader NtfEnv m) => (NtfServerStats -> TVar Int) -> m ()
incNtfStat statSel = do
  stats <- asks serverStats
  atomically $ modifyTVar (statSel stats) (+ 1)

saveServerStats :: (MonadUnliftIO m, MonadReader NtfEnv m) => m ()
saveServerStats =
  asks (serverStatsBackupFile . config)
    >>= mapM_ (\f -> asks serverStats >>= atomically . getNtfServerStatsData >>= liftIO . saveStats f)
  where
    saveStats f stats = do
      logInfo $ "saving server stats to file " <> T.pack f
      B.writeFile f $ strEncode stats
      logInfo "server stats saved"

restoreServerStats :: (MonadUnliftIO m, MonadReader NtfEnv m) => m ()
restoreServerStats = asks (serverStatsBackupFile . config) >>= mapM_ restoreStats
  where
    restoreStats f = whenM (doesFileExist f) $ do
      logInfo $ "restoring server stats from file " <> T.pack f
      liftIO (strDecode <$> B.readFile f) >>= \case
        Right d -> do
          s <- asks serverStats
          atomically $ setNtfServerStats s d
          renameFile f $ f <> ".bak"
          logInfo "server stats restored"
        Left e -> do
          logInfo $ "error restoring server stats: " <> T.pack e
          liftIO exitFailure
