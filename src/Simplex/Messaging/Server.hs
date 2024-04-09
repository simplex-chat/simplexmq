{-# LANGUAGE BangPatterns #-}
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
{-# LANGUAGE TypeApplications #-}

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
    verifyCmdAuthorization,
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
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Either (fromRight, partitionEithers)
import Data.Functor (($>))
import Data.Int (Int64)
import qualified Data.IntMap.Strict as IM
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
import System.IO (hPrint, hPutStrLn, hSetNewlineMode, universalNewlineMode)
import System.Mem.Weak (deRefWeak)
import UnliftIO (timeout)
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
  expired <- restoreServerMessages
  restoreServerStats expired
  raceAny_
    ( serverThread s "server subscribedQ" subscribedQ subscribers subscriptions cancelSub
        : serverThread s "server ntfSubscribedQ" ntfSubscribedQ Env.notifiers ntfSubscriptions (\_ -> pure ())
        : map runServer transports <> expireMessagesThread_ cfg <> serverStatsThread_ cfg <> controlPortThread_ cfg
    )
    `finally` withLock' (savingLock s) "final" (saveServer False)
  where
    runServer :: (ServiceName, ATransport) -> M ()
    runServer (tcpPort, ATransport t) = do
      serverParams <- asks tlsServerParams
      ss <- asks sockets
      serverSignKey <- either fail pure . fromTLSCredentials $ tlsServerCredentials serverParams
      env <- ask
      liftIO $ runTransportServerState ss started tcpPort serverParams tCfg $ \h -> runClient serverSignKey t h `runReaderT` env
    fromTLSCredentials (_, pk) = C.x509ToPrivate (pk, []) >>= C.privKey

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
    serverThread s label subQ subs clientSubs unsub = do
      labelMyThread label
      forever $
        atomically' updateSubscribers
          $>>= endPreviousSubscriptions
          >>= liftIO . mapM_ unsub
      where
        updateSubscribers :: STM (Maybe (QueueId, Client))
        updateSubscribers = do
          (qId, clnt) <- readTQueue $ subQ s
          let clientToBeNotified c' =
                if sameClientId clnt c'
                  then pure Nothing
                  else do
                    yes <- readTVar $ connected c'
                    pure $ if yes then Just (qId, c') else Nothing
          TM.lookupInsert qId clnt (subs s) $>>= clientToBeNotified
        endPreviousSubscriptions :: (QueueId, Client) -> M (Maybe s)
        endPreviousSubscriptions (qId, c) = do
          tId <- atomically $ stateTVar (endThreadSeq c) $ \next -> (next, next + 1)
          t <- forkIO $ do
            labelMyThread $ label <> ".endPreviousSubscriptions"
            atomically $ writeTBQueue (sndQ c) [(CorrId "", qId, END)]
            atomically $ modifyTVar' (endThreads c) $ IM.delete tId
          mkWeakThreadId t >>= atomically' . modifyTVar' (endThreads c) . IM.insert tId
          atomically $ TM.lookupDelete qId (clientSubs c)

    expireMessagesThread_ :: ServerConfig -> [M ()]
    expireMessagesThread_ ServerConfig {messageExpiration = Just msgExp} = [expireMessages msgExp]
    expireMessagesThread_ _ = []

    expireMessages :: ExpirationConfig -> M ()
    expireMessages expCfg = do
      ms <- asks msgStore
      quota <- asks $ msgQueueQuota . config
      let interval = checkInterval expCfg * 1000000
      stats <- asks serverStats
      labelMyThread "expireMessages"
      forever $ do
        liftIO $ threadDelay' interval
        old <- liftIO $ expireBeforeEpoch expCfg
        rIds <- M.keysSet <$> readTVarIO ms
        forM_ rIds $ \rId -> do
          q <- atomically' (getMsgQueue ms rId quota)
          deleted <- atomically' $ deleteExpiredMsgs q old
          atomically $ modifyTVar' (msgExpired stats) (+ deleted)

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
      ServerStats {fromTime, qCreated, qSecured, qDeletedAll, qDeletedNew, qDeletedSecured, msgSent, msgRecv, msgExpired, activeQueues, msgSentNtf, msgRecvNtf, activeQueuesNtf, qCount, msgCount} <- asks serverStats
      let interval = 1000000 * logInterval
      forever $ do
        withFile statsFilePath AppendMode $ \h -> liftIO $ do
          hSetBuffering h LineBuffering
          ts <- getCurrentTime
          fromTime' <- atomically' $ swapTVar fromTime ts
          qCreated' <- atomically' $ swapTVar qCreated 0
          qSecured' <- atomically' $ swapTVar qSecured 0
          qDeletedAll' <- atomically' $ swapTVar qDeletedAll 0
          qDeletedNew' <- atomically' $ swapTVar qDeletedNew 0
          qDeletedSecured' <- atomically' $ swapTVar qDeletedSecured 0
          msgSent' <- atomically' $ swapTVar msgSent 0
          msgRecv' <- atomically' $ swapTVar msgRecv 0
          msgExpired' <- atomically' $ swapTVar msgExpired 0
          ps <- atomically' $ periodStatCounts activeQueues ts
          msgSentNtf' <- atomically' $ swapTVar msgSentNtf 0
          msgRecvNtf' <- atomically' $ swapTVar msgRecvNtf 0
          psNtf <- atomically' $ periodStatCounts activeQueuesNtf ts
          qCount' <- readTVarIO qCount
          msgCount' <- readTVarIO msgCount
          hPutStrLn h $
            intercalate
              ","
              [ iso8601Show $ utctDay fromTime',
                show qCreated',
                show qSecured',
                show qDeletedAll',
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
                show msgCount',
                show msgExpired',
                show qDeletedNew',
                show qDeletedSecured'
              ]
        liftIO $ threadDelay' interval

    runClient :: Transport c => C.APrivateSignKey -> TProxy c -> c -> M ()
    runClient signKey tp h = do
      kh <- asks serverIdentity
      ks <- atomically . C.generateKeyPair =<< asks random
      ServerConfig {smpServerVRange, smpHandshakeTimeout} <- asks config
      labelMyThread $ "smp handshake for " <> transportName tp
      liftIO (timeout smpHandshakeTimeout . runExceptT $ smpServerHandshake signKey h ks kh smpServerVRange) >>= \case
        Just (Right th) -> runClientTransport th
        _ -> pure ()

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
          role <- newTVarIO CPRNone
          cpLoop h role
          where
            cpLoop h role = do
              s <- trimCR <$> B.hGetLine h
              case strDecode s of
                Right CPQuit -> hClose h
                Right cmd -> logCmd s cmd >> processCP h role cmd >> cpLoop h role
                Left err -> hPutStrLn h ("error: " <> err) >> cpLoop h role
            logCmd s cmd = when shouldLog $ logWarn $ "ControlPort: " <> tshow s
              where
                shouldLog = case cmd of
                  CPAuth _ -> False
                  CPHelp -> False
                  CPQuit -> False
                  CPSkip -> False
                  _ -> True
            processCP h role = \case
              CPAuth auth -> atomically $ writeTVar role $! newRole cfg
                where
                  newRole ServerConfig {controlPortUserAuth = user, controlPortAdminAuth = admin}
                    | Just auth == admin = CPRAdmin
                    | Just auth == user = CPRUser
                    | otherwise = CPRNone
              CPSuspend -> withAdminRole $ hPutStrLn h "suspend not implemented"
              CPResume -> withAdminRole $ hPutStrLn h "resume not implemented"
              CPClients -> withAdminRole $ do
                active <- unliftIO u (asks clients) >>= readTVarIO
                hPutStrLn h $ "clientId,sessionId,connected,createdAt,rcvActiveAt,sndActiveAt,age,subscriptions"
                forM_ (IM.toList active) $ \(cid, Client {sessionId, connected, createdAt, rcvActiveAt, sndActiveAt, subscriptions}) -> do
                  connected' <- bshow <$> readTVarIO connected
                  rcvActiveAt' <- strEncode <$> readTVarIO rcvActiveAt
                  sndActiveAt' <- strEncode <$> readTVarIO sndActiveAt
                  now <- liftIO getSystemTime
                  let age = systemSeconds now - systemSeconds createdAt
                  subscriptions' <- bshow . M.size <$> readTVarIO subscriptions
                  hPutStrLn h . B.unpack $ B.intercalate "," [bshow cid, encode sessionId, connected', strEncode createdAt, rcvActiveAt', sndActiveAt', bshow age, subscriptions']
              CPStats -> withAdminRole $ do
                ServerStats {fromTime, qCreated, qSecured, qDeletedAll, qDeletedNew, qDeletedSecured, msgSent, msgRecv, msgSentNtf, msgRecvNtf, qCount, msgCount} <- unliftIO u $ asks serverStats
                putStat "fromTime" fromTime
                putStat "qCreated" qCreated
                putStat "qSecured" qSecured
                putStat "qDeletedAll" qDeletedAll
                putStat "qDeletedNew" qDeletedNew
                putStat "qDeletedSecured" qDeletedSecured
                putStat "msgSent" msgSent
                putStat "msgRecv" msgRecv
                putStat "msgSentNtf" msgSentNtf
                putStat "msgRecvNtf" msgRecvNtf
                putStat "qCount" qCount
                putStat "msgCount" msgCount
                where
                  putStat :: Show a => String -> TVar a -> IO ()
                  putStat label var = readTVarIO var >>= \v -> hPutStrLn h $ label <> ": " <> show v
              CPStatsRTS -> getRTSStats >>= hPrint h
              CPThreads -> withAdminRole $ do
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
              CPSockets -> withAdminRole $ do
                (accepted', closed', active') <- unliftIO u $ asks sockets
                (accepted, closed, active) <- atomically' $ (,,) <$> readTVar accepted' <*> readTVar closed' <*> readTVar active'
                hPutStrLn h "Sockets: "
                hPutStrLn h $ "accepted: " <> show accepted
                hPutStrLn h $ "closed: " <> show closed
                hPutStrLn h $ "active: " <> show (IM.size active)
                hPutStrLn h $ "leaked: " <> show (accepted - closed - IM.size active)
              CPSocketThreads -> withAdminRole $ do
#if MIN_VERSION_base(4,18,0)
                (_, _, active') <- unliftIO u $ asks sockets
                active <- readTVarIO active'
                forM_ (IM.toList active) $ \(sid, tid') ->
                  deRefWeak tid' >>= \case
                    Nothing -> hPutStrLn h $ intercalate "," [show sid, "", "gone", ""]
                    Just tid -> do
                      label <- threadLabel tid
                      status <- threadStatus tid
                      hPutStrLn h $ intercalate "," [show sid, show tid, show status, fromMaybe "" label]
#else
                hPutStrLn h "Not available on GHC 8.10"
#endif
              CPDelete queueId' -> withUserRole $ unliftIO u $ do
                st <- asks queueStore
                ms <- asks msgStore
                queueId <- atomically' (getQueue st SSender queueId') >>= \case
                  Left _ -> pure queueId' -- fallback to using as recipientId directly
                  Right QueueRec {recipientId} -> pure recipientId
                r <- atomically' $
                  deleteQueue st queueId $>>= \q ->
                    Right . (q,) <$> delMsgQueueSize ms queueId
                case r of
                  Left e -> liftIO . hPutStrLn h $ "error: " <> show e
                  Right (q, numDeleted) -> do
                    withLog (`logDeleteQueue` queueId)
                    updateDeletedStats q
                    liftIO . hPutStrLn h $ "ok, " <> show numDeleted <> " messages deleted"
              CPSave -> withAdminRole $ withLock' (savingLock srv) "control" $ do
                hPutStrLn h "saving server state..."
                unliftIO u $ saveServer True
                hPutStrLn h "server state saved!"
              CPHelp -> hPutStrLn h "commands: stats, stats-rts, clients, sockets, socket-threads, threads, delete, save, help, quit"
              CPQuit -> pure ()
              CPSkip -> pure ()
              where
                withUserRole action = readTVarIO role >>= \case
                  CPRAdmin -> action
                  CPRUser -> action
                  _ -> do
                    logError "Unauthorized control port command"
                    hPutStrLn h "AUTH"
                withAdminRole action = readTVarIO role >>= \case
                  CPRAdmin -> action
                  _ -> do
                    logError "Unauthorized control port command"
                    hPutStrLn h "AUTH"

runClientTransport :: Transport c => THandleSMP c -> M ()
runClientTransport th@THandle {params = THandleParams {thVersion, sessionId}} = do
  q <- asks $ tbqSize . config
  ts <- liftIO getSystemTime
  active <- asks clients
  nextClientId <- asks clientSeq
  c <- atomically' $ do
    new@Client {clientId} <- newClient nextClientId q thVersion sessionId ts
    modifyTVar' active $ IM.insert clientId new
    pure new
  s <- asks server
  expCfg <- asks $ inactiveClientExpiration . config
  labelMyThread . B.unpack $ "client $" <> encode sessionId
  raceAny_ ([liftIO $ send th c, client c s, receive th c] <> disconnectThread_ c expCfg)
    `finally` clientDisconnected c
  where
    disconnectThread_ c (Just expCfg) = [liftIO $ disconnectTransport th (rcvActiveAt c) (sndActiveAt c) expCfg (noSubscriptions c)]
    disconnectThread_ _ _ = []
    noSubscriptions c = atomically' $ (&&) <$> TM.null (subscriptions c) <*> TM.null (ntfSubscriptions c)

clientDisconnected :: Client -> M ()
clientDisconnected c@Client {clientId, subscriptions, connected, sessionId, endThreads} = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " disc"
  subs <- atomically' $ do
    writeTVar connected False
    swapTVar subscriptions M.empty
  liftIO $ mapM_ cancelSub subs
  srvSubs <- asks $ subscribers . server
  atomically $ modifyTVar' srvSubs $ \cs ->
    M.foldrWithKey (\sub _ -> M.update deleteCurrentClient sub) cs subs
  asks clients >>= atomically' . (`modifyTVar'` IM.delete clientId)
  tIds <- atomically' $ swapTVar endThreads IM.empty
  liftIO $ mapM_ (mapM_ killThread <=< deRefWeak) tIds
  where
    deleteCurrentClient :: Client -> Maybe Client
    deleteCurrentClient c'
      | sameClientId c c' = Nothing
      | otherwise = Just c'

sameClientId :: Client -> Client -> Bool
sameClientId Client {clientId} Client {clientId = cId'} = clientId == cId'

cancelSub :: TVar Sub -> IO ()
cancelSub sub =
  readTVarIO sub >>= \case
    Sub {subThread = SubThread t} -> liftIO $ deRefWeak t >>= mapM_ killThread
    _ -> return ()

receive :: Transport c => THandleSMP c -> Client -> M ()
receive th@THandle {params = THandleParams {thAuth}} Client {rcvQ, sndQ, rcvActiveAt, sessionId} = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " receive"
  forever $ do
    ts <- L.toList <$> liftIO (tGet th)
    atomically . writeTVar rcvActiveAt =<< liftIO getSystemTime
    as <- partitionEithers <$> mapM cmdAction ts
    write sndQ $ fst as
    write rcvQ $ snd as
  where
    cmdAction :: SignedTransmission ErrorType Cmd -> M (Either (Transmission BrokerMsg) (Maybe QueueRec, Transmission Cmd))
    cmdAction (tAuth, authorized, (corrId, queueId, cmdOrError)) =
      case cmdOrError of
        Left e -> pure $ Left (corrId, queueId, ERR e)
        Right cmd -> verified <$> verifyTransmission ((,C.cbNonce (bs corrId)) <$> thAuth) tAuth authorized queueId cmd
          where
            verified = \case
              VRVerified qr -> Right (qr, (corrId, queueId, cmd))
              VRFailed -> Left (corrId, queueId, ERR AUTH)
    write q = mapM_ (atomically' . writeTBQueue q) . L.nonEmpty

send :: Transport c => THandleSMP c -> Client -> IO ()
send h@THandle {params} Client {sndQ, sessionId, sndActiveAt} = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " send"
  forever $ do
    ts <- atomically' $ L.sortWith tOrder <$> readTBQueue sndQ
    -- TODO we can authorize responses as well
    void . liftIO . tPut h $ L.map (\t -> Right (Nothing, encodeTransmission params t)) ts
    atomically . writeTVar sndActiveAt =<< liftIO getSystemTime
  where
    tOrder :: Transmission BrokerMsg -> Int
    tOrder (_, _, cmd) = case cmd of
      MSG {} -> 0
      NMSG {} -> 0
      _ -> 1

disconnectTransport :: Transport c => THandle v c -> TVar SystemTime -> TVar SystemTime -> ExpirationConfig -> IO Bool -> IO ()
disconnectTransport THandle {connection, params = THandleParams {sessionId}} rcvActiveAt sndActiveAt expCfg noSubscriptions = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " disconnectTransport"
  loop
  where
    loop = do
      threadDelay' $ checkInterval expCfg * 1000000
      ifM noSubscriptions checkExpired loop
    checkExpired = do
      old <- expireBeforeEpoch expCfg
      ts <- max <$> readTVarIO rcvActiveAt <*> readTVarIO sndActiveAt
      if systemSeconds ts < old then closeConnection connection else loop

data VerificationResult = VRVerified (Maybe QueueRec) | VRFailed

-- This function verifies queue command authorization, with the objective to have constant time between the three AUTH error scenarios:
-- - the queue and party key exist, and the provided authorization has type matching queue key, but it is made with the different key.
-- - the queue and party key exist, but the provided authorization has incorrect type.
-- - the queue or party key do not exist.
-- In all cases, the time of the verification should depend only on the provided authorization type,
-- a dummy key is used to run verification in the last two cases, and failure is returned irrespective of the result.
verifyTransmission :: Maybe (THandleAuth, C.CbNonce) -> Maybe TransmissionAuth -> ByteString -> QueueId -> Cmd -> M VerificationResult
verifyTransmission auth_ tAuth authorized queueId cmd =
  case cmd of
    Cmd SRecipient (NEW k _ _ _) -> pure $ Nothing `verifiedWith` k
    Cmd SRecipient _ -> verifyQueue (\q -> Just q `verifiedWith` recipientKey q) <$> get SRecipient
    -- SEND will be accepted without authorization before the queue is secured with KEY command
    Cmd SSender SEND {} -> verifyQueue (\q -> Just q `verified` maybe (isNothing tAuth) verify (senderKey q)) <$> get SSender
    Cmd SSender PING -> pure $ VRVerified Nothing
    -- NSUB will not be accepted without authorization
    Cmd SNotifier NSUB -> verifyQueue (\q -> maybe dummyVerify (Just q `verifiedWith`) (notifierKey <$> notifier q)) <$> get SNotifier
  where
    verify = verifyCmdAuthorization auth_ tAuth authorized
    dummyVerify = verify (dummyAuthKey tAuth) `seq` VRFailed
    verifyQueue :: (QueueRec -> VerificationResult) -> Either ErrorType QueueRec -> VerificationResult
    verifyQueue = either (\_ -> dummyVerify)
    verified q cond = if cond then VRVerified q else VRFailed
    verifiedWith q k = q `verified` verify k
    get :: SParty p -> M (Either ErrorType QueueRec)
    get party = do
      st <- asks queueStore
      atomically' $ getQueue st party queueId

verifyCmdAuthorization :: Maybe (THandleAuth, C.CbNonce) -> Maybe TransmissionAuth -> ByteString -> C.APublicAuthKey -> Bool
verifyCmdAuthorization auth_ tAuth authorized key = maybe False (verify key) tAuth
  where
    verify :: C.APublicAuthKey -> TransmissionAuth -> Bool
    verify (C.APublicAuthKey a k) = \case
      TASignature (C.ASignature a' s) -> case testEquality a a' of
        Just Refl -> C.verify' k s authorized
        _ -> C.verify' (dummySignKey a') s authorized `seq` False
      TAAuthenticator s -> case a of
        C.SX25519 -> verifyCmdAuth auth_ k s authorized
        _ -> verifyCmdAuth auth_ dummyKeyX25519 s authorized `seq` False

verifyCmdAuth :: Maybe (THandleAuth, C.CbNonce) -> C.PublicKeyX25519 -> C.CbAuthenticator -> ByteString -> Bool
verifyCmdAuth auth_ k authenticator authorized = case auth_ of
  Just (THandleAuth {privKey}, nonce) -> C.cbVerify k privKey nonce authenticator authorized
  Nothing -> False

dummyVerifyCmd :: Maybe (THandleAuth, C.CbNonce) -> ByteString -> TransmissionAuth -> Bool
dummyVerifyCmd auth_ authorized = \case
  TASignature (C.ASignature a s) -> C.verify' (dummySignKey a) s authorized
  TAAuthenticator s -> verifyCmdAuth auth_ dummyKeyX25519 s authorized

-- These dummy keys are used with `dummyVerify` function to mitigate timing attacks
-- by having the same time of the response whether a queue exists or nor, for all valid key/signature sizes
dummySignKey :: C.SignatureAlgorithm a => C.SAlgorithm a -> C.PublicKey a
dummySignKey = \case
  C.SEd25519 -> dummyKeyEd25519
  C.SEd448 -> dummyKeyEd448

dummyAuthKey :: Maybe TransmissionAuth -> C.APublicAuthKey
dummyAuthKey = \case
  Just (TASignature (C.ASignature a _)) -> case a of
    C.SEd25519 -> C.APublicAuthKey C.SEd25519 dummyKeyEd25519
    C.SEd448 -> C.APublicAuthKey C.SEd448 dummyKeyEd448
  _ -> C.APublicAuthKey C.SX25519 dummyKeyX25519

dummyKeyEd25519 :: C.PublicKey 'C.Ed25519
dummyKeyEd25519 = "MCowBQYDK2VwAyEA139Oqs4QgpqbAmB0o7rZf6T19ryl7E65k4AYe0kE3Qs="

dummyKeyEd448 :: C.PublicKey 'C.Ed448
dummyKeyEd448 = "MEMwBQYDK2VxAzoA6ibQc9XpkSLtwrf7PLvp81qW/etiumckVFImCMRdftcG/XopbOSaq9qyLhrgJWKOLyNrQPNVvpMA"

dummyKeyX25519 :: C.PublicKey 'C.X25519
dummyKeyX25519 = "MCowBQYDK2VuAyEA4JGSMYht18H4mas/jHeBwfcM7jLwNYJNOAhi2/g4RXg="

client :: Client -> Server -> M ()
client clnt@Client {subscriptions, ntfSubscriptions, rcvQ, sndQ, sessionId} Server {subscribedQ, ntfSubscribedQ, notifiers} = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " commands"
  forever $
    atomically' (readTBQueue rcvQ)
      >>= mapM processCommand
      >>= atomically' . writeTBQueue sndQ
  where
    processCommand :: (Maybe QueueRec, Transmission Cmd) -> M (Transmission BrokerMsg)
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
        createQueue :: QueueStore -> RcvPublicAuthKey -> RcvPublicDhKey -> SubscriptionMode -> M (Transmission BrokerMsg)
        createQueue st recipientKey dhKey subMode = time "NEW" $ do
          (rcvPublicDhKey, privDhKey) <- atomically . C.generateKeyPair =<< asks random
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
              Int -> ((RecipientId, SenderId) -> QueueIdsKeys) -> ((RecipientId, SenderId) -> QueueRec) -> M BrokerMsg
            addQueueRetry 0 _ _ = pure $ ERR INTERNAL
            addQueueRetry n qik qRec = do
              ids@(rId, _) <- getIds
              -- create QueueRec record with these ids and keys
              let qr = qRec ids
              atomically' (addQueue st qr) >>= \case
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
              atomically' (getQueue st SRecipient rId) >>= \case
                Right q -> logCreateQueue s q
                _ -> pure ()

            getIds :: M (RecipientId, SenderId)
            getIds = do
              n <- asks $ queueIdBytes . config
              liftM2 (,) (randomId n) (randomId n)

        secureQueue_ :: QueueStore -> SndPublicAuthKey -> M (Transmission BrokerMsg)
        secureQueue_ st sKey = time "KEY" $ do
          withLog $ \s -> logSecureQueue s queueId sKey
          stats <- asks serverStats
          atomically $ modifyTVar' (qSecured stats) (+ 1)
          atomically' $ (corrId,queueId,) . either ERR (const OK) <$> secureQueue st queueId sKey

        addQueueNotifier_ :: QueueStore -> NtfPublicAuthKey -> RcvNtfPublicDhKey -> M (Transmission BrokerMsg)
        addQueueNotifier_ st notifierKey dhKey = time "NKEY" $ do
          (rcvPublicDhKey, privDhKey) <- atomically . C.generateKeyPair =<< asks random
          let rcvNtfDhSecret = C.dh' dhKey privDhKey
          (corrId,queueId,) <$> addNotifierRetry 3 rcvPublicDhKey rcvNtfDhSecret
          where
            addNotifierRetry :: Int -> RcvNtfPublicDhKey -> RcvNtfDhSecret -> M BrokerMsg
            addNotifierRetry 0 _ _ = pure $ ERR INTERNAL
            addNotifierRetry n rcvPublicDhKey rcvNtfDhSecret = do
              notifierId <- randomId =<< asks (queueIdBytes . config)
              let ntfCreds = NtfCreds {notifierId, notifierKey, rcvNtfDhSecret}
              atomically' (addQueueNotifier st queueId ntfCreds) >>= \case
                Left DUPLICATE_ -> addNotifierRetry (n - 1) rcvPublicDhKey rcvNtfDhSecret
                Left e -> pure $ ERR e
                Right _ -> do
                  withLog $ \s -> logAddNotifier s queueId ntfCreds
                  pure $ NID notifierId rcvPublicDhKey

        deleteQueueNotifier_ :: QueueStore -> M (Transmission BrokerMsg)
        deleteQueueNotifier_ st = do
          withLog (`logDeleteNotifier` queueId)
          okResp <$> atomically' (deleteQueueNotifier st queueId)

        suspendQueue_ :: QueueStore -> M (Transmission BrokerMsg)
        suspendQueue_ st = do
          withLog (`logSuspendQueue` queueId)
          okResp <$> atomically' (suspendQueue st queueId)

        subscribeQueue :: QueueRec -> RecipientId -> M (Transmission BrokerMsg)
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
                  atomically' (tryTakeTMVar $ delivered s) >> deliver sub
          where
            newSub :: M (TVar Sub)
            newSub = time "SUB newSub" . atomically' $ do
              writeTQueue subscribedQ (rId, clnt)
              sub <- newTVar =<< newSubscription NoSub
              TM.insert rId sub subscriptions
              pure sub
            deliver :: TVar Sub -> M (Transmission BrokerMsg)
            deliver sub = do
              q <- getStoreMsgQueue "SUB" rId
              msg_ <- atomically' $ tryPeekMsg q
              deliverMessage "SUB" qr rId sub q msg_

        getMessage :: QueueRec -> M (Transmission BrokerMsg)
        getMessage qr = time "GET" $ do
          atomically (TM.lookup queueId subscriptions) >>= \case
            Nothing ->
              atomically newSub >>= getMessage_
            Just sub ->
              readTVarIO sub >>= \case
                s@Sub {subThread = ProhibitSub} ->
                  atomically' (tryTakeTMVar $ delivered s)
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
            getMessage_ :: Sub -> M (Transmission BrokerMsg)
            getMessage_ s = do
              q <- getStoreMsgQueue "GET" queueId
              atomically' $
                tryPeekMsg q >>= \case
                  Just msg ->
                    let encMsg = encryptMsg qr msg
                     in setDelivered s msg $> (corrId, queueId, MSG encMsg)
                  _ -> pure (corrId, queueId, OK)

        withQueue :: (QueueRec -> M (Transmission BrokerMsg)) -> M (Transmission BrokerMsg)
        withQueue action = maybe (pure $ err AUTH) action qr_

        subscribeNotifications :: M (Transmission BrokerMsg)
        subscribeNotifications = time "NSUB" . atomically' $ do
          unlessM (TM.member queueId ntfSubscriptions) $ do
            writeTQueue ntfSubscribedQ (queueId, clnt)
            TM.insert queueId () ntfSubscriptions
          pure ok

        acknowledgeMsg :: QueueRec -> MsgId -> M (Transmission BrokerMsg)
        acknowledgeMsg qr msgId = time "ACK" $ do
          atomically (TM.lookup queueId subscriptions) >>= \case
            Nothing -> pure $ err NO_MSG
            Just sub ->
              atomically' (getDelivered sub) >>= \case
                Just s -> do
                  q <- getStoreMsgQueue "ACK" queueId
                  case s of
                    Sub {subThread = ProhibitSub} -> do
                      deletedMsg_ <- atomically' $ tryDelMsg q msgId
                      mapM_ updateStats deletedMsg_
                      pure ok
                    _ -> do
                      (deletedMsg_, msg_) <- atomically' $ tryDelPeekMsg q msgId
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
            updateStats :: Message -> M ()
            updateStats = \case
              MessageQuota {} -> pure ()
              Message {msgFlags} -> do
                stats <- asks serverStats
                atomically $ modifyTVar' (msgRecv stats) (+ 1)
                atomically $ modifyTVar' (msgCount stats) (subtract 1)
                atomically' $ updatePeriodStats (activeQueues stats) queueId
                when (notification msgFlags) $ do
                  atomically $ modifyTVar' (msgRecvNtf stats) (+ 1)
                  atomically' $ updatePeriodStats (activeQueuesNtf stats) queueId

        sendMessage :: QueueRec -> MsgFlags -> MsgBody -> M (Transmission BrokerMsg)
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
                      atomically' . writeMsg q =<< mkMessage body
                    case msg_ of
                      Nothing -> pure $ err QUOTA
                      Just msg -> time "SEND ok" $ do
                        stats <- asks serverStats
                        when (notification msgFlags) $ do
                          atomically' . trySendNotification msg =<< asks random
                          atomically $ modifyTVar' (msgSentNtf stats) (+ 1)
                          atomically' $ updatePeriodStats (activeQueuesNtf stats) (recipientId qr)
                        atomically $ modifyTVar' (msgSent stats) (+ 1)
                        atomically $ modifyTVar' (msgCount stats) (+ 1)
                        atomically' $ updatePeriodStats (activeQueues stats) (recipientId qr)
                        pure ok
          where
            mkMessage :: C.MaxLenBS MaxMessageLen -> M Message
            mkMessage body = do
              msgId <- randomId =<< asks (msgIdBytes . config)
              msgTs <- liftIO getSystemTime
              pure $ Message msgId msgTs msgFlags body

            expireMessages :: MsgQueue -> M ()
            expireMessages q = do
              msgExp <- asks $ messageExpiration . config
              old <- liftIO $ mapM expireBeforeEpoch msgExp
              stats <- asks serverStats
              deleted <- atomically' $ sum <$> mapM (deleteExpiredMsgs q) old
              atomically $ modifyTVar' (msgExpired stats) (+ deleted)

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
              cbNonce <- C.randomCbNonce ntfNonceDrg
              let msgMeta = NMsgMeta {msgId, msgTs}
                  encNMsgMeta = C.cbEncrypt rcvNtfDhSecret cbNonce (smpEncode msgMeta) 128
              pure . (cbNonce,) $ fromRight "" encNMsgMeta

        deliverMessage :: T.Text -> QueueRec -> RecipientId -> TVar Sub -> MsgQueue -> Maybe Message -> M (Transmission BrokerMsg)
        deliverMessage name qr rId sub q msg_ = time (name <> " deliver") $ do
          readTVarIO sub >>= \case
            s@Sub {subThread = NoSub} ->
              case msg_ of
                Just msg ->
                  let encMsg = encryptMsg qr msg
                   in atomically' (setDelivered s msg) $> (corrId, rId, MSG encMsg)
                _ -> forkSub $> ok
            _ -> pure ok
          where
            forkSub :: M ()
            forkSub = do
              atomically' . modifyTVar' sub $ \s -> s {subThread = SubPending}
              t <- mkWeakThreadId =<< forkIO subscriber
              atomically' . modifyTVar' sub $ \case
                s@Sub {subThread = SubPending} -> s {subThread = SubThread t}
                s -> s
              where
                subscriber = do
                  labelMyThread $ B.unpack ("client $" <> encode sessionId) <> " subscriber/" <> T.unpack name
                  msg <- atomically' $ peekMsg q
                  time "subscriber" . atomically' $ do
                    let encMsg = encryptMsg qr msg
                    writeTBQueue sndQ [(CorrId "", rId, MSG encMsg)]
                    s <- readTVar sub
                    void $ setDelivered s msg
                    writeTVar sub $! s {subThread = NoSub}

        time :: T.Text -> M a -> M a
        time name = timed name queueId

        encryptMsg :: QueueRec -> Message -> RcvMessage
        encryptMsg qr msg = encrypt . encodeRcvMsgBody $ case msg of
          Message {msgFlags, msgBody} -> RcvMsgBody {msgTs = msgTs', msgFlags, msgBody}
          MessageQuota {} -> RcvMsgQuota msgTs'
          where
            encrypt :: KnownNat i => C.MaxLenBS i -> RcvMessage
            encrypt body = RcvMessage msgId' . EncRcvMsgBody $ C.cbEncryptMaxLenBS (rcvDhSecret qr) (C.cbNonce msgId') body
            msgId' = messageId msg
            msgTs' = messageTs msg

        setDelivered :: Sub -> Message -> STM Bool
        setDelivered s msg = tryPutTMVar (delivered s) (messageId msg)

        getStoreMsgQueue :: T.Text -> RecipientId -> M MsgQueue
        getStoreMsgQueue name rId = time (name <> " getMsgQueue") $ do
          ms <- asks msgStore
          quota <- asks $ msgQueueQuota . config
          atomically' $ getMsgQueue ms rId quota

        delQueueAndMsgs :: QueueStore -> M (Transmission BrokerMsg)
        delQueueAndMsgs st = do
          withLog (`logDeleteQueue` queueId)
          ms <- asks msgStore
          atomically' (deleteQueue st queueId $>>= \q -> delMsgQueue ms queueId $> Right q) >>= \case
            Right q -> updateDeletedStats q $> ok
            Left e -> pure $ err e

        ok :: Transmission BrokerMsg
        ok = (corrId, queueId, OK)

        err :: ErrorType -> Transmission BrokerMsg
        err e = (corrId, queueId, ERR e)

        okResp :: Either ErrorType () -> Transmission BrokerMsg
        okResp = either err $ const ok

updateDeletedStats :: QueueRec -> M ()
updateDeletedStats q = do
  stats <- asks serverStats
  let delSel = if isNothing (senderKey q) then qDeletedNew else qDeletedSecured
  atomically $ modifyTVar' (delSel stats) (+ 1)
  atomically $ modifyTVar' (qDeletedAll stats) (+ 1)
  atomically $ modifyTVar' (qCount stats) (subtract 1)

withLog :: (StoreLog 'WriteMode -> IO a) -> M ()
withLog action = do
  env <- ask
  liftIO . mapM_ action $ storeLog (env :: Env)

timed :: T.Text -> RecipientId -> M a -> M a
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

randomId :: Int -> M ByteString
randomId n = atomically . C.randomBytes n =<< asks random

saveServerMessages :: Bool -> M ()
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
          atomically' (getMessages ms rId)
            >>= mapM_ (B.hPutStrLn h . strEncode . MLRv3 rId)

restoreServerMessages :: M Int
restoreServerMessages = asks (storeMsgsFile . config) >>= \case
  Just f -> ifM (doesFileExist f) (restoreMessages f) (pure 0)
  Nothing -> pure 0
  where
    restoreMessages f = do
      logInfo $ "restoring messages from file " <> T.pack f
      ms <- asks msgStore
      quota <- asks $ msgQueueQuota . config
      old_ <- asks (messageExpiration . config) $>>= (liftIO . fmap Just . expireBeforeEpoch)
      runExceptT (liftIO (LB.readFile f) >>= foldM (\expired -> restoreMsg expired ms quota old_) 0 . LB.lines) >>= \case
        Left e -> do
          logError . T.pack $ "error restoring messages: " <> e
          liftIO exitFailure
        Right expired -> do
          renameFile f $ f <> ".bak"
          logInfo "messages restored"
          pure expired
      where
        restoreMsg !expired ms quota old_ s' = do
          MLRv3 rId msg <- liftEither . first (msgErr "parsing") $ strDecode s
          addToMsgQueue rId msg
          where
            s = LB.toStrict s'
            addToMsgQueue rId msg = do
              (isExpired, logFull) <- atomically' $ do
                q <- getMsgQueue ms rId quota
                case msg of
                  Message {msgTs}
                    | maybe True (systemSeconds msgTs >=) old_ -> (False,) . isNothing <$> writeMsg q msg
                    | otherwise -> pure (True, False)
                  MessageQuota {} -> writeMsg q msg $> (False, False)
              when logFull . logError . decodeLatin1 $ "message queue " <> strEncode rId <> " is full, message not restored: " <> strEncode (messageId msg)
              pure $ if isExpired then expired + 1 else expired
            msgErr :: Show e => String -> e -> String
            msgErr op e = op <> " error (" <> show e <> "): " <> B.unpack (B.take 100 s)

saveServerStats :: M ()
saveServerStats =
  asks (serverStatsBackupFile . config)
    >>= mapM_ (\f -> asks serverStats >>= atomically' . getServerStatsData >>= liftIO . saveStats f)
  where
    saveStats f stats = do
      logInfo $ "saving server stats to file " <> T.pack f
      B.writeFile f $ strEncode stats
      logInfo "server stats saved"

restoreServerStats :: Int -> M ()
restoreServerStats expiredWhileRestoring = asks (serverStatsBackupFile . config) >>= mapM_ restoreStats
  where
    restoreStats f = whenM (doesFileExist f) $ do
      logInfo $ "restoring server stats from file " <> T.pack f
      liftIO (strDecode <$> B.readFile f) >>= \case
        Right d@ServerStatsData {_qCount = statsQCount} -> do
          s <- asks serverStats
          _qCount <- fmap M.size . readTVarIO . queues =<< asks queueStore
          _msgCount <- foldM (\(!n) q -> (n +) <$> readTVarIO (size q)) 0 =<< readTVarIO =<< asks msgStore
          atomically' $ setServerStats s d {_qCount, _msgCount, _msgExpired = _msgExpired d + expiredWhileRestoring}
          renameFile f $ f <> ".bak"
          logInfo "server stats restored"
          when (_qCount /= statsQCount) $ logWarn $ "Queue count differs: stats: " <> tshow statsQCount <> ", store: " <> tshow _qCount
          logInfo $ "Restored " <> tshow _msgCount <> " messages in " <> tshow _qCount <> " queues"
        Left e -> do
          logInfo $ "error restoring server stats: " <> T.pack e
          liftIO exitFailure
