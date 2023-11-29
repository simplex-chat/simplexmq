{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
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
    randomId,
  )
where

import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random
import Data.Bifunctor (first)
import Data.ByteString.Base64 (encode)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Either (fromRight, partitionEithers)
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List (intercalate)
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.Maybe (isNothing)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.Type.Equality
import GHC.Stats (getRTSStats)
import GHC.TypeLits (KnownNat)
import Network.Socket (ServiceName, Socket, socketToHandle)
import Simplex.Messaging.Agent.Lock
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding (Encoding (smpEncode))
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.Control
import Simplex.Messaging.Server.Env.STM as Env
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Server.MsgStore
import Simplex.Messaging.Server.MsgStore.STM
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.STM as QS
import Simplex.Messaging.Server.Stats
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Buffer (trimCR)
import Simplex.Messaging.Transport.Server
import Simplex.Messaging.Util
import System.Exit (exitFailure)
import System.IO (hPutStrLn, hSetNewlineMode, universalNewlineMode)
import System.Mem.Weak (deRefWeak)
import UnliftIO.Concurrent
import UnliftIO.Directory (doesFileExist, renameFile)
import UnliftIO.Exception
import UnliftIO.IO
import UnliftIO.STM
#if MIN_VERSION_base(4,18,0)
import Data.List (sort)
import Data.Maybe (fromMaybe)
import GHC.Conc (listThreads, threadStatus)
import GHC.Conc.Sync (threadLabel)
#endif

-- | Runs an SMP server using passed configuration.
--
-- See a full server here: https://github.com/simplex-chat/simplexmq/blob/master/apps/smp-server/Main.hs
runSMPServer :: ServerConfig -> IO ()
runSMPServer cfg = do
  started <- newEmptyTMVarIO
  runSMPServerBlocking started cfg

-- | Runs an SMP server using passed configuration with signalling.
--
-- This function uses passed TMVar to signal when the server is ready to accept TCP requests (True)
-- and when it is disconnected from the TCP socket once the server thread is killed (False).
runSMPServerBlocking :: TMVar Bool -> ServerConfig -> IO ()
runSMPServerBlocking started cfg = newEnv cfg >>= runReaderT (smpServer started cfg)

type M a = ReaderT Env IO a

