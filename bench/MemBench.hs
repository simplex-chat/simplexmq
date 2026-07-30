{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

-- | Memory-leak load driver for the SMP server.
--
-- Starts an in-process SMP server (beta.2 code) and hammers a chosen command
-- path in a churn loop, printing GHC live-heap residency (measured after a
-- forced major GC) every checkpoint. A path whose residency climbs with the
-- iteration count is leaking; a flat path is clean.
--
-- Usage: smp-mem-bench <phase> <iterations>
--
-- Single-server phases (server on testPort):
--   plain | svc | svcrace | ntf | conc | svcsubs | getp | stuck | certchurn | link | ntfexp
--   tlsstall | tlshalf | tlschurn | tlspartial  -- TLS/TCP stack
--
-- Two-server phases (proxy on testPort, lagged destination relay on testPort2):
--   proxyfwd | proxytmo | proxychurn | subtmo
--
-- Env: BENCHSTORE selects the store (see srvStoreCfg); SMP_LEAKDIAG_SEC sets the LEAKDIAG
-- interval (defaulted to 10s here). In two-server phases each LEAKDIAG line is tagged with the
-- listening port - "srv=5001" is the proxy, "srv=5002" the relay - because process-wide RTS
-- residency cannot attribute growth to one server.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently_, forConcurrently, forConcurrently_, mapConcurrently_, wait, withAsync)
import Control.Logger.Simple (LogConfig (..), LogLevel (..), setLogLevel, withGlobalLogging)
import qualified Control.Exception as E
import Control.Concurrent.STM
import Control.Monad
import Control.Monad.Trans.Except (ExceptT, runExceptT)
import Crypto.Random (ChaChaDRG)
import qualified Data.ByteString.Char8 as B
import Data.ByteString.Char8 (ByteString)
import Data.Int (Int64)
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..), fromList)
import Data.Maybe (fromMaybe)
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import qualified Data.X509.Validation as XV
import GHC.Stats
import qualified Network.Socket as N
import NetLag (LagTLS, clearLag, setDropEvery, setDropSnd, setLag)
import SMPClient
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.Env.STM (AStoreType (..), ServerConfig (controlPort, controlPortAdminAuth, maxJournalMsgCount, msgQueueQuota, notificationExpiration, serverClientConcurrency))
import Simplex.Messaging.Server.Expiration (ExpirationConfig (..))
import Simplex.Messaging.Server.MsgStore.Types (SMSType (..), SQSType (..))
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Client (TransportClientConfig (..), defaultTransportClientConfig, runTransportClient)
import Simplex.Messaging.Transport.Credentials (genCredentials, tlsCredentials)
import Simplex.Messaging.Version (mkVersionRange)
import System.Environment (getArgs, lookupEnv, setEnv)
import System.IO (BufferMode (..), IOMode (..), hClose, hGetLine, hPutStrLn, hSetBuffering, hSetNewlineMode, universalNewlineMode)
import System.Mem (performMajorGC)
import System.Timeout (timeout)
import Text.Printf (printf)
import Text.Read (readMaybe)

type H = THandleSMP TLS 'TClient

-- store config: PostgreSQL (matches production) when built with -fserver_postgres, else journal
benchCfg :: AServerConfig
#if defined(dbServerPostgres)
benchCfg = cfgMS (ASType SQSPostgres SMSPostgres)
#else
benchCfg = cfg
#endif

-- command helpers (copied from tests/ServerTests.hs) ------------------------

pattern Resp :: CorrId -> QueueId -> BrokerMsg -> Transmission (Either ErrorType BrokerMsg)
pattern Resp corrId queueId command <- (corrId, queueId, Right command)

pattern New :: RcvPublicAuthKey -> RcvPublicDhKey -> Command 'Creator
pattern New rPub dhPub = NEW (NewQueueReq rPub dhPub Nothing SMSubscribe (Just (QRMessaging Nothing)) Nothing)

pattern New0 :: RcvPublicAuthKey -> RcvPublicDhKey -> Command 'Creator
pattern New0 rPub dhPub = NEW (NewQueueReq rPub dhPub Nothing SMOnlyCreate (Just (QRMessaging Nothing)) Nothing)

pattern Ids :: RecipientId -> SenderId -> RcvPublicDhKey -> BrokerMsg
pattern Ids rId sId srvDh <- IDS (QIK rId sId srvDh _sndSecure _linkId Nothing Nothing)

pattern Ids_ :: RecipientId -> SenderId -> RcvPublicDhKey -> ServiceId -> BrokerMsg
pattern Ids_ rId sId srvDh serviceId <- IDS (QIK rId sId srvDh _sndSecure _linkId (Just serviceId) Nothing)

pattern Msg :: MsgId -> MsgBody -> BrokerMsg
pattern Msg msgId body <- MSG RcvMessage {msgId, msgBody = EncRcvMsgBody body}

_SEND :: MsgBody -> Command 'Sender
_SEND = SEND noMsgFlags

_SEND' :: MsgBody -> Command 'Sender
_SEND' = SEND MsgFlags {notification = True}

sendRecv :: forall p. PartyI p => H -> (Maybe TAuthorizations, ByteString, EntityId, Command p) -> IO (Transmission (Either ErrorType BrokerMsg))
sendRecv h@THandle {params} (sgn, corrId, qId, cmd) = do
  let TransmissionForAuth {tToSend} = encodeTransmissionForAuth params (CorrId corrId, qId, cmd)
  Right () <- tPut1 h (sgn, tToSend)
  tGet1 h

signSendRecv :: forall p. PartyI p => H -> C.APrivateAuthKey -> (ByteString, EntityId, Command p) -> IO (Transmission (Either ErrorType BrokerMsg))
signSendRecv h pk t = do
  [r] <- signSendRecv_ h pk Nothing t
  pure r

serviceSignSendRecv :: forall p. PartyI p => H -> C.APrivateAuthKey -> C.PrivateKeyEd25519 -> (ByteString, EntityId, Command p) -> IO (Transmission (Either ErrorType BrokerMsg))
serviceSignSendRecv h pk serviceKey t = do
  [r] <- signSendRecv_ h pk (Just serviceKey) t
  pure r

