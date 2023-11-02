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

import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List (intercalate, sort)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import Data.Time.Clock.System (getSystemTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Network.Socket (ServiceName)
import Simplex.Messaging.Client (ProtocolClientError (..), SMPClientError)
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
import UnliftIO.Concurrent (forkIO, killThread, mkWeakThreadId)
import UnliftIO.Directory (doesFileExist, renameFile)
import UnliftIO.Exception
import UnliftIO.STM

runNtfServer :: NtfServerConfig -> IO ()
runNtfServer cfg = do
  started <- newEmptyTMVarIO
  runNtfServerBlocking started cfg

runNtfServerBlocking :: TMVar Bool -> NtfServerConfig -> IO ()
runNtfServerBlocking started cfg = runReaderT (ntfServer cfg started) =<< newNtfServerEnv cfg

type M a = ReaderT NtfEnv IO a

ntfServer :: NtfServerConfig -> TMVar Bool -> M ()
ntfServer cfg@NtfServerConfig {transports, transportConfig = tCfg} started = do
  restoreServerStats
  s <- asks subscriber
  ps <- asks pushServer
  subs <- readTVarIO =<< asks (subscriptions . store)
  void . forkIO $ resubscribe s subs
  raceAny_ (ntfSubscriber s : ntfPush ps : map runServer transports <> serverStatsThread_ cfg) `finally` stopServer
  where
    runServer :: (ServiceName, ATransport) -> M ()
    runServer (tcpPort, ATransport t) = do
      serverParams <- asks tlsServerParams
      runTransportServer started tcpPort serverParams tCfg (runClient t)

    runClient :: Transport c => TProxy c -> c -> M ()
    runClient _ h = do
      kh <- asks serverIdentity
      liftIO (runExceptT $ ntfServerHandshake h kh supportedNTFServerVRange) >>= \case
        Right th -> runNtfClientTransport th
        Left _ -> pure ()

    stopServer :: M ()
    stopServer = do
      withNtfLog closeStoreLog
      saveServerStats
      asks (smpSubscribers . subscriber) >>= readTVarIO >>= mapM_ (\SMPSubscriber {subThreadId} -> readTVarIO subThreadId >>= mapM_ (liftIO . deRefWeak >=> mapM_ killThread))

    serverStatsThread_ :: NtfServerConfig -> [M ()]
    serverStatsThread_ NtfServerConfig {logStatsInterval = Just interval, logStatsStartTime, serverStatsLogFile} =
      [logServerStats logStatsStartTime interval serverStatsLogFile]
    serverStatsThread_ _ = []

    logServerStats :: Int64 -> Int64 -> FilePath -> M ()
    logServerStats startAt logInterval statsFilePath = do
      initialDelay <- (startAt -) . fromIntegral . (`div` 1000000_000000) . diffTimeToPicoseconds . utctDayTime <$> liftIO getCurrentTime
      liftIO $ putStrLn $ "server stats log enabled: " <> statsFilePath
      liftIO $ threadDelay' $ 1000000 * (initialDelay + if initialDelay < 0 then 86400 else 0)
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
          threadDelay' interval

resubscribe :: NtfSubscriber -> Map NtfSubscriptionId NtfSubData -> M ()
resubscribe NtfSubscriber {newSubQ} subs = do
  subs' <- atomically $ filterM (fmap ntfShouldSubscribe . readTVar . subStatus) $ M.elems subs
  atomically . writeTBQueue newSubQ $ map NtfSub subs'
  liftIO $ logInfo $ "SMP resubscriptions queued (" <> tshow (length subs') <> " subscriptions)"

ntfSubscriber :: NtfSubscriber -> M ()
ntfSubscriber NtfSubscriber {smpSubscribers, newSubQ, smpAgent = ca@SMPClientAgent {msgQ, agentQ}} = do
  raceAny_ [subscribe, receiveSMP, receiveAgent]
  where
    subscribe :: M ()
    subscribe = forever $ do
      subs <- atomically (readTBQueue newSubQ)
      let ss = L.groupAllWith server subs
      batchSize <- asks $ subsBatchSize . config
      forM_ ss $ \serverSubs -> do
        let srv = server $ L.head serverSubs
            batches = toChunks batchSize $ L.toList serverSubs
        SMPSubscriber {newSubQ = subscriberSubQ} <- getSMPSubscriber srv
        mapM_ (atomically . writeTQueue subscriberSubQ) batches

    server :: NtfEntityRec 'Subscription -> SMPServer
    server (NtfSub sub) = ntfSubServer sub

    getSMPSubscriber :: SMPServer -> M SMPSubscriber
    getSMPSubscriber smpServer =
      atomically (TM.lookup smpServer smpSubscribers) >>= maybe createSMPSubscriber pure
      where
        createSMPSubscriber = do
          sub@SMPSubscriber {subThreadId} <- atomically newSMPSubscriber
          atomically $ TM.insert smpServer sub smpSubscribers
          tId <- mkWeakThreadId =<< forkIO (runSMPSubscriber sub)
          atomically . writeTVar subThreadId $ Just tId
          pure sub

    runSMPSubscriber :: SMPSubscriber -> M ()
    runSMPSubscriber SMPSubscriber {newSubQ = subscriberSubQ} =
      forever $ do
        subs <- atomically (peekTQueue subscriberSubQ)
        let subs' = L.map (\(NtfSub sub) -> sub) subs
            srv = server $ L.head subs
        logSubStatus srv "subscribing" $ length subs
        mapM_ (\NtfSubData {smpQueue} -> updateSubStatus smpQueue NSPending) subs'
        rs <- liftIO $ subscribeQueues srv subs'
        (subs'', oks, errs) <- foldM process ([], 0, []) rs
        atomically $ do
          void $ readTQueue subscriberSubQ
          mapM_ (writeTQueue subscriberSubQ . L.map NtfSub) $ L.nonEmpty subs''
        logSubStatus srv "retrying" $ length subs''
        logSubStatus srv "subscribed" oks
        logSubErrors srv errs
      where
        process :: ([NtfSubData], Int, [NtfSubStatus]) -> (NtfSubData, Either SMPClientError ()) -> M ([NtfSubData], Int, [NtfSubStatus])
        process (subs, oks, errs) (sub@NtfSubData {smpQueue}, r) = case r of
          Right _ -> updateSubStatus smpQueue NSActive $> (subs, oks + 1, errs)
          Left e -> update <$> handleSubError smpQueue e
          where
            update = \case
              Just err -> (subs, oks, err : errs) -- permanent error, log and don't retry subscription
              Nothing -> (sub : subs, oks, errs) -- temporary error, retry subscription

    -- \| Subscribe to queues. The list of results can have a different order.
    subscribeQueues :: SMPServer -> NonEmpty NtfSubData -> IO (NonEmpty (NtfSubData, Either SMPClientError ()))
    subscribeQueues srv subs =
      L.zipWith (\s r -> (s, snd r)) subs <$> subscribeQueuesNtfs ca srv (L.map sub subs)
      where
        sub NtfSubData {smpQueue = SMPQueueNtf {notifierId}, notifierKey} = (notifierId, notifierKey)

    receiveSMP :: M ()
    receiveSMP = forever $ do
      ((_, srv, _), _, _, ntfId, msg) <- atomically $ readTBQueue msgQ
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
              >>= mapM_ (\tkn -> writeTBQueue pushQ (tkn, PNMessage PNMessageData {smpQueue, ntfTs, nmsgNonce, encNMsgMeta}))
          incNtfStat ntfReceived
        SMP.END -> updateSubStatus smpQueue NSEnd
        _ -> pure ()

    receiveAgent =
      forever $
        atomically (readTBQueue agentQ) >>= \case
          CAConnected _ -> pure ()
          CADisconnected srv subs -> do
            logSubStatus srv "disconnected" $ length subs
            forM_ subs $ \(_, ntfId) -> do
              let smpQueue = SMPQueueNtf srv ntfId
              updateSubStatus smpQueue NSInactive
          CAReconnected srv ->
            logInfo $ "SMP server reconnected " <> showServer' srv
          CAResubscribed srv subs -> do
            forM_ subs $ \(_, ntfId) -> updateSubStatus (SMPQueueNtf srv ntfId) NSActive
            logSubStatus srv "resubscribed" $ length subs
          CASubError srv errs ->
            forM errs (\((_, ntfId), err) -> handleSubError (SMPQueueNtf srv ntfId) err)
              >>= logSubErrors srv . catMaybes . L.toList

    logSubStatus srv event n =
      when (n > 0) . logInfo $
        "SMP server " <> event <> " " <> showServer' srv <> " (" <> tshow n <> " subscriptions)"

    logSubErrors :: SMPServer -> [NtfSubStatus] -> M ()
    logSubErrors srv errs = forM_ (L.group $ sort errs) $ \errs' -> do
      logError $ "SMP subscription errors on server " <> showServer' srv <> ": " <> tshow (L.head errs') <> " (" <> tshow (length errs') <> " errors)"

    showServer' = decodeLatin1 . strEncode . host

    handleSubError :: SMPQueueNtf -> SMPClientError -> M (Maybe NtfSubStatus)
    handleSubError smpQueue = \case
      PCEProtocolError AUTH -> updateSubStatus smpQueue NSAuth $> Just NSAuth
      PCEProtocolError e -> updateErr "SMP error " e
      PCEResponseError e -> updateErr "ResponseError " e
      PCEUnexpectedResponse r -> updateErr "UnexpectedResponse " r
      PCETransportError e -> updateErr "TransportError " e
      PCECryptoError e -> updateErr "CryptoError " e
      PCEIncompatibleHost -> let e = NSErr "IncompatibleHost" in updateSubStatus smpQueue e $> Just e
      PCEResponseTimeout -> pure Nothing
      PCENetworkError -> pure Nothing
      PCEIOError _ -> pure Nothing
      where
        updateErr :: Show e => ByteString -> e -> M (Maybe NtfSubStatus)
        updateErr errType e = updateSubStatus smpQueue (NSErr $ errType <> bshow e) $> Just (NSErr errType)

    updateSubStatus smpQueue status = do
      st <- asks store
      atomically (findNtfSubscription st smpQueue) >>= mapM_ update
      where
        update NtfSubData {ntfSubId, subStatus} = do
          old <- atomically $ stateTVar subStatus (,status)
          when (old /= status) $ withNtfLog $ \sl -> logSubscriptionStatus sl ntfSubId status

ntfPush :: NtfPushServer -> M ()
ntfPush s@NtfPushServer {pushQ} = forever $ do
  (tkn@NtfTknData {ntfTknId, token = DeviceToken pp _, tknStatus}, ntf) <- atomically (readTBQueue pushQ)
  liftIO $ logDebug $ "sending push notification to " <> T.pack (show pp)
  status <- readTVarIO tknStatus
  case ntf of
    PNVerification _
      | status /= NTInvalid && status /= NTExpired ->
          deliverNotification pp tkn ntf >>= \case
            Right _ -> do
              status_ <- atomically $ stateTVar tknStatus $ \case
                NTActive -> (Nothing, NTActive)
                NTConfirmed -> (Nothing, NTConfirmed)
                _ -> (Just NTConfirmed, NTConfirmed)
              forM_ status_ $ \status' -> withNtfLog $ \sl -> logTokenStatus sl ntfTknId status'
            _ -> pure ()
      | otherwise -> logError "bad notification token status"
    PNCheckMessages -> checkActiveTkn status $ do
      void $ deliverNotification pp tkn ntf
    PNMessage {} -> checkActiveTkn status $ do
      stats <- asks serverStats
      atomically $ updatePeriodStats (activeTokens stats) ntfTknId
      void $ deliverNotification pp tkn ntf
      incNtfStat ntfDelivered
  where
    checkActiveTkn :: NtfTknStatus -> M () -> M ()
    checkActiveTkn status action
      | status == NTActive = action
      | otherwise = liftIO $ logError "bad notification token status"
    deliverNotification :: PushProvider -> NtfTknData -> PushNotification -> M (Either PushProviderError ())
    deliverNotification pp tkn ntf = do
      deliver <- liftIO $ getPushClient s pp
      liftIO (runExceptT $ deliver tkn ntf) >>= \case
        Right _ -> pure $ Right ()
        Left e -> case e of
          PPConnection _ -> retryDeliver
          PPRetryLater -> retryDeliver
          PPCryptoError _ -> err e
          PPResponseError _ _ -> err e
          PPTokenInvalid -> updateTknStatus tkn NTInvalid >> err e
          PPPermanentError -> err e
      where
        retryDeliver :: M (Either PushProviderError ())
        retryDeliver = do
          deliver <- liftIO $ newPushClient s pp
          liftIO (runExceptT $ deliver tkn ntf) >>= either err (pure . Right)
        err e = logError (T.pack $ "Push provider error (" <> show pp <> "): " <> show e) $> Left e

updateTknStatus :: NtfTknData -> NtfTknStatus -> M ()
updateTknStatus NtfTknData {ntfTknId, tknStatus} status = do
  old <- atomically $ stateTVar tknStatus (,status)
  when (old /= status) $ withNtfLog $ \sl -> logTokenStatus sl ntfTknId status

runNtfClientTransport :: Transport c => THandle c -> M ()
runNtfClientTransport th@THandle {sessionId} = do
  qSize <- asks $ clientQSize . config
  ts <- liftIO getSystemTime
  c <- atomically $ newNtfServerClient qSize sessionId ts
  s <- asks subscriber
  ps <- asks pushServer
  expCfg <- asks $ inactiveClientExpiration . config
  raceAny_ ([liftIO $ send th c, client c s ps, receive th c] <> disconnectThread_ c expCfg)
    `finally` liftIO (clientDisconnected c)
  where
    disconnectThread_ c (Just expCfg) = [liftIO $ disconnectTransport th c activeAt expCfg]
    disconnectThread_ _ _ = []

clientDisconnected :: NtfServerClient -> IO ()
clientDisconnected NtfServerClient {connected} = atomically $ writeTVar connected False

receive :: Transport c => THandle c -> NtfServerClient -> M ()
receive th NtfServerClient {rcvQ, sndQ, activeAt} = forever $ do
  ts <- liftIO $ tGet th
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

send :: Transport c => THandle c -> NtfServerClient -> IO ()
send h@THandle {thVersion = v} NtfServerClient {sndQ, sessionId, activeAt} = forever $ do
  t <- atomically $ readTBQueue sndQ
  void . liftIO $ tPut h Nothing [(Nothing, encodeTransmission v sessionId t)]
  atomically . writeTVar activeAt =<< liftIO getSystemTime

-- instance Show a => Show (TVar a) where
--   show x = unsafePerformIO $ show <$> readTVarIO x

data VerificationResult = VRVerified NtfRequest | VRFailed

verifyNtfTransmission :: SignedTransmission ErrorType NtfCmd -> NtfCmd -> M VerificationResult
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
          t_ <- atomically $ getActiveNtfToken st tknId
          verifyToken' t_ $ VRVerified (NtfReqNew corrId (ANE SSubscription sub))
        Just s@NtfSubData {tokenId = subTknId} ->
          if subTknId == tknId
            then do
              t_ <- atomically $ getActiveNtfToken st subTknId
              verifyToken' t_ $ verifiedSubCmd s c
            else pure $ maybe False (dummyVerifyCmd signed) sig_ `seq` VRFailed
    NtfCmd SSubscription PING -> pure $ VRVerified $ NtfReqPing corrId entId
    NtfCmd SSubscription c -> do
      s_ <- atomically $ getNtfSubscription st entId
      case s_ of
        Just s@NtfSubData {tokenId = subTknId} -> do
          t_ <- atomically $ getActiveNtfToken st subTknId
          verifyToken' t_ $ verifiedSubCmd s c
        _ -> pure $ maybe False (dummyVerifyCmd signed) sig_ `seq` VRFailed
  where
    verifiedTknCmd t c = VRVerified (NtfReqCmd SToken (NtfTkn t) (corrId, entId, c))
    verifiedSubCmd s c = VRVerified (NtfReqCmd SSubscription (NtfSub s) (corrId, entId, c))
    verifyToken :: Maybe NtfTknData -> (NtfTknData -> VerificationResult) -> M VerificationResult
    verifyToken t_ positiveVerificationResult =
      pure $ case t_ of
        Just t@NtfTknData {tknVerifyKey} ->
          if verifyCmdSignature sig_ signed tknVerifyKey
            then positiveVerificationResult t
            else VRFailed
        _ -> maybe False (dummyVerifyCmd signed) sig_ `seq` VRFailed
    verifyToken' :: Maybe NtfTknData -> VerificationResult -> M VerificationResult
    verifyToken' t_ = verifyToken t_ . const

client :: NtfServerClient -> NtfSubscriber -> NtfPushServer -> M ()
client NtfServerClient {rcvQ, sndQ} NtfSubscriber {newSubQ, smpAgent = ca} NtfPushServer {pushQ, intervalNotifiers} =
  forever $
    atomically (readTBQueue rcvQ)
      >>= processCommand
      >>= atomically . writeTBQueue sndQ
  where
    processCommand :: NtfRequest -> M (Transmission NtfResponse)
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
                updateTknStatus tkn NTActive
                tIds <- atomically $ removeInactiveTokenRegistrations st tkn
                forM_ tIds cancelInvervalNotifications
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
                    liftIO $ threadDelay' delay
                    atomically $ writeTBQueue pushQ (tkn, PNCheckMessages)
      NtfReqNew corrId (ANE SSubscription newSub) -> do
        logDebug "SNEW - new subscription"
        st <- asks store
        subId <- getId
        sub <- atomically $ mkNtfSubData subId newSub
        resp <-
          atomically (addNtfSubscription st subId sub) >>= \case
            Just _ -> atomically (writeTBQueue newSubQ [NtfSub sub]) $> NRSubId subId
            _ -> pure $ NRErr AUTH
        withNtfLog (`logCreateSubscription` sub)
        incNtfStat subCreated
        pure (corrId, "", resp)
      NtfReqCmd SSubscription (NtfSub NtfSubData {smpQueue = SMPQueueNtf {smpServer, notifierId}, notifierKey = registeredNKey, subStatus}) (corrId, subId, cmd) -> do
        status <- readTVarIO subStatus
        (corrId,subId,) <$> case cmd of
          SNEW (NewNtfSub _ _ notifierKey) -> do
            logDebug "SNEW - existing subscription"
            -- possible improvement: retry if subscription failed, if pending or AUTH do nothing
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
      NtfReqPing corrId entId -> pure (corrId, entId, NRPong)
    getId :: M NtfEntityId
    getId = getRandomBytes =<< asks (subIdBytes . config)
    getRegCode :: M NtfRegCode
    getRegCode = NtfRegCode <$> (getRandomBytes =<< asks (regCodeBytes . config))
    getRandomBytes :: Int -> M ByteString
    getRandomBytes n = do
      gVar <- asks idsDrg
      atomically (C.pseudoRandomBytes n gVar)
    cancelInvervalNotifications :: NtfTokenId -> M ()
    cancelInvervalNotifications tknId =
      atomically (TM.lookupDelete tknId intervalNotifiers)
        >>= mapM_ (uninterruptibleCancel . action)

withNtfLog :: (StoreLog 'WriteMode -> IO a) -> M ()
withNtfLog action = liftIO . mapM_ action =<< asks storeLog

incNtfStat :: (NtfServerStats -> TVar Int) -> M ()
incNtfStat statSel = do
  stats <- asks serverStats
  atomically $ modifyTVar' (statSel stats) (+ 1)

saveServerStats :: M ()
saveServerStats =
  asks (serverStatsBackupFile . config)
    >>= mapM_ (\f -> asks serverStats >>= atomically . getNtfServerStatsData >>= liftIO . saveStats f)
  where
    saveStats f stats = do
      logInfo $ "saving server stats to file " <> T.pack f
      B.writeFile f $ strEncode stats
      logInfo "server stats saved"

restoreServerStats :: M ()
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
