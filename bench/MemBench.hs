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
--   phases: plain | svc | svcrace | ntf
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently_, mapConcurrently_, withAsync)
import Control.Logger.Simple (LogConfig (..), LogLevel (..), setLogLevel, withGlobalLogging)
import Control.Concurrent.STM
import Control.Monad
import Crypto.Random (ChaChaDRG)
import qualified Data.ByteString.Char8 as B
import Data.ByteString.Char8 (ByteString)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.X509.Validation as XV
import GHC.Stats
import SMPClient
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.Env.STM (AStoreType (..), ServerConfig (notificationExpiration))
import Simplex.Messaging.Server.Expiration (ExpirationConfig (..))
import Simplex.Messaging.Server.MsgStore.Types (SMSType (..), SQSType (..))
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Credentials (genCredentials, tlsCredentials)
import System.Environment (getArgs, lookupEnv)
import System.Mem (performMajorGC)
import System.Timeout (timeout)
import Text.Printf (printf)

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
        _ -> srvStoreCfg storeEnv
  setLogLevel LogInfo
  withGlobalLogging LogConfig {lc_file = Nothing, lc_stderr = True} $
    withSmpServerConfigOn (transport @TLS) srvCfg testPort $ \_ -> do
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
      _ -> error $ "unknown phase: " <> phase