smpServer :: TMVar Bool -> ServerConfig -> M ()
smpServer started cfg@ServerConfig {transports, transportConfig = tCfg} = do
  s <- asks server
  restoreServerMessages
  restoreServerStats
  raceAny_
    ( serverThread s "server subscribedQ" subscribedQ subscribers subscriptions cancelSub
        : serverThread s "server ntfSubscribedQ" ntfSubscribedQ Env.notifiers ntfSubscriptions (\_ -> pure ())
        : map runServer transports <> expireMessagesThread_ cfg <> serverStatsThread_ cfg <> controlPortThread_ cfg
    )
    `finally` withLock (savingLock s) "final" (saveServer False)
  where
    runServer :: (ServiceName, ATransport) -> M ()
    runServer (tcpPort, ATransport t) = do
      serverParams <- asks tlsServerParams
      runTransportServer started tcpPort serverParams tCfg (runClient t)

    saveServer :: Bool -> M ()
    saveServer keepMsgs = withLog closeStoreLog >> saveServerMessages keepMsgs >> saveServerStats

    serverThread ::
      forall s.
      Server ->
      String ->
      (Server -> TQueue (QueueId, Client)) ->
      (Server -> TMap QueueId Client) ->
      (Client -> TMap QueueId s) ->
      (s -> IO ()) ->
      M ()
    serverThread s label subQ subs clientSubs unsub = forever $ do
      labelMyThread label
      atomically updateSubscribers
        $>>= endPreviousSubscriptions
        >>= liftIO . mapM_ unsub
      where
        updateSubscribers :: STM (Maybe (QueueId, Client))
        updateSubscribers = do
          (qId, clnt) <- readTQueue $ subQ s
          let clientToBeNotified c' =
                if sameClientSession clnt c'
                  then pure Nothing
                  else do
                    yes <- readTVar $ connected c'
                    pure $ if yes then Just (qId, c') else Nothing
          TM.lookupInsert qId clnt (subs s) $>>= clientToBeNotified
        endPreviousSubscriptions :: (QueueId, Client) -> M (Maybe s)
        endPreviousSubscriptions (qId, c) = do
          labelMyThread $ label <> ".endPreviousSubscriptions"
          void . forkIO . atomically $
            writeTBQueue (sndQ c) [(CorrId "", qId, END)]
          atomically $ TM.lookupDelete qId (clientSubs c)

    expireMessagesThread_ :: ServerConfig -> [M ()]
    expireMessagesThread_ ServerConfig {messageExpiration = Just msgExp} = [expireMessages msgExp]
    expireMessagesThread_ _ = []

    expireMessages :: ExpirationConfig -> M ()
    expireMessages expCfg = do
      ms <- asks msgStore
      quota <- asks $ msgQueueQuota . config
      let interval = checkInterval expCfg * 1000000
      labelMyThread "expireMessages"
      forever $ do
        liftIO $ threadDelay' interval
        old <- liftIO $ expireBeforeEpoch expCfg
        rIds <- M.keysSet <$> readTVarIO ms
        forM_ rIds $ \rId ->
          atomically (getMsgQueue ms rId quota)
            >>= atomically . (`deleteExpiredMsgs` old)

    serverStatsThread_ :: ServerConfig -> [M ()]
    serverStatsThread_ ServerConfig {logStatsInterval = Just interval, logStatsStartTime, serverStatsLogFile} =
      [logServerStats logStatsStartTime interval serverStatsLogFile]
    serverStatsThread_ _ = []

    logServerStats :: Int64 -> Int64 -> FilePath -> M ()
    logServerStats startAt logInterval statsFilePath = do
      labelMyThread "logServerStats"
      initialDelay <- (startAt -) . fromIntegral . (`div` 1000000_000000) . diffTimeToPicoseconds . utctDayTime <$> liftIO getCurrentTime
      liftIO $ putStrLn $ "server stats log enabled: " <> statsFilePath
      liftIO $ threadDelay' $ 1000000 * (initialDelay + if initialDelay < 0 then 86400 else 0)
      ServerStats {fromTime, qCreated, qSecured, qDeleted, msgSent, msgRecv, activeQueues, msgSentNtf, msgRecvNtf, activeQueuesNtf, qCount, msgCount} <- asks serverStats
      let interval = 1000000 * logInterval
      withFile statsFilePath AppendMode $ \h -> liftIO $ do
        hSetBuffering h LineBuffering
        forever $ do
          ts <- getCurrentTime
          fromTime' <- atomically $ swapTVar fromTime ts
          qCreated' <- atomically $ swapTVar qCreated 0
          qSecured' <- atomically $ swapTVar qSecured 0
          qDeleted' <- atomically $ swapTVar qDeleted 0
          msgSent' <- atomically $ swapTVar msgSent 0
          msgRecv' <- atomically $ swapTVar msgRecv 0
          ps <- atomically $ periodStatCounts activeQueues ts
          msgSentNtf' <- atomically $ swapTVar msgSentNtf 0
          msgRecvNtf' <- atomically $ swapTVar msgRecvNtf 0
          psNtf <- atomically $ periodStatCounts activeQueuesNtf ts
          qCount' <- readTVarIO qCount
          msgCount' <- readTVarIO msgCount
          hPutStrLn h $
            intercalate
              ","
              [ iso8601Show $ utctDay fromTime',
                show qCreated',
                show qSecured',
                show qDeleted',
                show msgSent',
                show msgRecv',
                dayCount ps,
                weekCount ps,
                monthCount ps,
                show msgSentNtf',
                show msgRecvNtf',
                dayCount psNtf,
                weekCount psNtf,
                monthCount psNtf,
                show qCount',
                show msgCount'
              ]
          threadDelay' interval

    runClient :: Transport c => TProxy c -> c -> M ()
    runClient tp h = do
      kh <- asks serverIdentity
      smpVRange <- asks $ smpServerVRange . config
      labelMyThread $ "smp handshake for " <> transportName tp
      liftIO (runExceptT $ smpServerHandshake h kh smpVRange) >>= \case
        Right th -> runClientTransport th
        Left _ -> pure ()

    controlPortThread_ :: ServerConfig -> [M ()]
    controlPortThread_ ServerConfig {controlPort = Just port} = [runCPServer port]
    controlPortThread_ _ = []

    runCPServer :: ServiceName -> M ()
    runCPServer port = do
      srv <- asks server
      cpStarted <- newEmptyTMVarIO
      u <- askUnliftIO
      liftIO $ do
        labelMyThread "control port server"
        runTCPServer cpStarted port $ runCPClient u srv
      where
        runCPClient :: UnliftIO (ReaderT Env IO) -> Server -> Socket -> IO ()
        runCPClient u srv sock = do
          labelMyThread "control port client"
          h <- socketToHandle sock ReadWriteMode
          hSetBuffering h LineBuffering
          hSetNewlineMode h universalNewlineMode
          hPutStrLn h "SMP server control port\n'help' for supported commands"
          cpLoop h
          where
            cpLoop h = do
              s <- B.hGetLine h
              case strDecode $ trimCR s of
                Right CPQuit -> hClose h
                Right cmd -> processCP h cmd >> cpLoop h
                Left err -> hPutStrLn h ("error: " <> err) >> cpLoop h
            processCP h = \case
              CPSuspend -> hPutStrLn h "suspend not implemented"
              CPResume -> hPutStrLn h "resume not implemented"
              CPClients -> do
                Server {subscribers} <- unliftIO u $ asks server
                clients <- readTVarIO subscribers
                hPutStrLn h $ "Clients: " <> show (length clients)
                forM_ (M.toList clients) $ \(cid, Client {sessionId, connected, activeAt, subscriptions}) -> do
                  hPutStrLn h . B.unpack $ "Client " <> encode cid <> " $" <> encode sessionId
                  readTVarIO connected >>= hPutStrLn h . ("  connected: " <>) . show
                  readTVarIO activeAt >>= hPutStrLn h . ("  activeAt: " <>) . B.unpack . strEncode
                  readTVarIO subscriptions >>= hPutStrLn h . ("  subscriptions: " <>) . show . M.size
              CPStats -> do
                ServerStats {fromTime, qCreated, qSecured, qDeleted, msgSent, msgRecv, msgSentNtf, msgRecvNtf, qCount, msgCount} <- unliftIO u $ asks serverStats
                putStat "fromTime" fromTime
                putStat "qCreated" qCreated
                putStat "qSecured" qSecured
                putStat "qDeleted" qDeleted
                putStat "msgSent" msgSent
                putStat "msgRecv" msgRecv
                putStat "msgSentNtf" msgSentNtf
                putStat "msgRecvNtf" msgRecvNtf
                putStat "qCount" qCount
                putStat "msgCount" msgCount
                where
                  putStat :: Show a => String -> TVar a -> IO ()
                  putStat label var = readTVarIO var >>= \v -> hPutStrLn h $ label <> ": " <> show v
              CPStatsRTS -> getRTSStats >>= hPutStrLn h . show
              CPThreads -> do
#if MIN_VERSION_base(4,18,0)
                threads <- liftIO listThreads
                hPutStrLn h $ "Threads: " <> show (length threads)
                forM_ (sort threads) $ \tid -> do
                  label <- threadLabel tid
                  status <- threadStatus tid
                  hPutStrLn h $ show tid <> " (" <> show status <> ") " <> fromMaybe "" label
#else
                hPutStrLn h "Not available on GHC 8.10"
#endif
              CPSave -> withLock (savingLock srv) "control" $ do
                hPutStrLn h "saving server state..."
                unliftIO u $ saveServer True
                hPutStrLn h "server state saved!"
              CPHelp -> hPutStrLn h "commands: stats, stats-rts, clients, threads, save, help, quit"
              CPQuit -> pure ()
              CPSkip -> pure ()

runClientTransport :: Transport c => THandle c -> M ()
runClientTransport th@THandle {thVersion, sessionId} = do
  q <- asks $ tbqSize . config
  ts <- liftIO getSystemTime
  c <- atomically $ newClient q thVersion sessionId ts
  s <- asks server
  expCfg <- asks $ inactiveClientExpiration . config
  labelMyThread . B.unpack $ "client $" <> encode sessionId
  raceAny_ ([liftIO $ send th c, client c s, receive th c] <> disconnectThread_ c expCfg)
    `finally` clientDisconnected c
  where
    disconnectThread_ c (Just expCfg) = [liftIO $ disconnectTransport th c activeAt expCfg]
    disconnectThread_ _ _ = []

clientDisconnected :: Client -> M ()
clientDisconnected c@Client {subscriptions, connected} = do
  atomically $ writeTVar connected False
  subs <- readTVarIO subscriptions
  liftIO $ mapM_ cancelSub subs
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

cancelSub :: TVar Sub -> IO ()
cancelSub sub =
  readTVarIO sub >>= \case
    Sub {subThread = SubThread t} -> liftIO $ deRefWeak t >>= mapM_ killThread
    _ -> return ()

receive :: Transport c => THandle c -> Client -> M ()
receive th Client {rcvQ, sndQ, activeAt, sessionId} = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " receive"
  forever $ do
    ts <- L.toList <$> liftIO (tGet th)
    atomically . writeTVar activeAt =<< liftIO getSystemTime
    as <- partitionEithers <$> mapM cmdAction ts
    write sndQ $ fst as
    write rcvQ $ snd as
  where
    cmdAction :: SignedTransmission ErrorType Cmd -> M (Either (Transmission BrokerMsg) (Maybe QueueRec, Transmission Cmd))
    cmdAction (sig, signed, (corrId, queueId, cmdOrError)) =
      case cmdOrError of
        Left e -> pure $ Left (corrId, queueId, ERR e)
        Right cmd -> verified <$> verifyTransmission sig signed queueId cmd
          where
            verified = \case
              VRVerified qr -> Right (qr, (corrId, queueId, cmd))
              VRFailed -> Left (corrId, queueId, ERR AUTH)
    write q = mapM_ (atomically . writeTBQueue q) . L.nonEmpty

send :: Transport c => THandle c -> Client -> IO ()
send h@THandle {thVersion = v} Client {sndQ, sessionId, activeAt} = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " send"
  forever $ do
    ts <- atomically $ L.sortWith tOrder <$> readTBQueue sndQ
    void . liftIO . tPut h Nothing $ L.map ((Nothing,) . encodeTransmission v sessionId) ts
    atomically . writeTVar activeAt =<< liftIO getSystemTime
  where
    tOrder :: Transmission BrokerMsg -> Int
    tOrder (_, _, cmd) = case cmd of
      MSG {} -> 0
      NMSG {} -> 0
      _ -> 1

disconnectTransport :: Transport c => THandle c -> client -> (client -> TVar SystemTime) -> ExpirationConfig -> IO ()
disconnectTransport THandle {connection, sessionId} c activeAt expCfg = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " disconnectTransport"
  let interval = checkInterval expCfg * 1000000
  forever . liftIO $ do
    threadDelay' interval
    old <- expireBeforeEpoch expCfg
    ts <- readTVarIO $ activeAt c
    when (systemSeconds ts < old) $ closeConnection connection

data VerificationResult = VRVerified (Maybe QueueRec) | VRFailed

verifyTransmission :: Maybe C.ASignature -> ByteString -> QueueId -> Cmd -> M VerificationResult
verifyTransmission sig_ signed queueId cmd =
  case cmd of
    Cmd SRecipient (NEW k _ _ _) -> pure $ Nothing `verified` verifyCmdSignature sig_ signed k
    Cmd SRecipient _ -> verifyCmd SRecipient $ verifyCmdSignature sig_ signed . recipientKey
    Cmd SSender SEND {} -> verifyCmd SSender $ verifyMaybe . senderKey
    Cmd SSender PING -> pure $ VRVerified Nothing
    Cmd SNotifier NSUB -> verifyCmd SNotifier $ verifyMaybe . fmap notifierKey . notifier
  where
    verifyCmd :: SParty p -> (QueueRec -> Bool) -> M VerificationResult
    verifyCmd party f = do
      st <- asks queueStore
      q_ <- atomically $ getQueue st party queueId
      pure $ case q_ of
        Right q -> Just q `verified` f q
        _ -> maybe False (dummyVerifyCmd signed) sig_ `seq` VRFailed
    verifyMaybe :: Maybe C.APublicVerifyKey -> Bool
    verifyMaybe = maybe (isNothing sig_) $ verifyCmdSignature sig_ signed
    verified q cond = if cond then VRVerified q else VRFailed

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
client clnt@Client {thVersion, subscriptions, ntfSubscriptions, rcvQ, sndQ, sessionId} Server {subscribedQ, ntfSubscribedQ, notifiers} = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " commands"
  forever $
    atomically (readTBQueue rcvQ)
      >>= mapM processCommand
      >>= atomically . writeTBQueue sndQ
  where
    processCommand :: (Maybe QueueRec, Transmission Cmd) -> m (Transmission BrokerMsg)
    processCommand (qr_, (corrId, queueId, cmd)) = do
      st <- asks queueStore
      case cmd of
        Cmd SSender command ->
          case command of
            SEND flags msgBody -> withQueue $ \qr -> sendMessage qr flags msgBody
            PING -> pure (corrId, "", PONG)
        Cmd SNotifier NSUB -> subscribeNotifications
        Cmd SRecipient command ->
          case command of
            NEW rKey dhKey auth subMode ->
              ifM
                allowNew
                (createQueue st rKey dhKey subMode)
                (pure (corrId, queueId, ERR AUTH))
              where
                allowNew = do
                  ServerConfig {allowNewQueues, newQueueBasicAuth} <- asks config
                  pure $ allowNewQueues && maybe True ((== auth) . Just) newQueueBasicAuth
            SUB -> withQueue (`subscribeQueue` queueId)
            GET -> withQueue getMessage
            ACK msgId -> withQueue (`acknowledgeMsg` msgId)
            KEY sKey -> secureQueue_ st sKey
            NKEY nKey dhKey -> addQueueNotifier_ st nKey dhKey
            NDEL -> deleteQueueNotifier_ st
            OFF -> suspendQueue_ st
            DEL -> delQueueAndMsgs st
      where
        createQueue :: QueueStore -> RcvPublicVerifyKey -> RcvPublicDhKey -> SubscriptionMode -> m (Transmission BrokerMsg)
        createQueue st recipientKey dhKey subMode = time "NEW" $ do
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
              let qr = qRec ids
              atomically (addQueue st qr) >>= \case
                Left DUPLICATE_ -> addQueueRetry (n - 1) qik qRec
                Left e -> pure $ ERR e
                Right _ -> do
                  withLog (`logCreateById` rId)
                  stats <- asks serverStats
                  atomically $ modifyTVar' (qCreated stats) (+ 1)
                  atomically $ modifyTVar' (qCount stats) (+ 1)
                  case subMode of
                    SMOnlyCreate -> pure ()
                    SMSubscribe -> void $ subscribeQueue qr rId
                  pure $ IDS (qik ids)

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
        secureQueue_ st sKey = time "KEY" $ do
          withLog $ \s -> logSecureQueue s queueId sKey
          stats <- asks serverStats
          atomically $ modifyTVar' (qSecured stats) (+ 1)
          atomically $ (corrId,queueId,) . either ERR (const OK) <$> secureQueue st queueId sKey

        addQueueNotifier_ :: QueueStore -> NtfPublicVerifyKey -> RcvNtfPublicDhKey -> m (Transmission BrokerMsg)
        addQueueNotifier_ st notifierKey dhKey = time "NKEY" $ do
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
          withLog (`logSuspendQueue` queueId)
          okResp <$> atomically (suspendQueue st queueId)

        subscribeQueue :: QueueRec -> RecipientId -> m (Transmission BrokerMsg)
        subscribeQueue qr rId = do
          atomically (TM.lookup rId subscriptions) >>= \case
            Nothing ->
              newSub >>= deliver
            Just sub ->
              readTVarIO sub >>= \case
                Sub {subThread = ProhibitSub} ->
                  -- cannot use SUB in the same connection where GET was used
                  pure (corrId, rId, ERR $ CMD PROHIBITED)
                s ->
                  atomically (tryTakeTMVar $ delivered s) >> deliver sub
          where
            newSub :: m (TVar Sub)
            newSub = time "SUB newSub" . atomically $ do
              writeTQueue subscribedQ (rId, clnt)
              sub <- newTVar =<< newSubscription NoSub
              TM.insert rId sub subscriptions
              pure sub
            deliver :: TVar Sub -> m (Transmission BrokerMsg)
            deliver sub = do
              q <- getStoreMsgQueue "SUB" rId
              msg_ <- atomically $ tryPeekMsg q
              deliverMessage "SUB" qr rId sub q msg_

        getMessage :: QueueRec -> m (Transmission BrokerMsg)
        getMessage qr = time "GET" $ do
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
            getMessage_ s = do
              q <- getStoreMsgQueue "GET" queueId
              atomically $
                tryPeekMsg q >>= \case
                  Just msg ->
                    let encMsg = encryptMsg qr msg
                     in setDelivered s msg $> (corrId, queueId, MSG encMsg)
                  _ -> pure (corrId, queueId, OK)

        withQueue :: (QueueRec -> m (Transmission BrokerMsg)) -> m (Transmission BrokerMsg)
        withQueue action = maybe (pure $ err AUTH) action qr_

        subscribeNotifications :: m (Transmission BrokerMsg)
        subscribeNotifications = time "NSUB" . atomically $ do
          unlessM (TM.member queueId ntfSubscriptions) $ do
            writeTQueue ntfSubscribedQ (queueId, clnt)
            TM.insert queueId () ntfSubscriptions
          pure ok

        acknowledgeMsg :: QueueRec -> MsgId -> m (Transmission BrokerMsg)
        acknowledgeMsg qr msgId = time "ACK" $ do
          atomically (TM.lookup queueId subscriptions) >>= \case
            Nothing -> pure $ err NO_MSG
            Just sub ->
              atomically (getDelivered sub) >>= \case
                Just s -> do
                  q <- getStoreMsgQueue "ACK" queueId
                  case s of
                    Sub {subThread = ProhibitSub} -> do
                      deletedMsg_ <- atomically $ tryDelMsg q msgId
                      mapM_ updateStats deletedMsg_
                      pure ok
                    _ -> do
                      (deletedMsg_, msg_) <- atomically $ tryDelPeekMsg q msgId
                      mapM_ updateStats deletedMsg_
                      deliverMessage "ACK" qr queueId sub q msg_
                _ -> pure $ err NO_MSG
          where
            getDelivered :: TVar Sub -> STM (Maybe Sub)
            getDelivered sub = do
              s@Sub {delivered} <- readTVar sub
              tryTakeTMVar delivered $>>= \msgId' ->
                if msgId == msgId' || B.null msgId
                  then pure $ Just s
                  else putTMVar delivered msgId' $> Nothing
            updateStats :: Message -> m ()
            updateStats = \case
              MessageQuota {} -> pure ()
              Message {msgFlags} -> do
                stats <- asks serverStats
                atomically $ modifyTVar' (msgRecv stats) (+ 1)
                atomically $ modifyTVar' (msgCount stats) (+ 1)
                atomically $ updatePeriodStats (activeQueues stats) queueId
                when (notification msgFlags) $ do
                  atomically $ modifyTVar' (msgRecvNtf stats) (+ 1)
                  atomically $ updatePeriodStats (activeQueuesNtf stats) queueId

        sendMessage :: QueueRec -> MsgFlags -> MsgBody -> m (Transmission BrokerMsg)
        sendMessage qr msgFlags msgBody
          | B.length msgBody > maxMessageLength = pure $ err LARGE_MSG
          | otherwise = case status qr of
              QueueOff -> return $ err AUTH
              QueueActive ->
                case C.maxLenBS msgBody of
                  Left _ -> pure $ err LARGE_MSG
                  Right body -> do
                    msg_ <- time "SEND" $ do
                      q <- getStoreMsgQueue "SEND" $ recipientId qr
                      expireMessages q
                      atomically . writeMsg q =<< mkMessage body
                    case msg_ of
                      Nothing -> pure $ err QUOTA
                      Just msg -> time "SEND ok" $ do
                        stats <- asks serverStats
                        when (notification msgFlags) $ do
                          atomically . trySendNotification msg =<< asks idsDrg
                          atomically $ modifyTVar' (msgSentNtf stats) (+ 1)
                          atomically $ updatePeriodStats (activeQueuesNtf stats) (recipientId qr)
                        atomically $ modifyTVar' (msgSent stats) (+ 1)
                        atomically $ modifyTVar' (msgCount stats) (subtract 1)
                        atomically $ updatePeriodStats (activeQueues stats) (recipientId qr)
                        pure ok
          where
            mkMessage :: C.MaxLenBS MaxMessageLen -> m Message
            mkMessage body = do
              msgId <- randomId =<< asks (msgIdBytes . config)
              msgTs <- liftIO getSystemTime
              pure $ Message msgId msgTs msgFlags body

            expireMessages :: MsgQueue -> m ()
            expireMessages q = do
              msgExp <- asks $ messageExpiration . config
              old <- liftIO $ mapM expireBeforeEpoch msgExp
              atomically $ mapM_ (deleteExpiredMsgs q) old

            trySendNotification :: Message -> TVar ChaChaDRG -> STM ()
            trySendNotification msg ntfNonceDrg =
              forM_ (notifier qr) $ \NtfCreds {notifierId, rcvNtfDhSecret} ->
                mapM_ (writeNtf notifierId msg rcvNtfDhSecret ntfNonceDrg) =<< TM.lookup notifierId notifiers

            writeNtf :: NotifierId -> Message -> RcvNtfDhSecret -> TVar ChaChaDRG -> Client -> STM ()
            writeNtf nId msg rcvNtfDhSecret ntfNonceDrg Client {sndQ = q} =
              unlessM (isFullTBQueue q) $ case msg of
                Message {msgId, msgTs} -> do
                  (nmsgNonce, encNMsgMeta) <- mkMessageNotification msgId msgTs rcvNtfDhSecret ntfNonceDrg
                  writeTBQueue q [(CorrId "", nId, NMSG nmsgNonce encNMsgMeta)]
                _ -> pure ()

            mkMessageNotification :: ByteString -> SystemTime -> RcvNtfDhSecret -> TVar ChaChaDRG -> STM (C.CbNonce, EncNMsgMeta)
            mkMessageNotification msgId msgTs rcvNtfDhSecret ntfNonceDrg = do
              cbNonce <- C.pseudoRandomCbNonce ntfNonceDrg
              let msgMeta = NMsgMeta {msgId, msgTs}
                  encNMsgMeta = C.cbEncrypt rcvNtfDhSecret cbNonce (smpEncode msgMeta) 128
              pure . (cbNonce,) $ fromRight "" encNMsgMeta

        deliverMessage :: T.Text -> QueueRec -> RecipientId -> TVar Sub -> MsgQueue -> Maybe Message -> m (Transmission BrokerMsg)
        deliverMessage name qr rId sub q msg_ = time (name <> " deliver") $ do
          readTVarIO sub >>= \case
            s@Sub {subThread = NoSub} ->
              case msg_ of
                Just msg ->
                  let encMsg = encryptMsg qr msg
                   in atomically (setDelivered s msg) $> (corrId, rId, MSG encMsg)
                _ -> forkSub $> ok
            _ -> pure ok
          where
            forkSub :: m ()
            forkSub = do
              atomically . modifyTVar' sub $ \s -> s {subThread = SubPending}
              t <- mkWeakThreadId =<< forkIO subscriber
              atomically . modifyTVar' sub $ \case
                s@Sub {subThread = SubPending} -> s {subThread = SubThread t}
                s -> s
              where
                subscriber = do
                  msg <- atomically $ peekMsg q
                  time "subscriber" . atomically $ do
                    let encMsg = encryptMsg qr msg
                    writeTBQueue sndQ [(CorrId "", rId, MSG encMsg)]
                    s <- readTVar sub
                    void $ setDelivered s msg
                    writeTVar sub $! s {subThread = NoSub}

        time :: T.Text -> m a -> m a
        time name = timed name queueId

        encryptMsg :: QueueRec -> Message -> RcvMessage
        encryptMsg qr msg = case msg of
          Message {msgFlags, msgBody}
            | thVersion == 1 || thVersion == 2 -> encrypt msgFlags msgBody
            | otherwise -> encrypt msgFlags $ encodeRcvMsgBody RcvMsgBody {msgTs = msgTs', msgFlags, msgBody}
          MessageQuota {} ->
            encrypt noMsgFlags $ encodeRcvMsgBody (RcvMsgQuota msgTs')
          where
            encrypt :: KnownNat i => MsgFlags -> C.MaxLenBS i -> RcvMessage
            encrypt msgFlags body =
              let encBody = EncRcvMsgBody $ C.cbEncryptMaxLenBS (rcvDhSecret qr) (C.cbNonce msgId') body
               in RcvMessage msgId' msgTs' msgFlags encBody
            msgId' = messageId msg
            msgTs' = messageTs msg

        setDelivered :: Sub -> Message -> STM Bool
        setDelivered s msg = tryPutTMVar (delivered s) (messageId msg)

        getStoreMsgQueue :: T.Text -> RecipientId -> m MsgQueue
        getStoreMsgQueue name rId = time (name <> " getMsgQueue") $ do
          ms <- asks msgStore
          quota <- asks $ msgQueueQuota . config
          atomically $ getMsgQueue ms rId quota

        delQueueAndMsgs :: QueueStore -> m (Transmission BrokerMsg)
        delQueueAndMsgs st = do
          withLog (`logDeleteQueue` queueId)
          ms <- asks msgStore
          stats <- asks serverStats
          atomically $ modifyTVar' (qDeleted stats) (+ 1)
          atomically $ modifyTVar' (qCount stats) (subtract 1)
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

timed :: MonadUnliftIO m => T.Text -> RecipientId -> m a -> m a
timed name qId a = do
  t <- liftIO getSystemTime
  r <- a
  t' <- liftIO getSystemTime
  let int = diff t t'
  when (int > sec) . logDebug $ T.unwords [name, tshow $ encode qId, tshow int]
  pure r
  where
    diff t t' = (systemSeconds t' - systemSeconds t) * sec + fromIntegral (systemNanoseconds t' - systemNanoseconds t)
    sec = 1000_000000

randomId :: (MonadUnliftIO m, MonadReader Env m) => Int -> m ByteString
randomId n = do
  gVar <- asks idsDrg
  atomically (C.pseudoRandomBytes n gVar)

saveServerMessages :: (MonadUnliftIO m, MonadReader Env m) => Bool -> m ()
saveServerMessages keepMsgs = asks (storeMsgsFile . config) >>= mapM_ saveMessages
  where
    saveMessages f = do
      logInfo $ "saving messages to file " <> T.pack f
      ms <- asks msgStore
      liftIO . withFile f WriteMode $ \h ->
        readTVarIO ms >>= mapM_ (saveQueueMsgs ms h) . M.keys
      logInfo "messages saved"
      where
        getMessages = if keepMsgs then snapshotMsgQueue else flushMsgQueue
        saveQueueMsgs ms h rId =
          atomically (getMessages ms rId)
            >>= mapM_ (B.hPutStrLn h . strEncode . MLRv3 rId)

restoreServerMessages :: forall m. (MonadUnliftIO m, MonadReader Env m) => m ()
restoreServerMessages = asks (storeMsgsFile . config) >>= mapM_ restoreMessages
  where
    restoreMessages f = whenM (doesFileExist f) $ do
      logInfo $ "restoring messages from file " <> T.pack f
      st <- asks queueStore
      ms <- asks msgStore
      quota <- asks $ msgQueueQuota . config
      old_ <- asks (messageExpiration . config) $>>= (liftIO . fmap Just . expireBeforeEpoch)
      runExceptT (liftIO (B.readFile f) >>= mapM_ (restoreMsg st ms quota old_) . B.lines) >>= \case
        Left e -> do
          logError . T.pack $ "error restoring messages: " <> e
          liftIO exitFailure
        _ -> do
          renameFile f $ f <> ".bak"
          logInfo "messages restored"
      where
        restoreMsg st ms quota old_ s = do
          r <- liftEither . first (msgErr "parsing") $ strDecode s
          case r of
            MLRv3 rId msg -> addToMsgQueue rId msg
            MLRv1 rId encMsg -> do
              qr <- liftEitherError (msgErr "queue unknown") . atomically $ getQueue st SRecipient rId
              msg' <- updateMsgV1toV3 qr encMsg
              addToMsgQueue rId msg'
          where
            addToMsgQueue rId msg = do
              logFull <- atomically $ do
                q <- getMsgQueue ms rId quota
                case msg of
                  Message {msgTs}
                    | maybe True (systemSeconds msgTs >=) old_ -> isNothing <$> writeMsg q msg
                    | otherwise -> pure False
                  MessageQuota {} -> writeMsg q msg $> False
              when logFull . logError . decodeLatin1 $ "message queue " <> strEncode rId <> " is full, message not restored: " <> strEncode (messageId msg)
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
          _qCount <- fmap (length . M.keys) . readTVarIO . queues =<< asks queueStore
          _msgCount <- foldM (\n q -> (n +) <$> readTVarIO (size q)) 0 =<< readTVarIO =<< asks msgStore
          atomically $ setServerStats s d {_qCount, _msgCount}
          renameFile f $ f <> ".bak"
          logInfo "server stats restored"
        Left e -> do
          logInfo $ "error restoring server stats: " <> T.pack e
          liftIO exitFailure
