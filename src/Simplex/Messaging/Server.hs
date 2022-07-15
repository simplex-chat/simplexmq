{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
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
import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Either (fromRight)
import Data.Functor (($>))
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import Data.Maybe (isNothing)
import Data.Set (Set)
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Data.Time.Calendar.Month.Compat (pattern MonthDay)
import Data.Time.Calendar.OrdinalDate (mondayStartWeek)
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.Type.Equality
import GHC.TypeLits (KnownNat)
import Network.Socket (ServiceName)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding (Encoding (smpEncode))
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Server.MsgStore
import Simplex.Messaging.Server.MsgStore.STM (MsgQueue)
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.STM (QueueStore)
import Simplex.Messaging.Server.Stats
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Server
import Simplex.Messaging.Util
import System.Exit (exitFailure)
import System.IO (hPutStrLn)
import System.Mem.Weak (deRefWeak)
import UnliftIO.Concurrent
import UnliftIO.Directory (doesFileExist, renameFile)
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
  restoreServerStats
  restoreServerMessages
  raceAny_
    ( serverThread s subscribedQ subscribers subscriptions cancelSub :
      serverThread s ntfSubscribedQ notifiers ntfSubscriptions (\_ -> pure ()) :
      map runServer transports <> expireMessagesThread_ cfg <> serverStatsThread_ cfg
    )
    `finally` (withLog closeStoreLog >> saveServerMessages >> saveServerStats)
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
    expireMessagesThread_ ServerConfig {messageExpiration = Just msgExp} = [expireMessages msgExp]
    expireMessagesThread_ _ = []

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
    serverStatsThread_ ServerConfig {logStatsInterval = Just interval, logStatsStartTime, serverStatsLogFile} =
      [logServerStats logStatsStartTime interval serverStatsLogFile]
    serverStatsThread_ _ = []

    logServerStats :: Int -> Int -> FilePath -> m ()
    logServerStats startAt logInterval statsFilePath = do
      initialDelay <- (startAt -) . fromIntegral . (`div` 1000000_000000) . diffTimeToPicoseconds . utctDayTime <$> liftIO getCurrentTime
      liftIO $ putStrLn $ "server stats log enabled: " <> statsFilePath
      threadDelay $ 1000000 * (initialDelay + if initialDelay < 0 then 86400 else 0)
      ServerStats {fromTime, qCreated, qSecured, qDeleted, msgSent, msgRecv, dayMsgQueues, weekMsgQueues, monthMsgQueues} <- asks serverStats
      hasFile <- doesFileExist statsFilePath
      let interval = 1000000 * logInterval
          ioMode = if hasFile then AppendMode else WriteMode
      withFile statsFilePath ioMode $ \h -> liftIO . forever $ do
        ts <- getCurrentTime
        fromTime' <- atomically $ swapTVar fromTime ts
        qCreated' <- atomically $ swapTVar qCreated 0
        qSecured' <- atomically $ swapTVar qSecured 0
        qDeleted' <- atomically $ swapTVar qDeleted 0
        msgSent' <- atomically $ swapTVar msgSent 0
        msgRecv' <- atomically $ swapTVar msgRecv 0
        let day = utctDay ts
            (_, wDay) = mondayStartWeek day
            MonthDay _ mDay = day
        (dayMsgQueues', weekMsgQueues', monthMsgQueues') <-
          atomically $ (,,) <$> periodCount 1 dayMsgQueues <*> periodCount wDay weekMsgQueues <*> periodCount mDay monthMsgQueues
        hPutStrLn h $ intercalate "," [iso8601Show $ utctDay fromTime', show qCreated', show qSecured', show qDeleted', show msgSent', show msgRecv', dayMsgQueues', weekMsgQueues', monthMsgQueues']
        threadDelay interval
      where
        periodCount :: Int -> TVar (Set RecipientId) -> STM String
        periodCount 1 pVar = show . S.size <$> swapTVar pVar S.empty
        periodCount _ _ = pure ""

    runClient :: Transport c => TProxy c -> c -> m ()
    runClient _ h = do
      kh <- asks serverIdentity
      smpVRange <- asks $ smpServerVRange . config
      liftIO (runExceptT $ smpServerHandshake h kh smpVRange) >>= \case
        Right th -> runClientTransport th
        Left _ -> pure ()

runClientTransport :: (Transport c, MonadUnliftIO m, MonadReader Env m) => THandle c -> m ()
runClientTransport th@THandle {thVersion, sessionId} = do
  q <- asks $ tbqSize . config
  ts <- liftIO getSystemTime
  c <- atomically $ newClient q thVersion sessionId ts
  s <- asks server
  expCfg <- asks $ inactiveClientExpiration . config
  raceAny_ ([send th c, client c s, receive th c] <> disconnectThread_ c expCfg)
    `finally` clientDisconnected c
  where
    disconnectThread_ c (Just expCfg) = [disconnectTransport th c activeAt expCfg]
    disconnectThread_ _ _ = []

clientDisconnected :: (MonadUnliftIO m, MonadReader Env m) => Client -> m ()
clientDisconnected c@Client {subscriptions, connected} = do
  atomically $ writeTVar connected False
  subs <- readTVarIO subscriptions
  mapM_ cancelSub subs
  atomically $ writeTVar subscriptions M.empty
  cs <- asks $ subscribers . server
  atomically . mapM_ (\rId -> TM.update deleteCurrentClient rId cs) $ M.keys subs
  where
    deleteCurrentClient :: Client -> Maybe Client
    deleteCurrentClient c'
      | sameClientSession c c' = Nothing
      | otherwise = Just c'

sameClientSession :: Client -> Client -> Bool
sameClientSession Client {sessionId} Client {sessionId = s'} = sessionId == s'

cancelSub :: MonadUnliftIO m => TVar Sub -> m ()
cancelSub sub =
  readTVarIO sub >>= \case
    Sub {subThread = SubThread t} -> liftIO $ deRefWeak t >>= mapM_ killThread
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
send h@THandle {thVersion = v} Client {sndQ, sessionId, activeAt} = forever $ do
  t <- atomically $ readTBQueue sndQ
  -- TODO the line below can return Left, but we ignore it and do not disconnect the client
  void . liftIO $ tPut h (Nothing, encodeTransmission v sessionId t)
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
    Cmd SSender SEND {} -> verifyCmd SSender $ verifyMaybe . senderKey
    Cmd SSender PING -> pure True
    Cmd SNotifier NSUB -> verifyCmd SNotifier $ verifyMaybe . fmap notifierKey . notifier
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
client clnt@Client {thVersion, subscriptions, ntfSubscriptions, rcvQ, sndQ} Server {subscribedQ, ntfSubscribedQ, notifiers} =
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
            SEND flags msgBody -> sendMessage st flags msgBody
            PING -> pure (corrId, "", PONG)
        Cmd SNotifier NSUB -> subscribeNotifications
        Cmd SRecipient command ->
          case command of
            NEW rKey dhKey ->
              ifM
                (asks $ allowNewQueues . config)
                (createQueue st rKey dhKey)
                (pure (corrId, queueId, ERR AUTH))
            SUB -> subscribeQueue st queueId
            GET -> getMessage st
            ACK msgId -> acknowledgeMsg st msgId
            KEY sKey -> secureQueue_ st sKey
            NKEY nKey dhKey -> addQueueNotifier_ st nKey dhKey
            NDEL -> deleteQueueNotifier_ st
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
                  subscribeQueue st rId $> IDS (qik ids)

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

        addQueueNotifier_ :: QueueStore -> NtfPublicVerifyKey -> RcvNtfPublicDhKey -> m (Transmission BrokerMsg)
        addQueueNotifier_ st notifierKey dhKey = do
          (rcvPublicDhKey, privDhKey) <- liftIO C.generateKeyPair'
          let rcvNtfDhSecret = C.dh' dhKey privDhKey
          (corrId,queueId,) <$> addNotifierRetry 3 rcvPublicDhKey rcvNtfDhSecret
          where
            addNotifierRetry :: Int -> RcvNtfPublicDhKey -> RcvNtfDhSecret -> m BrokerMsg
            addNotifierRetry 0 _ _ = pure $ ERR INTERNAL
            addNotifierRetry n rcvPublicDhKey rcvNtfDhSecret = do
              notifierId <- randomId =<< asks (queueIdBytes . config)
              let ntfCreds = NtfCreds {notifierId, notifierKey, rcvNtfDhSecret}
              atomically (addQueueNotifier st queueId ntfCreds) >>= \case
                Left DUPLICATE_ -> addNotifierRetry (n - 1) rcvPublicDhKey rcvNtfDhSecret
                Left e -> pure $ ERR e
                Right _ -> do
                  withLog $ \s -> logAddNotifier s queueId ntfCreds
                  pure $ NID notifierId rcvPublicDhKey

        deleteQueueNotifier_ :: QueueStore -> m (Transmission BrokerMsg)
        deleteQueueNotifier_ st = do
          withLog (`logDeleteNotifier` queueId)
          okResp <$> atomically (deleteQueueNotifier st queueId)

        suspendQueue_ :: QueueStore -> m (Transmission BrokerMsg)
        suspendQueue_ st = do
          withLog (`logDeleteQueue` queueId)
          okResp <$> atomically (suspendQueue st queueId)

        subscribeQueue :: QueueStore -> RecipientId -> m (Transmission BrokerMsg)
        subscribeQueue st rId =
          atomically (TM.lookup rId subscriptions) >>= \case
            Nothing ->
              atomically newSub >>= deliver
            Just sub ->
              readTVarIO sub >>= \case
                Sub {subThread = ProhibitSub} ->
                  -- cannot use SUB in the same connection where GET was used
                  pure (corrId, rId, ERR $ CMD PROHIBITED)
                s ->
                  atomically (tryTakeTMVar $ delivered s) >> deliver sub
          where
            newSub :: STM (TVar Sub)
            newSub = do
              writeTBQueue subscribedQ (rId, clnt)
              sub <- newTVar =<< newSubscription NoSub
              TM.insert rId sub subscriptions
              pure sub
            deliver :: TVar Sub -> m (Transmission BrokerMsg)
            deliver sub = do
              q <- getStoreMsgQueue rId
              msg_ <- atomically $ tryPeekMsg q
              deliverMessage st rId sub q msg_

        getMessage :: QueueStore -> m (Transmission BrokerMsg)
        getMessage st =
          atomically (TM.lookup queueId subscriptions) >>= \case
            Nothing ->
              atomically newSub >>= getMessage_
            Just sub ->
              readTVarIO sub >>= \case
                s@Sub {subThread = ProhibitSub} ->
                  atomically (tryTakeTMVar $ delivered s)
                    >> getMessage_ s
                -- cannot use GET in the same connection where there is an active subscription
                _ -> pure (corrId, queueId, ERR $ CMD PROHIBITED)
          where
            newSub :: STM Sub
            newSub = do
              s <- newSubscription ProhibitSub
              sub <- newTVar s
              TM.insert queueId sub subscriptions
              pure s
            getMessage_ :: Sub -> m (Transmission BrokerMsg)
            getMessage_ s = withRcvQueue st queueId $ \qr -> do
              q <- getStoreMsgQueue queueId
              atomically $
                tryPeekMsg q >>= \case
                  Just msg ->
                    let encMsg = encryptMsg qr msg
                     in setDelivered s msg $> (corrId, queueId, MSG encMsg)
                  _ -> pure (corrId, queueId, OK)

        withRcvQueue :: QueueStore -> RecipientId -> (QueueRec -> m (Transmission BrokerMsg)) -> m (Transmission BrokerMsg)
        withRcvQueue st rId action =
          atomically (getQueue st SRecipient rId) >>= \case
            Left e -> pure (corrId, rId, ERR e)
            Right qr -> action qr

        subscribeNotifications :: m (Transmission BrokerMsg)
        subscribeNotifications = atomically $ do
          unlessM (TM.member queueId ntfSubscriptions) $ do
            writeTBQueue ntfSubscribedQ (queueId, clnt)
            TM.insert queueId () ntfSubscriptions
          pure ok

        acknowledgeMsg :: QueueStore -> MsgId -> m (Transmission BrokerMsg)
        acknowledgeMsg st msgId = do
          atomically (TM.lookup queueId subscriptions) >>= \case
            Nothing -> pure $ err NO_MSG
            Just sub ->
              atomically (getDelivered sub) >>= \case
                Just s -> do
                  q <- getStoreMsgQueue queueId
                  case s of
                    Sub {subThread = ProhibitSub} -> do
                      msgDeleted <- atomically $ tryDelMsg q msgId
                      when msgDeleted updateStats
                      pure ok
                    _ -> do
                      (msgDeleted, msg_) <- atomically $ tryDelPeekMsg q msgId
                      when msgDeleted updateStats
                      deliverMessage st queueId sub q msg_
                _ -> pure $ err NO_MSG
          where
            getDelivered :: TVar Sub -> STM (Maybe Sub)
            getDelivered sub = do
              s@Sub {delivered} <- readTVar sub
              tryTakeTMVar delivered $>>= \msgId' ->
                if msgId == msgId' || B.null msgId
                  then pure $ Just s
                  else putTMVar delivered msgId' $> Nothing
            updateStats :: m ()
            updateStats = do
              stats <- asks serverStats
              atomically $ modifyTVar (msgRecv stats) (+ 1)
              atomically $ updateActiveQueues stats queueId

        updateActiveQueues :: ServerStats -> RecipientId -> STM ()
        updateActiveQueues stats qId = do
          updatePeriod dayMsgQueues
          updatePeriod weekMsgQueues
          updatePeriod monthMsgQueues
          where
            updatePeriod pSel = modifyTVar (pSel stats) (S.insert qId)

        sendMessage :: QueueStore -> MsgFlags -> MsgBody -> m (Transmission BrokerMsg)
        sendMessage st msgFlags msgBody
          | B.length msgBody > maxMessageLength = pure $ err LARGE_MSG
          | otherwise = do
            qr <- atomically $ getQueue st SSender queueId
            either (return . err) storeMessage qr
          where
            storeMessage :: QueueRec -> m (Transmission BrokerMsg)
            storeMessage qr = case status qr of
              QueueOff -> return $ err AUTH
              QueueActive ->
                mapM mkMessage (C.maxLenBS msgBody) >>= \case
                  Left _ -> pure $ err LARGE_MSG
                  Right msg -> do
                    ms <- asks msgStore
                    ServerConfig {messageExpiration, msgQueueQuota} <- asks config
                    old <- liftIO $ mapM expireBeforeEpoch messageExpiration
                    ntfNonceDrg <- asks idsDrg
                    resp@(_, _, sent) <- atomically $ do
                      q <- getMsgQueue ms (recipientId qr) msgQueueQuota
                      mapM_ (deleteExpiredMsgs q) old
                      ifM (isFull q) (pure $ err QUOTA) $ do
                        when (notification msgFlags) $ trySendNotification msg ntfNonceDrg
                        writeMsg q msg
                        pure ok
                    when (sent == OK) $ do
                      stats <- asks serverStats
                      atomically $ modifyTVar (msgSent stats) (+ 1)
                      atomically $ updateActiveQueues stats $ recipientId qr
                    pure resp
              where
                mkMessage :: C.MaxLenBS MaxMessageLen -> m Message
                mkMessage body = do
                  msgId <- randomId =<< asks (msgIdBytes . config)
                  msgTs <- liftIO getSystemTime
                  pure $ Message msgId msgTs msgFlags body

                trySendNotification :: Message -> TVar ChaChaDRG -> STM ()
                trySendNotification msg ntfNonceDrg =
                  forM_ (notifier qr) $ \NtfCreds {notifierId, rcvNtfDhSecret} ->
                    mapM_ (writeNtf notifierId msg rcvNtfDhSecret ntfNonceDrg) =<< TM.lookup notifierId notifiers

                writeNtf :: NotifierId -> Message -> RcvNtfDhSecret -> TVar ChaChaDRG -> Client -> STM ()
                writeNtf nId msg rcvNtfDhSecret ntfNonceDrg Client {sndQ = q} =
                  unlessM (isFullTBQueue sndQ) $ do
                    (nmsgNonce, encNMsgMeta) <- mkMessageNotification msg rcvNtfDhSecret ntfNonceDrg
                    writeTBQueue q (CorrId "", nId, NMSG nmsgNonce encNMsgMeta)

                mkMessageNotification :: Message -> RcvNtfDhSecret -> TVar ChaChaDRG -> STM (C.CbNonce, EncNMsgMeta)
                mkMessageNotification Message {msgId, msgTs} rcvNtfDhSecret ntfNonceDrg = do
                  cbNonce <- C.pseudoRandomCbNonce ntfNonceDrg
                  let msgMeta = NMsgMeta {msgId, msgTs}
                      encNMsgMeta = C.cbEncrypt rcvNtfDhSecret cbNonce (smpEncode msgMeta) 128
                  pure . (cbNonce,) $ fromRight "" encNMsgMeta

        deliverMessage :: QueueStore -> RecipientId -> TVar Sub -> MsgQueue -> Maybe Message -> m (Transmission BrokerMsg)
        deliverMessage st rId sub q msg_ = withRcvQueue st rId $ \qr -> do
          readTVarIO sub >>= \case
            s@Sub {subThread = NoSub} ->
              case msg_ of
                Just msg ->
                  let encMsg = encryptMsg qr msg
                   in atomically (setDelivered s msg) $> (corrId, rId, MSG encMsg)
                _ -> forkSub qr $> ok
            _ -> pure ok
          where
            forkSub :: QueueRec -> m ()
            forkSub qr = do
              atomically . modifyTVar sub $ \s -> s {subThread = SubPending}
              t <- mkWeakThreadId =<< forkIO subscriber
              atomically . modifyTVar sub $ \case
                s@Sub {subThread = SubPending} -> s {subThread = SubThread t}
                s -> s
              where
                subscriber = atomically $ do
                  msg <- peekMsg q
                  let encMsg = encryptMsg qr msg
                  writeTBQueue sndQ (CorrId "", rId, MSG encMsg)
                  s <- readTVar sub
                  void $ setDelivered s msg
                  writeTVar sub s {subThread = NoSub}

        encryptMsg :: QueueRec -> Message -> RcvMessage
        encryptMsg qr Message {msgId, msgTs, msgFlags, msgBody}
          | thVersion == 1 || thVersion == 2 = encrypt msgBody
          | otherwise = encrypt $ encodeRcvMsgBody RcvMsgBody {msgTs, msgFlags, msgBody}
          where
            encrypt :: KnownNat i => C.MaxLenBS i -> RcvMessage
            encrypt body =
              let encBody = EncRcvMsgBody $ C.cbEncryptMaxLenBS (rcvDhSecret qr) (C.cbNonce msgId) body
               in RcvMessage msgId msgTs msgFlags encBody

        setDelivered :: Sub -> Message -> STM Bool
        setDelivered s Message {msgId} = tryPutTMVar (delivered s) msgId

        getStoreMsgQueue :: RecipientId -> m MsgQueue
        getStoreMsgQueue rId = do
          ms <- asks msgStore
          quota <- asks $ msgQueueQuota . config
          atomically $ getMsgQueue ms rId quota

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

saveServerMessages :: (MonadUnliftIO m, MonadReader Env m) => m ()
saveServerMessages = asks (storeMsgsFile . config) >>= mapM_ saveMessages
  where
    saveMessages f = do
      logInfo $ "saving messages to file " <> T.pack f
      ms <- asks msgStore
      liftIO . withFile f WriteMode $ \h ->
        readTVarIO ms >>= mapM_ (saveQueueMsgs ms h) . M.keys
      logInfo "messages saved"
      where
        saveQueueMsgs ms h rId =
          atomically (flushMsgQueue ms rId)
            >>= mapM_ (B.hPutStrLn h . strEncode . MLRv3 rId)

restoreServerMessages :: forall m. (MonadUnliftIO m, MonadReader Env m) => m ()
restoreServerMessages = asks (storeMsgsFile . config) >>= mapM_ restoreMessages
  where
    restoreMessages f = whenM (doesFileExist f) $ do
      logInfo $ "restoring messages from file " <> T.pack f
      st <- asks queueStore
      ms <- asks msgStore
      quota <- asks $ msgQueueQuota . config
      runExceptT (liftIO (B.readFile f) >>= mapM_ (restoreMsg st ms quota) . B.lines) >>= \case
        Left e -> do
          logError . T.pack $ "error restoring messages: " <> e
          liftIO exitFailure
        _ -> do
          renameFile f $ f <> ".bak"
          logInfo "messages restored"
      where
        restoreMsg st ms quota s = do
          r <- liftEither . first (msgErr "parsing") $ strDecode s
          case r of
            MLRv3 rId msg -> addToMsgQueue rId msg
            MLRv1 rId encMsg -> do
              qr <- liftEitherError (msgErr "queue unknown") . atomically $ getQueue st SRecipient rId
              msg' <- updateMsgV1toV3 qr encMsg
              addToMsgQueue rId msg'
          where
            addToMsgQueue rId msg = do
              full <- atomically $ do
                q <- getMsgQueue ms rId quota
                ifM (isFull q) (pure True) (writeMsg q msg $> False)
              when full . logError . decodeLatin1 $ "message queue " <> strEncode rId <> " is full, message not restored: " <> strEncode (msgId (msg :: Message))
            updateMsgV1toV3 QueueRec {rcvDhSecret} RcvMessage {msgId, msgTs, msgFlags, msgBody = EncRcvMsgBody body} = do
              let nonce = C.cbNonce msgId
              msgBody <- liftEither . first (msgErr "v1 message decryption") $ C.maxLenBS =<< C.cbDecrypt rcvDhSecret nonce body
              pure Message {msgId, msgTs, msgFlags, msgBody}
            msgErr :: Show e => String -> e -> String
            msgErr op e = op <> " error (" <> show e <> "): " <> B.unpack (B.take 100 s)

saveServerStats :: (MonadUnliftIO m, MonadReader Env m) => m ()
saveServerStats =
  asks (serverStatsBackupFile . config)
    >>= mapM_ (\f -> asks serverStats >>= atomically . getServerStatsData >>= liftIO . saveStats f)
  where
    saveStats f stats = do
      logInfo $ "saving server stats to file " <> T.pack f
      B.writeFile f $ strEncode stats
      logInfo "server stats saved"

restoreServerStats :: (MonadUnliftIO m, MonadReader Env m) => m ()
restoreServerStats = asks (serverStatsBackupFile . config) >>= mapM_ restoreStats
  where
    restoreStats f = whenM (doesFileExist f) $ do
      logInfo $ "restoring server stats from file " <> T.pack f
      liftIO (strDecode <$> B.readFile f) >>= \case
        Right d -> do
          s <- asks serverStats
          atomically $ setServerStatsData s d
          renameFile f $ f <> ".bak"
          logInfo "server stats restored"
        Left e -> logInfo $ "error restoring server stats: " <> T.pack e