signSendRecv_ :: forall p. PartyI p => H -> C.APrivateAuthKey -> Maybe C.PrivateKeyEd25519 -> (ByteString, EntityId, Command p) -> IO (NonEmpty (Transmission (Either ErrorType BrokerMsg)))
signSendRecv_ h@THandle {params} (C.APrivateAuthKey a pk) serviceKey_ (corrId, qId, cmd) = do
  let TransmissionForAuth {tForAuth, tToSend} = encodeTransmissionForAuth params (CorrId corrId, qId, cmd)
  Right () <- tPut1 h (authorize tForAuth, tToSend)
  tGetClient h
  where
    authorize t = (,(`C.sign'` t) <$> serviceKey_) <$> case a of
      C.SEd25519 -> Just . TASignature . C.ASignature C.SEd25519 $ C.sign' pk t'
      C.SEd448 -> Just . TASignature . C.ASignature C.SEd448 $ C.sign' pk t'
      C.SX25519 -> (\THAuthClient {peerServerPubKey = k} -> TAAuthenticator $ C.cbAuthenticate k pk (C.cbNonce corrId) t') <$> thAuth params
#if !MIN_VERSION_base(4,18,0)
      _sx448 -> undefined
#endif
      where
        t' = case (serviceKey_, thAuth params >>= clientService) of
          (Just _, Just THClientService {serviceCertHash = XV.Fingerprint fp}) -> fp <> t
          _ -> t

tPut1 :: H -> SentRawTransmission -> IO (Either TransportError ())
tPut1 h t = do
  [r] <- tPut h [Right t]
  pure r

tGet1 :: H -> IO (Transmission (Either ErrorType BrokerMsg))
tGet1 h = do
  [r] <- tGetClient h
  pure r

-- read and discard any pending transmissions until quiet, to resync after a race
drainAll :: H -> IO ()
drainAll h = timeout 40000 (tGet1 h) >>= maybe (pure ()) (const $ drainAll h)

-- measurement ---------------------------------------------------------------

liveBytesMiB :: IO Double
liveBytesMiB = do
  performMajorGC
  s <- getRTSStats
  pure $ fromIntegral (gcdetails_live_bytes (gc s)) / (1024 * 1024)

report :: String -> Int -> Double -> Double -> IO ()
report phase i base cur =
  printf "%-8s iter=%7d  live=%9.1f MiB  delta=%+9.1f MiB  (%+.4f KiB/iter)\n"
    phase i cur (cur - base) (if i == 0 then 0 else (cur - base) * 1024 / fromIntegral i)

withCheckpoints :: String -> Int -> Int -> (Int -> IO ()) -> IO ()
withCheckpoints phase iters cp step = do
  base <- liveBytesMiB
  report phase 0 base base
  forM_ ([1 .. iters] :: [Int]) $ \i -> do
    step i
    when (i `mod` cp == 0) $ liveBytesMiB >>= report phase i base

-- phases --------------------------------------------------------------------

-- regular recipient: create+subscribe, send, receive, ack, delete (churn)
runPlain :: TVar ChaChaDRG -> Int -> Int -> IO ()
runPlain g iters cp =
  testSMPClient @TLS $ \recip ->
    testSMPClient @TLS $ \sndr ->
      withCheckpoints "plain" iters cp $ \i -> do
        (rPub, rKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
        (dhPub, _dhPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
        let corr = B.pack (show i)
        Resp _ _ (Ids rId sId _srvDh) <- signSendRecv recip rKey (corr, NoEntity, New rPub dhPub)
        Resp _ _ OK <- sendRecv sndr (Nothing, corr, sId, _SEND "hello")
        Resp _ _ (Msg mId _) <- tGet1 recip
        Resp _ _ OK <- signSendRecv recip rKey (corr, rId, ACK mId)
        Resp _ _ OK <- signSendRecv recip rKey (corr, rId, DEL)
        pure ()

-- recipient-service: create queue as service, send, service receives, ack, delete (churn)
runSvc :: TVar ChaChaDRG -> Int -> Int -> IO ()
runSvc g iters cp = do
  creds <- genCredentials g Nothing (0, 2400) "localhost"
  let (_fp, tlsCred) = tlsCredentials (creds :| [])
  serviceKeys@(_, servicePK) <- atomically $ C.generateKeyPair g
  testSMPClient @TLS $ \sndr ->
    testSMPServiceClient @TLS (tlsCred, serviceKeys) $ \sh ->
      withCheckpoints "svc" iters cp $ \i -> do
        (rPub, rKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
        (dhPub, _dhPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
        let corr = B.pack (show i)
        Resp _ _ (Ids_ rId sId _srvDh _serviceId) <- serviceSignSendRecv sh rKey servicePK (corr, NoEntity, New rPub dhPub)
        Resp _ _ OK <- sendRecv sndr (Nothing, corr, sId, _SEND "hello")
        Resp _ _ (Msg mId _) <- tGet1 sh
        Resp _ _ OK <- signSendRecv sh rKey (corr, rId, ACK mId)
        Resp _ _ OK <- signSendRecv sh rKey (corr, rId, DEL)
        pure ()

-- recipient-service with concurrent SEND vs DEL to probe the TOCTOU orphan
runSvcRace :: TVar ChaChaDRG -> Int -> Int -> IO ()
runSvcRace g iters cp = do
  creds <- genCredentials g Nothing (0, 2400) "localhost"
  let (_fp, tlsCred) = tlsCredentials (creds :| [])
  serviceKeys@(_, servicePK) <- atomically $ C.generateKeyPair g
  testSMPClient @TLS $ \sndr ->
    testSMPServiceClient @TLS (tlsCred, serviceKeys) $ \sh ->
      withCheckpoints "svcrace" iters cp $ \i -> do
        (rPub, rKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
        (dhPub, _dhPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
        let corr = B.pack (show i)
        Resp _ _ (Ids_ rId sId _srvDh _serviceId) <- serviceSignSendRecv sh rKey servicePK (corr, NoEntity, New rPub dhPub)
        -- race an in-flight SEND (creates delivery Sub) against queue deletion
        concurrently_
          (void $ sendRecv sndr (Nothing, corr, sId, _SEND "hello"))
          (void $ signSendRecv sh rKey (corr, rId, DEL))
        drainAll sh

-- notifications: enable ntf on live queues and send ntf-flagged messages without draining
runNtf :: TVar ChaChaDRG -> Int -> Int -> IO ()
runNtf g iters cp =
  testSMPClient @TLS $ \recip ->
    testSMPClient @TLS $ \sndr ->
      withCheckpoints "ntf" iters cp $ \i -> do
        (rPub, rKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
        (dhPub, _dhPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
        (nPub, _nKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
        (rcvNtfPubDh, _dhNtfPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
        let corr = B.pack (show i)
        Resp _ _ (Ids rId sId _srvDh) <- signSendRecv recip rKey (corr, NoEntity, New rPub dhPub)
        Resp _ _ (NID _nId _) <- signSendRecv recip rKey (corr, rId, NKEY nPub rcvNtfPubDh)
        -- ntf-flagged send stores a notification; no notifier subscribed -> stays in ntfStore
        Resp _ _ OK <- sendRecv sndr (Nothing, corr, sId, _SEND' "hello")
        Resp _ _ (Msg mId _) <- tGet1 recip
        Resp _ _ OK <- signSendRecv recip rKey (corr, rId, ACK mId)
        pure ()

-- reusable steps ------------------------------------------------------------

genKeys :: TVar ChaChaDRG -> IO (RcvPublicAuthKey, C.APrivateAuthKey, RcvPublicDhKey)
genKeys g = do
  (rPub, rKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (dhPub, _dhPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
  pure (rPub, rKey, dhPub)

plainStep :: TVar ChaChaDRG -> H -> H -> Int -> IO ()
plainStep g recip sndr i = do
  (rPub, rKey, dhPub) <- genKeys g
  let corr = B.pack (show i)
  Resp _ _ (Ids rId sId _) <- signSendRecv recip rKey (corr, NoEntity, New rPub dhPub)
  Resp _ _ OK <- sendRecv sndr (Nothing, corr, sId, _SEND "hello")
  Resp _ _ (Msg mId _) <- tGet1 recip
  Resp _ _ OK <- signSendRecv recip rKey (corr, rId, ACK mId)
  Resp _ _ OK <- signSendRecv recip rKey (corr, rId, DEL)
  pure ()

ntfStep :: TVar ChaChaDRG -> H -> H -> Int -> IO ()
ntfStep g recip sndr i = do
  (rPub, rKey, dhPub) <- genKeys g
  (nPub, _nKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (rcvNtfPubDh, _dh :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
  let corr = B.pack (show i)
  Resp _ _ (Ids rId sId _) <- signSendRecv recip rKey (corr, NoEntity, New rPub dhPub)
  Resp _ _ (NID _ _) <- signSendRecv recip rKey (corr, rId, NKEY nPub rcvNtfPubDh)
  Resp _ _ OK <- sendRecv sndr (Nothing, corr, sId, _SEND' "hello")
  Resp _ _ (Msg mId _) <- tGet1 recip
  Resp _ _ OK <- signSendRecv recip rKey (corr, rId, ACK mId)
  Resp _ _ OK <- signSendRecv recip rKey (corr, rId, DEL)
  pure ()

-- concurrency/scale: many client connections running a mixed workload
runConc :: TVar ChaChaDRG -> Int -> Int -> IO ()
runConc g iters _cp = do
  let nW = 8
      per = max 1 (iters `div` nW)
  base <- liveBytesMiB
  report "conc" 0 base base
  counter <- newTVarIO (0 :: Int)
  let target = nW * per
      monitor = do
        threadDelay 2000000
        c <- readTVarIO counter
        cur <- liveBytesMiB
        report "conc" c base cur
        when (c < target) monitor
      worker w =
        testSMPClient @TLS $ \recip ->
          testSMPClient @TLS $ \sndr ->
            forM_ ([1 .. per] :: [Int]) $ \i -> do
              (if i `mod` 3 == 0 then ntfStep else plainStep) g recip sndr (w * per + i)
              atomically $ modifyTVar' counter (+ 1)
  withAsync monitor $ \_ -> mapConcurrently_ worker ([0 .. nW - 1] :: [Int])
  cur <- liveBytesMiB
  report "conc" target base cur

-- service SUBS reconnect: a fixed set of service queues, reconnect+resubscribe each iteration
runSvcSubs :: TVar ChaChaDRG -> Int -> Int -> IO ()
runSvcSubs g iters cp = do
  creds <- genCredentials g Nothing (0, 2400) "localhost"
  let (_fp, tlsCred) = tlsCredentials (creds :| [])
  serviceKeys@(_, servicePK) <- atomically $ C.generateKeyPair g
  let aServicePK = C.APrivateAuthKey C.SEd25519 servicePK
      nQueues = 20
  -- create nQueues associated with the service (persisted in the store)
  (serviceId, rIds) <- testSMPServiceClient @TLS (tlsCred, serviceKeys) $ \sh -> do
    xs <- forM ([1 .. nQueues] :: [Int]) $ \j -> do
      (rPub, rKey, dhPub) <- genKeys g
      Resp _ _ (Ids_ rId _sId _ sid) <- serviceSignSendRecv sh rKey servicePK (B.pack ("c" <> show j), NoEntity, New rPub dhPub)
      pure (rId, sid)
    pure (snd (head xs), map fst xs)
  let idsHash = queueIdsHash rIds
  base <- liveBytesMiB
  report "svcsubs" 0 base base
  -- each iteration: fresh service connection, SUBS to resubscribe all queues, then disconnect
  forM_ ([1 .. iters] :: [Int]) $ \i -> do
    testSMPServiceClient @TLS (tlsCred, serviceKeys) $ \sh ->
      void $ signSendRecv_ sh aServicePK Nothing (B.pack (show i), serviceId, SUBS (fromIntegral nQueues) idsHash)
    when (i `mod` cp == 0) $ liveBytesMiB >>= report "svcsubs" i base

-- GET path: create-only (unsubscribed) queue, send, GET (poll), ack, delete
runGet :: TVar ChaChaDRG -> Int -> Int -> IO ()
runGet g iters cp =
  testSMPClient @TLS $ \recip ->
    testSMPClient @TLS $ \sndr ->
      withCheckpoints "getp" iters cp $ \i -> do
        (rPub, rKey, dhPub) <- genKeys g
        let corr = B.pack (show i)
        Resp _ _ (Ids rId sId _) <- signSendRecv recip rKey (corr, NoEntity, New0 rPub dhPub)
        Resp _ _ OK <- sendRecv sndr (Nothing, corr, sId, _SEND "hello")
        Resp _ _ (Msg mId _) <- signSendRecv recip rKey (corr, rId, GET)
        Resp _ _ OK <- signSendRecv recip rKey (corr, rId, ACK mId)
        Resp _ _ OK <- signSendRecv recip rKey (corr, rId, DEL)
        pure ()

-- forkDeliver blocked in SubPending: a subscriber that never reads its sndQ.
-- Deliveries to a full sndQ fork a deliverThread that blocks forever -> threads/subs_thread grow.
runStuck :: TVar ChaChaDRG -> Int -> Int -> IO ()
runStuck g iters cp =
  testSMPClient @TLS $ \sndr ->
    testSMPClient @TLS $ \recip -> do
      -- phase 1: create + subscribe `iters` queues (recip reads only the IDS responses, no messages yet)
      qs <- forM ([1 .. iters] :: [Int]) $ \i -> do
        (rPub, rKey, dhPub) <- genKeys g
        Resp _ _ (Ids _rId sId _) <- signSendRecv recip rKey (B.pack ('c' : show i), NoEntity, New rPub dhPub)
        pure sId
      -- phase 2: send one message to each; recip never reads -> server delivery threads block on the full sndQ
      base <- liveBytesMiB
      report "stuck" 0 base base
      forM_ (zip ([1 ..] :: [Int]) qs) $ \(i, sId) -> do
        _ <- sendRecv sndr (Nothing, B.pack ('s' : show i), sId, _SEND "x")
        when (i `mod` cp == 0) $ liveBytesMiB >>= report "stuck" i base
      threadDelay 20000000 -- hold the subscriber open so diagnostics can sample the blocked threads

-- serviceLocks + services never evicted: connect as a messaging service with a fresh certificate
-- each iteration. getCreateService (run in the handshake) adds a services row + serviceLocks entry
-- that is never removed -> store_rcvServices grows.
runCertChurn :: TVar ChaChaDRG -> Int -> Int -> IO ()
runCertChurn g iters cp = do
  base <- liveBytesMiB
  report "certchurn" 0 base base
  forM_ ([1 .. iters] :: [Int]) $ \i -> do
    creds <- genCredentials g Nothing (0, 2400) "localhost"
    let (_fp, tlsCred) = tlsCredentials (creds :| [])
    serviceKeys <- atomically $ C.generateKeyPair g
    testSMPServiceClient @TLS (tlsCred, serviceKeys) $ \_sh -> pure ()
    when (i `mod` cp == 0) $ liveBytesMiB >>= report "certchurn" i base

-- LINK path coverage: create a queue with short-link data, update it (LSET), secure it via the
-- link (LKEY), delete the link data (LDEL), delete the queue. Exercises the links map on create
-- and delete. (Not a leak repro: the links-not-removed-on-delete bug only bites useCache=True.)
runLink :: TVar ChaChaDRG -> Int -> Int -> IO ()
runLink g iters cp =
  testSMPClient @TLS $ \r ->
    testSMPClient @TLS $ \s ->
      withCheckpoints "link" iters cp $ \i -> do
        (rPub, rKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
        (dhPub, _dhPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
        (sPub, sKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
        C.CbNonce corrId <- atomically $ C.randomCbNonce g
        let sId = EntityId $ B.take 24 $ C.sha3_384 corrId -- sender ID must be derived from corrId
            ld = (EncDataBytes "fixed data", EncDataBytes "user data")
            qrd = QRMessaging $ Just (sId, ld)
        Resp _ NoEntity (IDS (QIK rId _sId _srvDh _qm (Just lnkId) _svc _ntf)) <-
          signSendRecv r rKey (corrId, NoEntity, NEW (NewQueueReq rPub dhPub Nothing SMSubscribe (Just qrd) Nothing))
        Resp _ _ OK <- signSendRecv r rKey (B.pack ('a' : show i), rId, LSET lnkId ld)
        Resp _ _ (LNK _sId2 _ld') <- signSendRecv s sKey (B.pack ('b' : show i), lnkId, LKEY sPub)
        Resp _ _ OK <- signSendRecv r rKey (B.pack ('c' : show i), rId, LDEL)
        Resp _ _ OK <- signSendRecv r rKey (B.pack ('d' : show i), rId, DEL)
        pure ()

-- Note: the two proxy leaks are NOT reproducible in this load bench and are intentionally not
-- included. The sentCommands/PFWD-timeout leak needs a relay that keeps the session up but drops
-- RFWD (a mock relay). The empty-SessionVar leak is a precise disconnect-during-connect race
-- (reproduced deterministically by the SMPProxyTests unit test, not by a load loop). Both are
-- observable on a live proxy via the LEAKDIAG proxy_sentCommands / proxy_smpClients counters.

-- NtfStore key-retention leak: store notifications in many notifier queues, then let them expire.
-- With the fix, deleteExpiredNtfs removes the emptied outer keys, so LEAKDIAG ntfStore_keys rises
-- during creation then falls to ~0 after expiry; without it, the empty keys are retained.
-- Run with the short-expiry config (see main) so expiry fires within the run.
runNtfExp :: TVar ChaChaDRG -> Int -> Int -> IO ()
runNtfExp g iters _cp =
  testSMPClient @TLS $ \recip ->
    testSMPClient @TLS $ \sndr -> do
      forM_ ([1 .. iters] :: [Int]) $ \i -> do
        (rPub, rKey, dhPub) <- genKeys g
        (nPub, _nKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
        (rcvNtfPubDh, _dh :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
        let corr = B.pack (show i)
        Resp _ _ (Ids rId sId _) <- signSendRecv recip rKey (corr, NoEntity, New0 rPub dhPub)
        Resp _ _ (NID _nId _) <- signSendRecv recip rKey (corr, rId, NKEY nPub rcvNtfPubDh)
        Resp _ _ OK <- sendRecv sndr (Nothing, corr, sId, _SEND' "hi")
        pure ()
      base <- liveBytesMiB
      report "ntfexp" iters base base
      -- hold while notifications expire; LEAKDIAG samples ntfStore_keys over this window
      forM_ ([1 .. 12] :: [Int]) $ \k -> threadDelay 5000000 >> (liveBytesMiB >>= report "ntfexp" (iters * 10 + k) base)

-- two-server topology: proxy + lagged relay ---------------------------------
--
-- The destination relay listens on LagTLS (see bench/NetLag.hs), so proxy->relay latency and
-- response-dropping are controlled from the bench without touching production code. The proxy
-- and all clients use plain TLS - LagTLS is wire-identical, only the local read/write path
-- differs.
--
-- Both servers log LEAKDIAG lines tagged with their listening port ("srv=5001" is the proxy,
-- "srv=5002" the relay), which is how per-server counters are attributed: process-wide RTS
-- residency conflates both servers with the bench clients.

proxySrv :: SMPServer
proxySrv = SMPServer testHost testPort testKeyHash

relaySrv :: SMPServer
relaySrv = SMPServer testHost2 testPort2 testKeyHash

-- an address with nothing listening, for connect-failure churn
deadSrv :: Int -> SMPServer
deadSrv i = SMPServer testHost2 (show (20000 + i)) testKeyHash

withProxyTopology :: Maybe String -> IO a -> IO a
withProxyTopology storeEnv = withProxyTopologyCfg (proxySrvCfg storeEnv) storeEnv

withProxyTopologyCfg :: AServerConfig -> Maybe String -> IO a -> IO a
withProxyTopologyCfg pCfg storeEnv action =
  withSmpServerConfigOn (transport @TLS) pCfg testPort $ \_ ->
    withSmpServerConfigOn (transport @LagTLS) (relaySrvCfg storeEnv) testPort2 $ \_ ->
      threadDelay 250000 >> action

proxySrvCfg :: Maybe String -> AServerConfig
proxySrvCfg = \case
#if defined(dbServerPostgres)
  Just "pgjournal" -> proxyCfgMS (ASType SQSPostgres SMSJournal)
  Just "journal" -> proxyCfgMS (ASType SQSMemory SMSJournal)
  _ -> proxyCfgMS (ASType SQSPostgres SMSPostgres)
#else
  _ -> proxyCfg
#endif

-- second store paths/db, so the relay does not collide with the proxy in one process.
-- Quota is raised (as SMPProxyTests does) so that forwarding under latency is not cut short by
-- QUOTA before the phase has run long enough to show a trend.
relaySrvCfg :: Maybe String -> AServerConfig
relaySrvCfg storeEnv = updateCfg (baseCfg storeEnv) $ \c -> c {msgQueueQuota = 128, maxJournalMsgCount = 256}
  where
    baseCfg = \case
#if defined(dbServerPostgres)
      Just "journal" -> cfgJ2QS SQSMemory
      _ -> cfgJ2QS SQSPostgres
#else
      _ -> cfgJ2
#endif

-- a client connected to the proxy, able to issue PRXY/PFWD
proxyClient :: TVar ChaChaDRG -> Int64 -> IO SMPClient
proxyClient g n = do
  ts <- getCurrentTime
  getProtocolClient g NRMInteractive (n, proxySrv, Nothing) benchClientCfg [] Nothing ts (\_ -> pure ())
    >>= either (fail . show) pure

benchClientCfg :: ProtocolClientConfig SMPVersion
benchClientCfg = defaultSMPClientConfig {serverVRange = mkVersionRange minServerSMPRelayVersion currentClientSMPRelayVersion}

runExceptT' :: Show e => ExceptT e IO a -> IO a
runExceptT' a = runExceptT a >>= either (fail . show) pure

-- a subscribed queue on the destination relay, with everything needed to drain it
data RelayQueue = RelayQueue
  { rqSndId :: SenderId,
    rqRcvId :: RecipientId,
    rqRcvKey :: C.APrivateAuthKey,
    rqClient :: SMPClient,
    rqMsgQ :: TBQueue (ServerTransmissionBatch SMPVersion ErrorType BrokerMsg)
  }

newRelayQueue :: TVar ChaChaDRG -> IO RelayQueue
newRelayQueue g = do
  ts <- getCurrentTime
  rqMsgQ <- newTBQueueIO 4096
  rqClient <-
    getProtocolClient g NRMInteractive (99, relaySrv, Nothing) benchClientCfg [] (Just rqMsgQ) ts (\_ -> pure ())
      >>= either (fail . show) pure
  (rPub, rqRcvKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (rdhPub, _rdhPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
  QIK {sndId = rqSndId, rcvId = rqRcvId} <-
    runExceptT' $ createSMPQueue rqClient NRMInteractive Nothing (rPub, rqRcvKey) rdhPub Nothing SMSubscribe (QRMessaging Nothing) Nothing
  pure RelayQueue {rqSndId, rqRcvId, rqRcvKey, rqClient, rqMsgQ}

-- Receive and ack one delivered message, so a steady-forwarding phase does not hit QUOTA.
-- Bounded: the recipient also talks to the lagged relay, so delivery is delayed by the same
-- lag, and an unbounded wait would hang the high-latency runs.
ackOne :: Int -> RelayQueue -> IO ()
ackOne tmo RelayQueue {rqRcvId, rqRcvKey, rqClient, rqMsgQ} =
  timeout tmo (atomically $ readTBQueue rqMsgQ) >>= \case
    Just (_, _, [(_, STEvent (Right (MSG RcvMessage {msgId})))]) ->
      void $ runExceptT $ ackSMPMessage rqClient rqRcvKey rqRcvId msgId
    _ -> pure ()

-- baseline: steady forwarding through the proxy under moderate latency.
-- proxy_sentCommands (LEAKDIAG srv=5001) should stay flat - every RFWD is answered.
--
-- CONNECTIVITY UNDER LATENCY, swept with BENCHLAG_MS (one way, so a request/response pair costs
-- twice this). Sockets counted from /proc/<pid>/fd while the phase ran:
--
--   lag/way   delivered   sockets   proxy->relay connects   reconnects   timeouts
--   0ms       12/12       8         1                       0            0
--   500ms     10/10       8         1                       0            0
--   5s        6/6         8         1                       0            0
--   16s       4/4         8         1                       0            0
--   40s       0/2         8         1                       0            1
--
-- Nothing accumulates. The socket count is identical whether forwards succeed or time out, the
-- proxy->relay session is opened once and reused throughout, and there are no reconnects at any
-- latency. proxy_smpClients and proxy_smpSessions stay at 1.
--
-- That robustness is exactly what makes Leak 1 unbounded: the session that holds the stuck
-- sentCommands entries never drops, so nothing ever frees them. A connection that failed under
-- latency would at least bound the damage.
--
-- Forwards succeed up to 16s each way and fail at 40s; the governing limit is the 30s RFWD
-- timeout. The exact cutoff is not pinned down, because the lag is applied per read/write cycle
-- on the relay rather than per message, so configured lag does not map exactly onto observed
-- round trip.
runProxyFwd :: TVar ChaChaDRG -> Int -> Int -> IO ()
runProxyFwd g iters cp = do
  rq <- newRelayQueue g
  pc <- proxyClient g 1
  sess <- runExceptT' $ connectSMPProxiedRelay pc NRMInteractive relaySrv Nothing
  -- one-way lag added to every relay read and write, so a request/response cycle costs 2x this.
  -- BENCHLAG_MS overrides it to sweep latency; see the connectivity notes below.
  lagMs <- fromMaybe 50 . (>>= readMaybe) <$> lookupEnv "BENCHLAG_MS"
  printf "proxyfwd: lag=%dms each way (%dms added per request/response)\n" lagMs (2 * lagMs :: Int)
  setLag (lagMs * 1000) (lagMs * 1000)
  ok <- newTVarIO (0 :: Int)
  failed <- newTVarIO (0 :: Int)
  -- Under latency a forward can fail without the phase being broken, so record outcomes
  -- instead of aborting: the point is which latency band still delivers.
  withCheckpoints "proxyfwd" iters cp $ \_i -> do
    runExceptT (proxySMPMessage pc NRMInteractive sess Nothing (rqSndId rq) noMsgFlags "hello") >>= \case
      Right (Right ()) -> atomically (modifyTVar' ok (+ 1)) >> ackOne (4 * lagMs * 1000 + 20000000) rq
      _ -> atomically $ modifyTVar' failed (+ 1)
  clearLag
  (o, f) <- (,) <$> readTVarIO ok <*> readTVarIO failed
  printf "proxyfwd: delivered=%d failed=%d\n" o f

-- HEADLINE REPRO: the relay keeps the session up but stops answering, so every RFWD the proxy
-- forwards times out. getResponse (Client.hs) sets `pending = False` and bumps the error count
-- but never deletes from `sentCommands` - the only removal is in processMsg when a response
-- actually arrives. Each stuck entry retains its RFWD command payload (EncFwdTransmission,
-- paddedProxiedTLength = 16226 bytes), and the session is never torn down because dropping the
-- client needs timeoutErrorCount >= smpPingCount AND 15 minutes of total silence, while the
-- proxy (party SSender) never pings.
--
-- Expect LEAKDIAG srv=5001 proxy_sentCommands to climb by `concurrency` per round and stay
-- there, with residency growing ~20 KiB per stuck command.
--
-- MEASURED, three cases, and only the last one is a real leak:
--
--  1. Relay slow but still replying (proxyfwd BENCHLAG_MS=16000): the late reply deletes the
--     entry, so the counter oscillates 1,0,1,0 and ends at 0. Latency alone does not leak.
--  2. Relay stops replying, then traffic stops (BENCHHOLD_SEC, with or without BENCHDROP_EVERY):
--     counter holds, then goes to 0 at ~20 minutes with a disconnect. monitor (Client.hs:668)
--     exits once timeoutErrorCount >= smpPingCount and nothing has arrived for 900s, and it sits
--     in raceAny_ ... `finally` disconnected (Client.hs:649), so the client is torn down and the
--     map goes with it. Bounded.
--  3. Sustained traffic with some replies dropped (BENCHDROP_EVERY=3, large iters so the phase
--     keeps sending): counter climbs 64,128,...,1280 over 20 minutes, linear, zero disconnects.
--     Received transmissions keep resetting lastReceived and timeoutErrorCount, so the drop
--     condition is never reached. Unbounded.
runProxyTmo :: TVar ChaChaDRG -> Int -> Int -> IO ()
runProxyTmo g iters _cp = do
  rq <- newRelayQueue g
  -- establish the proxy->relay session and prove it works before breaking it
  pcs <- mapM (proxyClient g . fromIntegral) [1 .. nClients]
  sess <- runExceptT' $ connectSMPProxiedRelay (head pcs) NRMInteractive relaySrv Nothing
  -- prove forwarding works before breaking it, so a setup failure cannot masquerade as the leak
  runExceptT (proxySMPMessage (head pcs) NRMInteractive sess Nothing (rqSndId rq) noMsgFlags "warmup") >>= \case
    Right (Right ()) -> pure ()
    r -> fail $ "proxytmo: warmup forward failed, topology is broken: " <> show r
  base <- liveBytesMiB
  report "proxytmo" 0 base base
  -- BENCHDROP_EVERY=n drops only every nth relay write instead of all of them. The replies that
  -- do get through reset timeoutErrorCount and lastReceived on the proxy's client, so monitor
  -- never reaches its drop condition and the session stays healthy while the unanswered
  -- commands accumulate. This is the unbounded case; dropping everything is not.
  dropEvery <- fromMaybe 0 . (>>= readMaybe) <$> lookupEnv "BENCHDROP_EVERY"
  if dropEvery > 0 then setDropEvery dropEvery else setDropSnd True
  timeouts <- newTVarIO (0 :: Int)
  let rounds = max 1 (iters `div` batch)
  forM_ ([1 .. rounds] :: [Int]) $ \r -> do
    -- all of these time out together; each leaves one entry in the proxy's sentCommands
    forConcurrently_ ([1 .. batch] :: [Int]) $ \k -> do
      let pc = pcs !! (k `mod` nClients)
      r' <- runExceptT (proxySMPMessage pc NRMInteractive sess Nothing (rqSndId rq) noMsgFlags "stuck")
      -- only a response timeout leaves a stuck sentCommands entry; anything else means the
      -- phase is measuring something other than the leak it claims to reproduce
      case r' of
        Left PCEResponseTimeout -> atomically $ modifyTVar' timeouts (+ 1)
        _ -> pure ()
    n <- readTVarIO timeouts
    cur <- liveBytesMiB
    report "proxytmo" (r * batch) base cur
    -- Measured, not assumed: this stays flat at one batch rather than accumulating. The
    -- bench clients give up at 20s (2 * interactive tcpTimeout) but the proxy still answers
    -- them with PROXY (BROKER TIMEOUT) once its own RFWD expires at 30s, and that late
    -- response deletes their entries in processMsg. Only the proxy->relay side leaks, so
    -- process residency is NOT a doubled count of the payload.
    clientStuck <- sum <$> mapM pClientSentCommandsCount pcs
    printf "proxytmo timeouts=%d of %d attempted, benchClient_sentCommands=%d\n" n (r * batch) clientStuck
  -- BENCHHOLD_SEC keeps the relay silent afterwards to see whether the proxy ever drops the
  -- session and frees the map. monitor (Client.hs:668) exits, and so tears the client down, when
  -- timeoutErrorCount >= smpPingCount and nothing has been received for recoverWindow (900s),
  -- checked on a 600s loop. So a fully silent relay should be dropped at about 20 minutes.
  -- Anything received resets both, which is why a relay that answers selectively is the
  -- unbounded case rather than a silent one.
  holdSec <- fromMaybe 0 . (>>= readMaybe) <$> lookupEnv "BENCHHOLD_SEC"
  when (holdSec > 0) $ do
    printf "proxytmo: holding relay silent for %ds to test session drop\n" (holdSec :: Int)
    forM_ ([1 .. holdSec `div` 60] :: [Int]) $ \m -> do
      threadDelay 60000000
      cur <- liveBytesMiB
      printf "proxytmo: hold +%dmin live=%.1f MiB\n" m cur
  setDropSnd False
  where
    nClients = 8
    batch = 64

-- The batched-subscribe leak, which is how the ntf server is exposed to the same bug as the
-- proxy. subscribeSMPQueues/subscribeSMPQueuesNtfs go through sendBatch, which calls getResponse
-- once per request (Client.hs:1344), so every queue in an unanswered batch leaves its own
-- sentCommands entry. The ntf server batches 1360 at a time (agentSubsBatchSize).
--
-- Measured on a bench-owned client so the count can be read directly with
-- pClientSentCommandsCount, rather than needing a full ntf server and its Postgres store: the
-- code path under test is identical.
runSubTmo :: TVar ChaChaDRG -> Int -> Int -> IO ()
runSubTmo g iters _cp = do
  ts <- getCurrentTime
  rc <-
    getProtocolClient g NRMInteractive (7, relaySrv, Nothing) benchClientCfg [] Nothing ts (\_ -> pure ())
      >>= either (fail . show) pure
  -- create the queues while the relay still answers
  qs <- forM ([1 .. iters] :: [Int]) $ \_ -> do
    (rPub, rKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
    (dhPub, _dh :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
    QIK {rcvId} <- runExceptT' $ createSMPQueue rc NRMInteractive Nothing (rPub, rKey) dhPub Nothing SMOnlyCreate (QRMessaging Nothing) Nothing
    pure (rcvId, rKey)
  before <- pClientSentCommandsCount rc
  base <- liveBytesMiB
  report "subtmo" 0 base base
  setDropSnd True
  rs <- subscribeSMPQueues rc (fromList qs)
  let timedOut = length [() | Left PCEResponseTimeout <- toList rs]
  stuck <- pClientSentCommandsCount rc
  cur <- liveBytesMiB
  report "subtmo" iters base cur
  printf
    "subtmo: queues=%d timedOut=%d sentCommands before=%d after=%d (%+.3f KiB/entry)\n"
    iters
    timedOut
    before
    stuck
    (if stuck > before then (cur - base) * 1024 / fromIntegral (stuck - before) else 0)
  setDropSnd False

-- Bug 4 reachability: forkClient registers the thread in endThreads AFTER forkIO, so an action
-- that finishes before the parent's insert leaves a permanently stale entry. Every ordinary
-- forked command (PFWD, PRXY, RSLV) blocks on the network, and a standalone reproduction of the
-- same registration order showed 0% staleness for any action that blocks even 1ms.
--
-- This phase probed the fast path I expected to reach it: a PFWD whose encBlock is large enough
-- that re-wrapping it as RFWD exceeds blockSize, so sendProtocolCommand_ would return TELargeMsg
-- at Client.hs:1368 without any IO.
--
-- RESULT: that path is NOT reachable. The client's own transmission limit caps encBlock before
-- the server's re-wrap can overflow. Largest block the client will send is ~16270 bytes (16275
-- is rejected by tPut), and at 16270 the proxy still forwards successfully - the relay answers
-- PROXY (PROTOCOL CRYPTO) on the garbage payload, which means the command did full IO. So no
-- size both fits the client and overflows the server. Kept as a boundary check in case block
-- sizes change; BENCHFWD_SZ sets the payload size.
runFastFwd :: TVar ChaChaDRG -> Int -> Int -> IO ()
runFastFwd g iters _cp =
  testSMPClient @TLS $ \h -> do
    (kPub, _kPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
    r <- sendRecv h (Nothing, "prxy", NoEntity, PRXY relaySrv Nothing)
    sessId <- case r of
      Resp _ _ (PKEY sId _ _) -> pure sId
      _ -> fail $ "fastfwd: PRXY did not return PKEY: " <> show r
    -- oversized: the proxy re-wraps this into RFWD, which then exceeds blockSize
    sz <- fromMaybe 16200 . (>>= readMaybe) <$> lookupEnv "BENCHFWD_SZ"
    let big = EncTransmission $ B.replicate sz 'x'
    base <- liveBytesMiB
    report "fastfwd" 0 base base
    oks <- forM ([1 .. iters] :: [Int]) $ \i -> do
      r' <- E.try @E.SomeException $ sendRecv h (Nothing, B.pack ('f' : show i), EntityId sessId, PFWD currentClientSMPRelayVersion kPub big)
      pure $ case r' of
        Right (_, _, Right (ERR e)) -> Right (show e)
        Right (_, _, resp) -> Right (take 40 $ show resp)
        Left e -> Left (take 60 $ show e)
    let sent = length [() | Right _ <- oks]
    printf "fastfwd: size=%d sent=%d clientRejected=%d sample=%s\n" sz sent (iters - sent) (show $ take 1 oks)
    liveBytesMiB >>= report "fastfwd" iters base
    -- hold the connection open so LEAKDIAG can sample this client's endThreads
    threadDelay 20000000

-- Bug 3: serverClientConcurrency is meant to cap concurrent proxied commands per connection,
-- but forkCmd is written `bracket_ wait signal . forkClient clnt label $ action`, which releases
-- the slot as soon as the thread is forked rather than when the work finishes.
--
-- With the cap set to 1 and the relay silent, N concurrent PFWDs on ONE connection would have to
-- serialise if the cap worked: each would hold the slot for the 30s RFWD timeout, and `wait`
-- blocks the client's whole command loop, so command k+1 could not even be read until k finished.
-- Completion times clustered together instead of spread ~30s apart mean the cap does nothing.
runConcLimit :: TVar ChaChaDRG -> Int -> Int -> IO ()
runConcLimit g iters _cp = do
  rq <- newRelayQueue g
  pc <- proxyClient g 1
  sess <- runExceptT' $ connectSMPProxiedRelay pc NRMInteractive relaySrv Nothing
  runExceptT (proxySMPMessage pc NRMInteractive sess Nothing (rqSndId rq) noMsgFlags "warmup") >>= \case
    Right (Right ()) -> pure ()
    r -> fail $ "conclimit: warmup failed, topology broken: " <> show r
  setDropSnd True
  t0 <- getCurrentTime
  ends <- forConcurrently ([1 .. iters] :: [Int]) $ \_ -> do
    _ <- runExceptT (proxySMPMessage pc NRMInteractive sess Nothing (rqSndId rq) noMsgFlags "x")
    getCurrentTime
  setDropSnd False
  let secs = map (\t -> realToFrac (diffUTCTime t t0) :: Double) ends
  printf
    "conclimit: n=%d cap=1 completions first=%.1fs last=%.1fs spread=%.1fs\n"
    iters
    (minimum secs)
    (maximum secs)
    (maximum secs - minimum secs)
  printf "conclimit: serialised would need ~%.0fs; clustered means the cap is not enforced\n" (fromIntegral iters * 30 :: Double)

-- PRXY to many distinct relay addresses that refuse the connection. Each failure stores
-- `Left (err, Just expiry)` in the agent's smpClients map; removal is lazy (only on a later
-- lookup of the same server), so addresses never requested again are retained.
-- Expect LEAKDIAG srv=5001 proxy_smpClients to grow monotonically.
runProxyChurn :: TVar ChaChaDRG -> Int -> Int -> IO ()
runProxyChurn g iters cp = do
  pc <- proxyClient g 1
  withCheckpoints "proxychurn" iters cp $ \i ->
    void $ runExceptT (connectSMPProxiedRelay pc NRMInteractive (deadSrv i) Nothing)

-- Note: the empty-SessionVar leak is NOT covered here. It was fixed in c9ebf72e by the
-- bracketOnError/dropEmptySessVar in Session.hs withGetSessVar', and SMPProxyTests already has
-- deterministic regression tests for it ("reconnects to relay after sender disconnects
-- mid-connection" and "reconnects after a connect is cancelled mid-flight"). A load phase
-- cannot reproduce a fixed race, and an earlier attempt here only measured harness growth.


-- TLS/TCP stack --------------------------------------------------------------

-- These phases hold every connection open at once, so they are bounded by file descriptors
-- rather than by memory. Cap and say so - a silent truncation would read as "20000 connections
-- were fine" when only a fraction were ever opened.
maxHeldConns :: Int
maxHeldConns = 512

heldConns :: String -> Int -> IO Int
heldConns phase iters
  | iters <= maxHeldConns = pure iters
  | otherwise = do
      printf "%s: capping held connections at %d (requested %d) to stay within the fd limit\n" phase maxHeldConns iters
      pure maxHeldConns

-- Query the server control port for socket accounting. Used to check Bug 5 directly rather
-- than inferring it: socketsLeaked = accepted - closed - active, and closeConn removes a
-- connection from `active` before gracefulClose (up to 5s) and before it increments `closed`,
-- so a connection in teardown is counted in neither and shows up as leaked.
cpSockets :: N.ServiceName -> IO [String]
cpSockets port = do
  sock <- rawConnect port
  h <- N.socketToHandle sock ReadWriteMode
  hSetBuffering h LineBuffering
  hSetNewlineMode h universalNewlineMode
  r <- timeout 5000000 $ do
    _ <- hGetLine h -- banner line 1
    _ <- hGetLine h -- banner line 2
    hPutStrLn h "auth bench"
    _ <- hGetLine h
    hPutStrLn h "sockets"
    replicateM 5 (hGetLine h) -- "Sockets for port N:" + accepted/closed/active/leaked
  hClose h `E.catch` \(_ :: E.SomeException) -> pure ()
  pure $ fromMaybe [] r

cpPort :: N.ServiceName
cpPort = "5010"

rawConnect :: N.ServiceName -> IO N.Socket
rawConnect port = do
  let hints = N.defaultHints {N.addrSocketType = N.Stream}
  addr : _ <- N.getAddrInfo (Just hints) (Just "127.0.0.1") (Just port)
  sock <- N.socket (N.addrFamily addr) (N.addrSocketType addr) (N.addrProtocol addr)
  N.connect sock (N.addrAddress addr)
  pure sock

-- Occupancy or leak? Hold `n` connections open at once, measure peak residency, then release
-- them all and measure again once the server has had time to drop its per-connection state.
-- Recovery to baseline means the phase measured the legitimate cost of a held connection; a
-- residency that stays elevated is a leak. Without this second measurement the two are
-- indistinguishable - the first version of these phases reported peak occupancy alone, which
-- reads like a leak and is not one.
holdRelease :: String -> Int -> (IO () -> Int -> IO ()) -> IO ()
holdRelease phase n conn = do
  base <- liveBytesMiB
  report phase 0 base base
  release <- newTVarIO False
  connected <- newTVarIO (0 :: Int)
  let held = do
        atomically $ modifyTVar' connected (+ 1)
        atomically $ readTVar release >>= \r -> unless r retry
  withAsync (forConcurrently_ ([1 .. n] :: [Int]) (conn held)) $ \as -> do
    atomically $ readTVar connected >>= \c -> when (c < n) retry
    peak <- liveBytesMiB
    report phase n base peak
    beforeRel <- cpSockets cpPort
    putStrLn $ phase <> ": sockets before release: " <> unwords (map (dropWhile (== ' ')) beforeRel)
    atomically $ writeTVar release True
    wait as
    -- immediately after n simultaneous teardowns: the widest possible window for the
    -- accounting gap in closeConn (active decremented before closed is incremented)
    afterRel <- cpSockets cpPort
    putStrLn $ phase <> ": sockets right after release: " <> unwords (map (dropWhile (== ' ')) afterRel)
    printf "%s: peak=%.1f MiB (%+.2f KiB/conn)\n" phase peak ((peak - base) * 1024 / fromIntegral n)
    -- Sample recovery repeatedly rather than once. A single early sample cannot tell a leak
    -- from state the server has not reaped yet: the relevant server windows are 60s
    -- (tlsSetupTimeout) and 60s (test smpHandshakeTimeout). Retention that keeps falling is
    -- slow reaping; retention that plateaus above baseline is a leak.
    foldM_
      ( \prev afterSec -> do
          threadDelay $ (afterSec - prev) * 1000000
          cur <- liveBytesMiB
          printf
            "%s: +%3ds recovered=%.1f MiB retained=%+.2f MiB (%+.3f KiB/conn)\n"
            phase
            afterSec
            cur
            (cur - base)
            ((cur - base) * 1024 / fromIntegral n)
          pure afterSec
      )
      (0 :: Int)
      ([5, 25, 60, 120] :: [Int])

-- TCP connections that never send a ClientHello. Each occupies a server thread, an fd and a
-- SocketState entry until tlsSetupTimeout (60s) or until the peer closes.
--
-- RESULT (200 conns): peak 48.2 KiB/conn, 0.31 KiB/conn retained from +25s onwards. Clean.
runTlsStall :: Int -> Int -> IO ()
runTlsStall iters0 _cp = do
  iters <- heldConns "tlsstall" iters0
  holdRelease "tlsstall" iters $ \held _ ->
    E.bracket (rawConnect testPort) N.close $ \_ -> held

-- TLS completes but the SMP handshake never starts: held until smpHandshakeTimeout (60s in the
-- test config) with no Client record ever allocated, so it is invisible to the LEAKDIAG client
-- counters - watch threads and CPSockets instead.
--
-- RESULT (200 conns): peak 203.1 KiB/conn, but 0.71 KiB/conn retained from +25s onwards. Clean.
-- Note the shape of the recovery curve: at +5s it still reads 124.6 KiB/conn, so a single early
-- sample reports this as a 24 MiB leak when it is teardown latency (gracefulClose holds each
-- connection up to 5s). The occupancy is still worth knowing - 200 abandoned half-open
-- connections pin ~40 MiB for ~25s with no authentication required.
runTlsHalf :: Int -> Int -> IO ()
runTlsHalf iters0 _cp = do
  iters <- heldConns "tlshalf" iters0
  holdRelease "tlshalf" iters $ \held _ ->
    runTransportClient tcConfig Nothing (head' testHost) testPort (Just testKeyHash) $
      \(_h :: TLS 'TClient) -> held
  where
    tcConfig = defaultTransportClientConfig {clientALPN = Just alpnSupportedSMPHandshakes} :: TransportClientConfig
    head' (h :| _) = h

-- full connect + SMP handshake + disconnect churn. Exercises the accept path, per-connection
-- TBuffer allocation and the gracefulClose teardown residue.
runTlsChurn :: Int -> Int -> IO ()
runTlsChurn iters cp = do
  base <- liveBytesMiB
  report "tlschurn" 0 base base
  -- sample the server's own socket accounting while churn is in flight, then again once it
  -- has quiesced, to see whether socketsLeaked is a real leak or a teardown artefact
  churning <- newTVarIO True
  let sampler = do
        threadDelay 1500000
        readTVarIO churning >>= \go -> when go $ do
          ls <- cpSockets cpPort
          putStrLn $ "tlschurn: during churn: " <> unwords (map (dropWhile (== ' ')) ls)
          sampler
  withAsync sampler $ \_ -> forM_ ([1 .. iters] :: [Int]) $ \i -> do
      testSMPClient @TLS $ \(_h :: THandleSMP TLS 'TClient) -> pure ()
      when (i `mod` cp == 0) $ liveBytesMiB >>= report "tlschurn" i base
  atomically $ writeTVar churning False
  -- gracefulClose holds each connection up to 5s, so wait past that before the settled sample
  threadDelay 8000000
  ls <- cpSockets cpPort
  putStrLn $ "tlschurn: after settling: " <> unwords (map (dropWhile (== ' ')) ls)

-- post-handshake, send a partial block and idle. The server's transportTimeout is hardcoded
-- Nothing, so its receive thread blocks in cGet indefinitely; only inactive-client expiry
-- (6h by default, and only without subscriptions) would ever reap it.
-- RESULT (200 conns): peak 264.6 KiB/conn, 0.87 KiB/conn retained from +25s onwards. Clean -
-- the server has no read timeout here (transportTimeout is hardcoded Nothing at
-- Transport/Server.hs:104) so it never reaps these itself, but it does release everything
-- promptly once the peer disconnects. The exposure is occupancy while the peer stays connected:
-- a client that completes the SMP handshake and then sends one byte pins ~265 KiB indefinitely,
-- reapable only by inactive-client expiry (6h default, and only for clients with no
-- subscriptions).
runTlsPartial :: Int -> Int -> IO ()
runTlsPartial iters0 _cp = do
  iters <- heldConns "tlspartial" iters0
  holdRelease "tlspartial" iters $ \held _ ->
    testSMPClient @TLS $ \h -> cPut (connection h) "partial" >> held

-- store config selectable via BENCHSTORE env: pgmsg (default, useCache=False) | pgjournal (useCache=True) | journal
srvStoreCfg :: Maybe String -> AServerConfig
srvStoreCfg = \case
#if defined(dbServerPostgres)
  Just "pgjournal" -> cfgMS (ASType SQSPostgres SMSJournal)
  Just "journal" -> cfgMS (ASType SQSMemory SMSJournal)
  _ -> cfgMS (ASType SQSPostgres SMSPostgres)
#else
  _ -> cfg
#endif

main :: IO ()
main = do
  args <- getArgs
  let (phase, iters) = case args of
        (p : n : _) -> (p, read n)
        [p] -> (p, 20000)
        _ -> ("svc", 20000)
      cp = max 1 (iters `div` 20)
  g <- C.newRandom
  storeEnv <- lookupEnv "BENCHSTORE"
  -- ntfexp uses a short notification-expiration so deleteExpiredNtfs fires within the run
  let srvCfg = case phase of
        "ntfexp" -> updateCfg (srvStoreCfg storeEnv) $ \c -> c {notificationExpiration = ExpirationConfig {ttl = 2, checkInterval = 3}}
        -- tlschurn reads the server's own socket counters over the control port
        p | p `elem` (["tlschurn", "tlsstall", "tlshalf", "tlspartial"] :: [String]) ->
              updateCfg (srvStoreCfg storeEnv) $ \c -> c {controlPort = Just cpPort, controlPortAdminAuth = Just "bench"}
        _ -> srvStoreCfg storeEnv
  -- LEAKDIAG counters are the only per-server signal in multi-server topologies, so sample
  -- them often enough to be useful over a bench run
  leakDiagSec <- fromMaybe 10 . (>>= readMaybe) <$> lookupEnv "SMP_LEAKDIAG_SEC"
  setEnv "SMP_LEAKDIAG_SEC" (show leakDiagSec)
  setLogLevel LogInfo
  withGlobalLogging LogConfig {lc_file = Nothing, lc_stderr = True} $
    if phase `elem` proxyPhases
      then
        ( if phase == "conclimit"
            then withProxyTopologyCfg (updateCfg (proxySrvCfg storeEnv) $ \c -> c {serverClientConcurrency = 1}) storeEnv
            else withProxyTopology storeEnv
        )
          $ settle leakDiagSec
          $ case phase of
        "proxyfwd" -> runProxyFwd g iters cp
        "proxytmo" -> runProxyTmo g iters cp
        "proxychurn" -> runProxyChurn g iters cp
        "subtmo" -> runSubTmo g iters cp
        "conclimit" -> runConcLimit g iters cp
        "fastfwd" -> runFastFwd g iters cp
        _ -> error $ "unknown proxy phase: " <> phase
      else withSmpServerConfigOn (transport @TLS) srvCfg testPort $ \_ -> settle leakDiagSec $ do
        threadDelay 250000
        case phase of
          "plain" -> runPlain g iters cp
          "svc" -> runSvc g iters cp
          "svcrace" -> runSvcRace g iters cp
          "ntf" -> runNtf g iters cp
          "conc" -> runConc g iters cp
          "svcsubs" -> runSvcSubs g iters cp
          "getp" -> runGet g iters cp
          "stuck" -> runStuck g iters cp
          "certchurn" -> runCertChurn g iters cp
          "link" -> runLink g iters cp
          "ntfexp" -> runNtfExp g iters cp
          "tlsstall" -> runTlsStall iters cp
          "tlshalf" -> runTlsHalf iters cp
          "tlschurn" -> runTlsChurn iters cp
          "tlspartial" -> runTlsPartial iters cp
          _ -> error $ "unknown phase: " <> phase

proxyPhases :: [String]
proxyPhases = ["proxyfwd", "proxytmo", "proxychurn", "subtmo", "conclimit", "fastfwd"]

-- Hold the servers up past one LEAKDIAG interval after the phase finishes, so the end state is
-- always sampled at least once. Short phases would otherwise exit before any line is emitted,
-- leaving the per-server counters - the only attribution in a two-server topology - unobservable.
settle :: Int -> IO a -> IO a
settle leakDiagSec run = do
  r <- run
  threadDelay $ (leakDiagSec + 2) * 1000000
  pure r
