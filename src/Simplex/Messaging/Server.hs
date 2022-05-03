{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

-- |
-- Module      : Simplex.Messaging.Server
-- Copyright   : (c) simplex.chat
-- License     : AGPL-3
--
-- Maintainer  : chat@simplex.chat
-- Stability   : experimental
-- Portability : non-portable
--
-- This module defines SMP protocol server with in-memory persistence
-- and optional append only log of SMP queue records.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md
module Simplex.Messaging.Server
  ( runSMPServer,
    runSMPServerBlocking,
    disconnectTransport,
    verifyCmdSignature,
    dummyVerifyCmd,
  )
where

import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import Data.Maybe (isNothing)
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Data.Type.Equality
import Network.Socket (ServiceName)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Server.MsgStore
import Simplex.Messaging.Server.MsgStore.STM (MsgQueue)
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.STM (QueueStore)
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Server
import Simplex.Messaging.Util
import UnliftIO.Concurrent
import UnliftIO.Exception
import UnliftIO.IO
import UnliftIO.STM

-- | Runs an SMP server using passed configuration.
--
-- See a full server here: https://github.com/simplex-chat/simplexmq/blob/master/apps/smp-server/Main.hs
runSMPServer :: (MonadRandom m, MonadUnliftIO m) => ServerConfig -> m ()
runSMPServer cfg = do
  started <- newEmptyTMVarIO
  runSMPServerBlocking started cfg

-- | Runs an SMP server using passed configuration with signalling.
--
-- This function uses passed TMVar to signal when the server is ready to accept TCP requests (True)
-- and when it is disconnected from the TCP socket once the server thread is killed (False).
runSMPServerBlocking :: (MonadRandom m, MonadUnliftIO m) => TMVar Bool -> ServerConfig -> m ()
runSMPServerBlocking started cfg = newEnv cfg >>= runReaderT (smpServer started)

smpServer :: forall m. (MonadUnliftIO m, MonadReader Env m) => TMVar Bool -> m ()
smpServer started = do
  s <- asks server
  cfg@ServerConfig {transports} <- asks config
  raceAny_
    ( serverThread s subscribedQ subscribers subscriptions cancelSub :
      serverThread s ntfSubscribedQ notifiers ntfSubscriptions (\_ -> pure ()) :
      map runServer transports <> expireMessagesThread_ cfg <> serverStatsThread_ cfg
    )
    `finally` withLog closeStoreLog
  where
    runServer :: (ServiceName, ATransport) -> m ()
    runServer (tcpPort, ATransport t) = do
      serverParams <- asks tlsServerParams
      runTransportServer started tcpPort serverParams (runClient t)

    serverThread ::
      forall s.
      Server ->
      (Server -> TBQueue (QueueId, Client)) ->
      (Server -> TMap QueueId Client) ->
      (Client -> TMap QueueId s) ->
      (s -> m ()) ->
      m ()
    serverThread s subQ subs clientSubs unsub = forever $ do
      atomically updateSubscribers
        $>>= endPreviousSubscriptions
        >>= mapM_ unsub
      where
        updateSubscribers :: STM (Maybe (QueueId, Client))
        updateSubscribers = do
          (qId, clnt) <- readTBQueue $ subQ s
          let clientToBeNotified = \c' ->
                if sameClientSession clnt c'
                  then pure Nothing
                  else do
                    yes <- readTVar $ connected c'
                    pure $ if yes then Just (qId, c') else Nothing
          TM.lookupInsert qId clnt (subs s) $>>= clientToBeNotified
        endPreviousSubscriptions :: (QueueId, Client) -> m (Maybe s)
        endPreviousSubscriptions (qId, c) = do
          void . forkIO . atomically $
            writeTBQueue (sndQ c) (CorrId "", qId, END)
          atomically $ TM.lookupDelete qId (clientSubs c)

    expireMessagesThread_ :: ServerConfig -> [m ()]
    expireMessagesThread_ = maybe [] ((: []) . expireMessages) . messageExpiration

    expireMessages :: ExpirationConfig -> m ()
    expireMessages expCfg = do
      ms <- asks msgStore
      quota <- asks $ msgQueueQuota . config
      let interval = checkInterval expCfg * 1000000
      forever $ do
        threadDelay interval
        old <- liftIO $ expireBeforeEpoch expCfg
        rIds <- M.keysSet <$> readTVarIO ms
        forM_ rIds $ \rId ->
          atomically (getMsgQueue ms rId quota)
            >>= atomically . (`deleteExpiredMsgs` old)

    serverStatsThread_ :: ServerConfig -> [m ()]
    serverStatsThread_ ServerConfig {logStatsInterval, logStatsStartTime} =
      maybe [] ((: []) . logServerStats logStatsStartTime) logStatsInterval

    logServerStats :: Int -> Int -> m ()
    logServerStats startAt logInterval = do
      initialDelay <- (startAt -) . fromIntegral . (`div` 1000000_000000) . diffTimeToPicoseconds . utctDayTime <$> liftIO getCurrentTime
      logInfo $ "fromTime,qCreated,qSecured,qDeleted,msgSent,msgRecv,msgQueues"
      threadDelay $ 1000000 * (initialDelay + if initialDelay < 0 then 86400 else 0)
      ServerStats {fromTime, qCreated, qSecured, qDeleted, msgSent, msgRecv, msgQueues} <- asks serverStats
      let interval = 1000000 * logInterval
      forever $ do
        ts <- liftIO getCurrentTime
        fromTime' <- atomically $ swapTVar fromTime ts
        qCreated' <- atomically $ swapTVar qCreated 0
        qSecured' <- atomically $ swapTVar qSecured 0
        qDeleted' <- atomically $ swapTVar qDeleted 0
        msgSent' <- atomically $ swapTVar msgSent 0
        msgRecv' <- atomically $ swapTVar msgRecv 0
        msgQueues' <- atomically $ S.size <$> swapTVar msgQueues S.empty
        logInfo . T.pack $ intercalate "," [show fromTime', show qCreated', show qSecured', show qDeleted', show msgSent', show msgRecv', show msgQueues']
        threadDelay interval

    runClient :: Transport c => TProxy c -> c -> m ()
    runClient _ h = do
      kh <- asks serverIdentity
      liftIO (runExceptT $ smpServerHandshake h kh) >>= \case
        Right th -> runClientTransport th
        Left _ -> pure ()

runClientTransport :: (Transport c, MonadUnliftIO m, MonadReader Env m) => THandle c -> m ()
runClientTransport th@THandle {sessionId} = do
  q <- asks $ tbqSize . config
  ts <- liftIO getSystemTime
  c <- atomically $ newClient q sessionId ts
  s <- asks server
  expCfg <- asks $ inactiveClientExpiration . config
  raceAny_ ([send th c, client c s, receive th c] <> disconnectThread_ c expCfg)
    `finally` clientDisconnected c
  where
    disconnectThread_ c expCfg = maybe [] ((: []) . disconnectTransport th c activeAt) expCfg

clientDisconnected :: (MonadUnliftIO m, MonadReader Env m) => Client -> m ()
clientDisconnected c@Client {subscriptions, connected} = do
  atomically $ writeTVar connected False
  subs <- readTVarIO subscriptions
  mapM_ cancelSub subs
  cs <- asks $ subscribers . server
  atomically . mapM_ (\rId -> TM.update deleteCurrentClient rId cs) $ M.keys subs
  where
    deleteCurrentClient :: Client -> Maybe Client
    deleteCurrentClient c'
      | sameClientSession c c' = Nothing
      | otherwise = Just c'

sameClientSession :: Client -> Client -> Bool
sameClientSession Client {sessionId} Client {sessionId = s'} = sessionId == s'

cancelSub :: MonadUnliftIO m => Sub -> m ()
cancelSub = \case
  Sub {subThread = SubThread t} -> killThread t
  _ -> return ()

receive :: (Transport c, MonadUnliftIO m, MonadReader Env m) => THandle c -> Client -> m ()
receive th Client {rcvQ, sndQ, activeAt} = forever $ do
  (sig, signed, (corrId, queueId, cmdOrError)) <- tGet th
  atomically . writeTVar activeAt =<< liftIO getSystemTime
  case cmdOrError of
    Left e -> write sndQ (corrId, queueId, ERR e)
    Right cmd -> do
      verified <- verifyTransmission sig signed queueId cmd
      if verified
        then write rcvQ (corrId, queueId, cmd)
        else write sndQ (corrId, queueId, ERR AUTH)
  where
    write q t = atomically $ writeTBQueue q t

send :: (Transport c, MonadUnliftIO m) => THandle c -> Client -> m ()
send h Client {sndQ, sessionId, activeAt} = forever $ do
  t <- atomically $ readTBQueue sndQ
  -- TODO the line below can return Left, but we ignore it and do not disconnect the client
  void . liftIO $ tPut h (Nothing, encodeTransmission sessionId t)
  atomically . writeTVar activeAt =<< liftIO getSystemTime

disconnectTransport :: (Transport c, MonadUnliftIO m) => THandle c -> client -> (client -> TVar SystemTime) -> ExpirationConfig -> m ()
disconnectTransport THandle {connection} c activeAt expCfg = do
  let interval = checkInterval expCfg * 1000000
  forever . liftIO $ do
    threadDelay interval
    old <- expireBeforeEpoch expCfg
    ts <- readTVarIO $ activeAt c
    when (systemSeconds ts < old) $ closeConnection connection

verifyTransmission ::
  forall m. (MonadUnliftIO m, MonadReader Env m) => Maybe C.ASignature -> ByteString -> QueueId -> Cmd -> m Bool
verifyTransmission sig_ signed queueId cmd = do
  case cmd of
    Cmd SRecipient (NEW k _) -> pure $ verifyCmdSignature sig_ signed k
    Cmd SRecipient _ -> verifyCmd SRecipient $ verifyCmdSignature sig_ signed . recipientKey
    Cmd SSender (SEND _) -> verifyCmd SSender $ verifyMaybe . senderKey
    Cmd SSender PING -> pure True
    Cmd SNotifier NSUB -> verifyCmd SNotifier $ verifyMaybe . fmap snd . notifier
  where
    verifyCmd :: SParty p -> (QueueRec -> Bool) -> m Bool
    verifyCmd party f = do
      st <- asks queueStore
      q <- atomically $ getQueue st party queueId
      pure $ either (const $ maybe False (dummyVerifyCmd signed) sig_ `seq` False) f q
    verifyMaybe :: Maybe C.APublicVerifyKey -> Bool
    verifyMaybe = maybe (isNothing sig_) $ verifyCmdSignature sig_ signed

verifyCmdSignature :: Maybe C.ASignature -> ByteString -> C.APublicVerifyKey -> Bool
verifyCmdSignature sig_ signed key = maybe False (verify key) sig_
  where
    verify :: C.APublicVerifyKey -> C.ASignature -> Bool
    verify (C.APublicVerifyKey a k) sig@(C.ASignature a' s) =
      case (testEquality a a', C.signatureSize k == C.signatureSize s) of
        (Just Refl, True) -> C.verify' k s signed
        _ -> dummyVerifyCmd signed sig `seq` False

dummyVerifyCmd :: ByteString -> C.ASignature -> Bool
dummyVerifyCmd signed (C.ASignature _ s) = C.verify' (dummyPublicKey s) s signed

-- These dummy keys are used with `dummyVerify` function to mitigate timing attacks
-- by having the same time of the response whether a queue exists or nor, for all valid key/signature sizes
dummyPublicKey :: C.Signature a -> C.PublicKey a
dummyPublicKey = \case
  C.SignatureEd25519 _ -> dummyKeyEd25519
  C.SignatureEd448 _ -> dummyKeyEd448

dummyKeyEd25519 :: C.PublicKey 'C.Ed25519
dummyKeyEd25519 = "MCowBQYDK2VwAyEA139Oqs4QgpqbAmB0o7rZf6T19ryl7E65k4AYe0kE3Qs="

dummyKeyEd448 :: C.PublicKey 'C.Ed448
dummyKeyEd448 = "MEMwBQYDK2VxAzoA6ibQc9XpkSLtwrf7PLvp81qW/etiumckVFImCMRdftcG/XopbOSaq9qyLhrgJWKOLyNrQPNVvpMA"

client :: forall m. (MonadUnliftIO m, MonadReader Env m) => Client -> Server -> m ()
client clnt@Client {subscriptions, ntfSubscriptions, rcvQ, sndQ} Server {subscribedQ, ntfSubscribedQ, notifiers} =
  forever $
    atomically (readTBQueue rcvQ)
      >>= processCommand
      >>= atomically . writeTBQueue sndQ
  where
    processCommand :: Transmission Cmd -> m (Transmission BrokerMsg)
    processCommand (corrId, queueId, cmd) = do
      st <- asks queueStore
      case cmd of
        Cmd SSender command ->
          case command of
            SEND msgBody -> sendMessage st msgBody
            PING -> pure (corrId, "", PONG)
        Cmd SNotifier NSUB -> subscribeNotifications
        Cmd SRecipient command ->
          case command of
            NEW rKey dhKey ->
              ifM
                (asks $ allowNewQueues . config)
                (createQueue st rKey dhKey)
                (pure (corrId, queueId, ERR AUTH))
            SUB -> subscribeQueue queueId
            ACK -> acknowledgeMsg
            KEY sKey -> secureQueue_ st sKey
            NKEY nKey -> addQueueNotifier_ st nKey
            OFF -> suspendQueue_ st
            DEL -> delQueueAndMsgs st
      where
        createQueue :: QueueStore -> RcvPublicVerifyKey -> RcvPublicDhKey -> m (Transmission BrokerMsg)
        createQueue st recipientKey dhKey = do
          (rcvPublicDhKey, privDhKey) <- liftIO C.generateKeyPair'
          let rcvDhSecret = C.dh' dhKey privDhKey
              qik (rcvId, sndId) = QIK {rcvId, sndId, rcvPublicDhKey}
              qRec (recipientId, senderId) =
                QueueRec
                  { recipientId,
                    senderId,
                    recipientKey,
                    rcvDhSecret,
                    senderKey = Nothing,
                    notifier = Nothing,
                    status = QueueActive
                  }
          (corrId,queueId,) <$> addQueueRetry 3 qik qRec
          where
            addQueueRetry ::
              Int -> ((RecipientId, SenderId) -> QueueIdsKeys) -> ((RecipientId, SenderId) -> QueueRec) -> m BrokerMsg
            addQueueRetry 0 _ _ = pure $ ERR INTERNAL
            addQueueRetry n qik qRec = do
              ids@(rId, _) <- getIds
              -- create QueueRec record with these ids and keys
              atomically (addQueue st $ qRec ids) >>= \case
                Left DUPLICATE_ -> addQueueRetry (n - 1) qik qRec
                Left e -> pure $ ERR e
                Right _ -> do
                  withLog (`logCreateById` rId)
                  stats <- asks serverStats
                  atomically $ modifyTVar (qCreated stats) (+ 1)
                  subscribeQueue rId $> IDS (qik ids)

            logCreateById :: StoreLog 'WriteMode -> RecipientId -> IO ()
            logCreateById s rId =
              atomically (getQueue st SRecipient rId) >>= \case
                Right q -> logCreateQueue s q
                _ -> pure ()

            getIds :: m (RecipientId, SenderId)
            getIds = do
              n <- asks $ queueIdBytes . config
              liftM2 (,) (randomId n) (randomId n)

        secureQueue_ :: QueueStore -> SndPublicVerifyKey -> m (Transmission BrokerMsg)
        secureQueue_ st sKey = do
          withLog $ \s -> logSecureQueue s queueId sKey
          stats <- asks serverStats
          atomically $ modifyTVar (qSecured stats) (+ 1)
          atomically $ (corrId,queueId,) . either ERR (const OK) <$> secureQueue st queueId sKey

        addQueueNotifier_ :: QueueStore -> NtfPublicVerifyKey -> m (Transmission BrokerMsg)
        addQueueNotifier_ st nKey = (corrId,queueId,) <$> addNotifierRetry 3
          where
            addNotifierRetry :: Int -> m BrokerMsg
            addNotifierRetry 0 = pure $ ERR INTERNAL
            addNotifierRetry n = do
              nId <- randomId =<< asks (queueIdBytes . config)
              atomically (addQueueNotifier st queueId nId nKey) >>= \case
                Left DUPLICATE_ -> addNotifierRetry $ n - 1
                Left e -> pure $ ERR e
                Right _ -> do
                  withLog $ \s -> logAddNotifier s queueId nId nKey
                  pure $ NID nId

        suspendQueue_ :: QueueStore -> m (Transmission BrokerMsg)
        suspendQueue_ st = do
          withLog (`logDeleteQueue` queueId)
          okResp <$> atomically (suspendQueue st queueId)

        subscribeQueue :: RecipientId -> m (Transmission BrokerMsg)
        subscribeQueue rId =
          atomically (getSubscription rId) >>= deliverMessage tryPeekMsg rId

        getSubscription :: RecipientId -> STM Sub
        getSubscription rId = do
          TM.lookup rId subscriptions >>= \case
            Just s -> tryTakeTMVar (delivered s) $> s
            Nothing -> do
              writeTBQueue subscribedQ (rId, clnt)
              s <- newSubscription
              TM.insert rId s subscriptions
              return s

        subscribeNotifications :: m (Transmission BrokerMsg)
        subscribeNotifications = atomically $ do
          unlessM (TM.member queueId ntfSubscriptions) $ do
            writeTBQueue ntfSubscribedQ (queueId, clnt)
            TM.insert queueId () ntfSubscriptions
          pure ok

        acknowledgeMsg :: m (Transmission BrokerMsg)
        acknowledgeMsg =
          atomically (withSub queueId $ \s -> const s <$$> tryTakeTMVar (delivered s))
            >>= \case
              Just (Just s) -> do
                stats <- asks serverStats
                atomically $ modifyTVar (msgRecv stats) (+ 1)
                atomically $ modifyTVar (msgQueues stats) (S.insert queueId)
                deliverMessage tryDelPeekMsg queueId s
              _ -> return $ err NO_MSG

        withSub :: RecipientId -> (Sub -> STM a) -> STM (Maybe a)
        withSub rId f = mapM f =<< TM.lookup rId subscriptions

        sendMessage :: QueueStore -> MsgBody -> m (Transmission BrokerMsg)
        sendMessage st msgBody
          | B.length msgBody > maxMessageLength = pure $ err LARGE_MSG
          | otherwise = do
            qr <- atomically $ getQueue st SSender queueId
            either (return . err) storeMessage qr
          where
            storeMessage :: QueueRec -> m (Transmission BrokerMsg)
            storeMessage qr = case status qr of
              QueueOff -> return $ err AUTH
              QueueActive ->
                mkMessage >>= \case
                  Left _ -> pure $ err LARGE_MSG
                  Right msg -> do
                    ms <- asks msgStore
                    ServerConfig {messageExpiration, msgQueueQuota} <- asks config
                    old <- liftIO $ mapM expireBeforeEpoch messageExpiration
                    resp@(_, _, sent) <- atomically $ do
                      q <- getMsgQueue ms (recipientId qr) msgQueueQuota
                      mapM_ (deleteExpiredMsgs q) old
                      ifM (isFull q) (pure $ err QUOTA) $ do
                        trySendNotification
                        writeMsg q msg
                        pure ok
                    when (sent == OK) $ do
                      stats <- asks serverStats
                      atomically $ modifyTVar (msgSent stats) (+ 1)
                      atomically $ modifyTVar (msgQueues stats) (S.insert $ recipientId qr)
                    pure resp
              where
                mkMessage :: m (Either C.CryptoError Message)
                mkMessage = do
                  msgId <- randomId =<< asks (msgIdBytes . config)
                  ts <- liftIO getSystemTime
                  let c = C.cbEncrypt (rcvDhSecret qr) (C.cbNonce msgId) msgBody (maxMessageLength + 2)
                  pure $ Message msgId ts <$> c

                trySendNotification :: STM ()
                trySendNotification =
                  forM_ (notifier qr) $ \(nId, _) ->
                    mapM_ (writeNtf nId) =<< TM.lookup nId notifiers

                writeNtf :: NotifierId -> Client -> STM ()
                writeNtf nId Client {sndQ = q} =
                  unlessM (isFullTBQueue sndQ) $
                    writeTBQueue q (CorrId "", nId, NMSG)

        deliverMessage :: (MsgQueue -> STM (Maybe Message)) -> RecipientId -> Sub -> m (Transmission BrokerMsg)
        deliverMessage tryPeek rId = \case
          Sub {subThread = NoSub} -> do
            ms <- asks msgStore
            quota <- asks $ msgQueueQuota . config
            q <- atomically $ getMsgQueue ms rId quota
            atomically (tryPeek q) >>= \case
              Nothing -> forkSub q $> ok
              Just msg -> atomically setDelivered $> (corrId, rId, msgCmd msg)
          _ -> pure ok
          where
            forkSub :: MsgQueue -> m ()
            forkSub q = do
              atomically . setSub $ \s -> s {subThread = SubPending}
              t <- forkIO $ subscriber q
              atomically . setSub $ \case
                s@Sub {subThread = SubPending} -> s {subThread = SubThread t}
                s -> s

            subscriber :: MsgQueue -> m ()
            subscriber q = atomically $ do
              msg <- peekMsg q
              writeTBQueue sndQ (CorrId "", rId, msgCmd msg)
              setSub (\s -> s {subThread = NoSub})
              void setDelivered

            setSub :: (Sub -> Sub) -> STM ()
            setSub f = TM.adjust f rId subscriptions

            setDelivered :: STM (Maybe Bool)
            setDelivered = withSub rId $ \s -> tryPutTMVar (delivered s) ()

            msgCmd :: Message -> BrokerMsg
            msgCmd Message {msgId, ts, msgBody} = MSG msgId ts msgBody

        delQueueAndMsgs :: QueueStore -> m (Transmission BrokerMsg)
        delQueueAndMsgs st = do
          withLog (`logDeleteQueue` queueId)
          ms <- asks msgStore
          stats <- asks serverStats
          atomically $ modifyTVar (qDeleted stats) (+ 1)
          atomically $
            deleteQueue st queueId >>= \case
              Left e -> pure $ err e
              Right _ -> delMsgQueue ms queueId $> ok

        ok :: Transmission BrokerMsg
        ok = (corrId, queueId, OK)

        err :: ErrorType -> Transmission BrokerMsg
        err e = (corrId, queueId, ERR e)

        okResp :: Either ErrorType () -> Transmission BrokerMsg
        okResp = either err $ const ok

withLog :: (MonadUnliftIO m, MonadReader Env m) => (StoreLog 'WriteMode -> IO a) -> m ()
withLog action = do
  env <- ask
  liftIO . mapM_ action $ storeLog (env :: Env)

randomId :: (MonadUnliftIO m, MonadReader Env m) => Int -> m ByteString
randomId n = do
  gVar <- asks idsDrg
  atomically (C.pseudoRandomBytes n gVar)
