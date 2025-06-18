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
    importMessages,
    exportMessages,
    printMessageStats,
    disconnectTransport,
    verifyCmdAuthorization,
    dummyVerifyCmd,
    randomId,
    AttachHTTP,
    MessageStats (..),
  )
where

import Control.Concurrent.STM (throwSTM)
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Control.Monad.Trans.Except
import Control.Monad.STM (retry)
import Crypto.Random (ChaChaDRG)
import Data.Bifunctor (first, second)
import Data.ByteString.Base64 (encode)
import qualified Data.ByteString.Builder as BLD
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Constraint (Dict (..))
import Data.Dynamic (toDyn)
import Data.Either (fromRight, partitionEithers)
import Data.Functor (($>))
import Data.IORef
import Data.Int (Int64)
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.List (foldl', intercalate, mapAccumR)
import Data.List.NonEmpty (NonEmpty (..), (<|))
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing)
import Data.Semigroup (Sum (..))
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import qualified Data.Text.IO as T
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.Type.Equality
import Data.Typeable (cast)
import qualified Data.X509 as X
import qualified Data.X509.Validation as XV
import GHC.Conc.Signal
import GHC.IORef (atomicSwapIORef)
import GHC.Stats (getRTSStats)
import GHC.TypeLits (KnownNat)
import Network.Socket (ServiceName, Socket, socketToHandle)
import qualified Network.TLS as TLS
import Numeric.Natural (Natural)
import Simplex.Messaging.Agent.Lock
import Simplex.Messaging.Client (ProtocolClient (thParams), ProtocolClientError (..), SMPClient, SMPClientError, forwardSMPTransmission, smpProxyError, temporaryClientError)
import Simplex.Messaging.Client.Agent (OwnServer, SMPClientAgent (..), SMPClientAgentEvent (..), closeSMPClientAgent, getSMPServerClient'', isOwnServer, lookupSMPServerClient, getConnectedSMPServerClient)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.Control
import Simplex.Messaging.Server.Env.STM as Env
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Server.MsgStore
import Simplex.Messaging.Server.MsgStore.Journal (JournalMsgStore, JournalQueue)
import Simplex.Messaging.Server.MsgStore.STM
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.Server.NtfStore
import Simplex.Messaging.Server.Prometheus
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.QueueInfo
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.Server.Stats
import Simplex.Messaging.Server.StoreLog (foldLogLines)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Buffer (trimCR)
import Simplex.Messaging.Transport.Server
import Simplex.Messaging.Util
import Simplex.Messaging.Version
import System.Environment (lookupEnv)
import System.Exit (exitFailure, exitSuccess)
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
import GHC.Conc (listThreads, threadStatus)
import GHC.Conc.Sync (threadLabel)
#endif

-- | Runs an SMP server using passed configuration.
--
-- See a full server here: https://github.com/simplex-chat/simplexmq/blob/master/apps/smp-server/Main.hs
runSMPServer :: MsgStoreClass s => ServerConfig s -> Maybe AttachHTTP -> IO ()
runSMPServer cfg attachHTTP_ = do
  started <- newEmptyTMVarIO
  runSMPServerBlocking started cfg attachHTTP_

-- | Runs an SMP server using passed configuration with signalling.
--
-- This function uses passed TMVar to signal when the server is ready to accept TCP requests (True)
-- and when it is disconnected from the TCP socket once the server thread is killed (False).
runSMPServerBlocking :: MsgStoreClass s => TMVar Bool -> ServerConfig s -> Maybe AttachHTTP -> IO ()
runSMPServerBlocking started cfg attachHTTP_ = newEnv cfg >>= runReaderT (smpServer started cfg attachHTTP_)

type M s a = ReaderT (Env s) IO a
type AttachHTTP = Socket -> TLS.Context -> IO ()

-- actions used in serverThread to reduce STM transaction scope
data ClientSubAction
  = CSAEndSub QueueId -- end single direct queue subscription
  | CSAEndServiceSub -- end service subscription to one queue
  | CSADecreaseSubs Int64 -- reduce service subscriptions when cancelling. Fixed number is used to correctly handle race conditions when service resubscribes

type PrevClientSub s = (Client s, ClientSubAction, (EntityId, BrokerMsg))

smpServer :: forall s. MsgStoreClass s => TMVar Bool -> ServerConfig s -> Maybe AttachHTTP -> M s ()
smpServer started cfg@ServerConfig {transports, transportConfig = tCfg, startOptions} attachHTTP_ = do
  s <- asks server
  pa <- asks proxyAgent
  msgStats_ <- processServerMessages startOptions
  ntfStats <- restoreServerNtfs
  liftIO $ mapM_ (printMessageStats "messages") msgStats_
  liftIO $ printMessageStats "notifications" ntfStats
  restoreServerStats msgStats_ ntfStats
  when (maintenance startOptions) $ do
    liftIO $ putStrLn "Server started in 'maintenance' mode, exiting"
    stopServer s
    liftIO $ exitSuccess
  raceAny_
    ( serverThread "server subscribers" s subscribers subscriptions serviceSubsCount (Just cancelSub)
        : serverThread "server ntfSubscribers" s ntfSubscribers ntfSubscriptions ntfServiceSubsCount Nothing
        : deliverNtfsThread s
        : sendPendingEvtsThread s
        : receiveFromProxyAgent pa
        : expireNtfsThread cfg
        : sigIntHandlerThread
        : map runServer transports
            <> expireMessagesThread_ cfg
            <> serverStatsThread_ cfg
            <> prometheusMetricsThread_ cfg
            <> controlPortThread_ cfg
    )
    `finally` stopServer s
  where
    runServer :: (ServiceName, ASrvTransport, AddHTTP) -> M s ()
    runServer (tcpPort, ATransport t, addHTTP) = do
      smpCreds@(srvCert, srvKey) <- asks tlsServerCreds
      httpCreds_ <- asks httpServerCreds
      ss <- liftIO newSocketState
      asks sockets >>= atomically . (`modifyTVar'` ((tcpPort, ss) :))
      srvSignKey <- either fail pure $ C.x509ToPrivate' srvKey
      env <- ask
      liftIO $ case (httpCreds_, attachHTTP_) of
        (Just httpCreds, Just attachHTTP) | addHTTP ->
          runTransportServerState_ ss started tcpPort defaultSupportedParamsHTTPS combinedCreds tCfg {serverALPN = Just combinedALPNs} $ \s (sniUsed, h) ->
            case cast h of
              Just (TLS {tlsContext} :: TLS 'TServer) | sniUsed -> labelMyThread "https client" >> attachHTTP s tlsContext
              _ -> runClient srvCert srvSignKey t h `runReaderT` env
          where
            combinedCreds = TLSServerCredential {credential = smpCreds, sniCredential = Just httpCreds}
            combinedALPNs = alpnSupportedSMPHandshakes <> httpALPN
            httpALPN :: [ALPN]
            httpALPN = ["h2", "http/1.1"]
        _ ->
          runTransportServerState ss started tcpPort defaultSupportedParams smpCreds tCfg $ \h -> runClient srvCert srvSignKey t h `runReaderT` env

    sigIntHandlerThread :: M s ()
    sigIntHandlerThread = do
      flagINT <- newEmptyTMVarIO
      let sigINT = 2 -- CONST_SIGINT value
          sigIntAction = \_ptr -> atomically $ void $ tryPutTMVar flagINT ()
          sigIntHandler = Just (sigIntAction, toDyn ())
      void $ liftIO $ setHandler sigINT sigIntHandler
      atomically $ readTMVar flagINT
      logNote "Received SIGINT, stopping server..."

    stopServer :: Server s -> M s ()
    stopServer s = do
      asks serverActive >>= atomically . (`writeTVar` False)
      logNote "Saving server state..."
      withLock' (savingLock s) "final" $ saveServer True >> closeServer
      logNote "Server stopped"

    saveServer :: Bool -> M s ()
    saveServer drainMsgs = do
      ms <- asks msgStore_
      liftIO $ saveServerMessages drainMsgs ms >> closeMsgStore (fromMsgStore ms)
      saveServerNtfs
      saveServerStats

    closeServer :: M s ()
    closeServer = asks (smpAgent . proxyAgent) >>= liftIO . closeSMPClientAgent

    serverThread ::
      forall sub. String ->
      Server s ->
      (Server s -> ServerSubscribers s) ->
      (Client s -> TMap QueueId sub) ->
      (Client s -> TVar Int64) ->
      Maybe (sub -> IO ()) ->
      M s ()
    serverThread label srv srvSubscribers clientSubs clientServiceSubs unsub_ = do
      labelMyThread label
      liftIO . forever $ do
        -- Reading clients outside of `updateSubscribers` transaction to avoid transaction re-evaluation on each new connected client.
        -- In case client disconnects during the transaction (its `connected` property is read),
        -- the transaction will still be re-evaluated, and the client won't be stored as subscribed.
        sub@(_, clntId) <- atomically $ readTQueue subQ
        c_ <- getServerClient clntId srv
        atomically (updateSubscribers c_ sub)
          >>= endPreviousSubscriptions
      where
        ServerSubscribers {subQ, queueSubscribers, serviceSubscribers, totalServiceSubs, subClients, pendingEvents} = srvSubscribers srv
        updateSubscribers :: Maybe (Client s) -> (ClientSub, ClientId) -> STM [PrevClientSub s]
        updateSubscribers c_ (clntSub, clntId) = case c_ of
          Just c@Client {connected} -> ifM (readTVar connected) (updateSubConnected c) updateSubDisconnected
          Nothing -> updateSubDisconnected
          where
            updateSubConnected c = case clntSub of
              CSClient qId prevServiceId serviceId_ -> do
                modifyTVar' subClients $ IS.insert clntId -- add ID to server's subscribed cients
                as'' <- if prevServiceId == serviceId_ then pure [] else endServiceSub prevServiceId qId END
                case serviceId_ of
                  Just serviceId -> do
                    as <- endQueueSub qId END
                    as' <- cancelServiceSubs serviceId =<< upsertSubscribedClient serviceId c serviceSubscribers
                    pure $ as ++ as' ++ as''
                  Nothing -> do
                    as <- prevSub qId END (CSAEndSub qId) =<< upsertSubscribedClient qId c queueSubscribers
                    pure $ as ++ as''
              CSDeleted qId serviceId -> do
                removeWhenNoSubs c
                as <- endQueueSub qId DELD
                as' <- endServiceSub serviceId qId DELD
                pure $ as ++ as'
              CSService serviceId -> do
                modifyTVar' subClients $ IS.insert clntId -- add ID to server's subscribed cients
                cancelServiceSubs serviceId =<< upsertSubscribedClient serviceId c serviceSubscribers
            updateSubDisconnected = case clntSub of
                -- do not insert client if it is already disconnected, but send END/DELD to any other client subscribed to this queue or service
                CSClient qId prevServiceId serviceId -> do
                  as <- endQueueSub qId END
                  as' <- endServiceSub serviceId qId END
                  as'' <- if prevServiceId == serviceId then pure [] else endServiceSub prevServiceId qId END
                  pure $ as ++ as' ++ as''
                CSDeleted qId serviceId -> do
                  as <- endQueueSub qId DELD
                  as' <- endServiceSub serviceId qId DELD
                  pure $ as ++ as'
                CSService serviceId -> cancelServiceSubs serviceId =<< lookupSubscribedClient serviceId serviceSubscribers
            endQueueSub :: QueueId -> BrokerMsg -> STM [PrevClientSub s]
            endQueueSub qId msg = prevSub qId msg (CSAEndSub qId) =<< lookupDeleteSubscribedClient qId queueSubscribers
            endServiceSub :: Maybe ServiceId -> QueueId -> BrokerMsg -> STM [PrevClientSub s]
            endServiceSub Nothing _ _ = pure []
            endServiceSub (Just serviceId) qId msg = prevSub qId msg CSAEndServiceSub =<< lookupSubscribedClient serviceId serviceSubscribers
            prevSub :: QueueId -> BrokerMsg -> ClientSubAction -> Maybe (Client s) -> STM [PrevClientSub s]
            prevSub qId msg action =
              checkAnotherClient $ \c -> pure [(c, action, (qId, msg))]
            cancelServiceSubs :: ServiceId -> Maybe (Client s) -> STM [PrevClientSub s]
            cancelServiceSubs serviceId =
              checkAnotherClient $ \c -> do
                n <- swapTVar (clientServiceSubs c) 0
                pure [(c, CSADecreaseSubs n, (serviceId, ENDS n))]
            checkAnotherClient :: (Client s -> STM [PrevClientSub s]) -> Maybe (Client s) -> STM [PrevClientSub s]
            checkAnotherClient mkSub = \case
              Just c@Client {clientId, connected} | clntId /= clientId ->
                ifM (readTVar connected) (mkSub c) (pure [])
              _ -> pure []

        endPreviousSubscriptions :: [PrevClientSub s] -> IO ()
        endPreviousSubscriptions = mapM_ $ \(c, subAction, evt) -> do
          atomically $ modifyTVar' pendingEvents $ IM.alter (Just . maybe [evt] (evt <|)) (clientId c)
          case subAction of
            CSAEndSub qId -> atomically (endSub c qId) >>= a unsub_
              where
                a (Just unsub) (Just s) = unsub s
                a _ _ = pure ()
            CSAEndServiceSub -> atomically $ do
              modifyTVar' (clientServiceSubs c) decrease
              modifyTVar' totalServiceSubs decrease
              where
                decrease n = max 0 (n - 1)
            -- TODO [certs rcv] for SMP subscriptions CSADecreaseSubs should also remove all delivery threads of the passed client
            CSADecreaseSubs n' -> atomically $ modifyTVar' totalServiceSubs $ \n -> max 0 (n - n')
          where
            endSub :: Client s -> QueueId -> STM (Maybe sub)
            endSub c qId = TM.lookupDelete qId (clientSubs c) >>= (removeWhenNoSubs c $>)
        -- remove client from server's subscribed cients
        removeWhenNoSubs c = do
          noClientSubs <- null <$> readTVar (clientSubs c)
          noServiceSubs <- (0 ==) <$> readTVar (clientServiceSubs c)
          when (noClientSubs && noServiceSubs) $ modifyTVar' subClients $ IS.delete (clientId c)

    deliverNtfsThread :: Server s -> M s ()
    deliverNtfsThread srv@Server {ntfSubscribers = ServerSubscribers {subClients, serviceSubscribers}} = do
      ntfInt <- asks $ ntfDeliveryInterval . config
      ms <- asks msgStore
      ns' <- asks ntfStore
      stats <- asks serverStats
      liftIO $ forever $ do
        threadDelay ntfInt
        runDeliverNtfs ms ns' stats
      where
        runDeliverNtfs :: s -> NtfStore -> ServerStats -> IO ()
        runDeliverNtfs ms (NtfStore ns) stats = do
          ntfs <- M.assocs <$> readTVarIO ns
          unless (null ntfs) $
            getQueueNtfServices @(StoreQueue s) (queueStore ms) ntfs >>= \case
              Left e -> logError $ "NOTIFICATIONS: getQueueNtfServices error " <> tshow e
              Right (sNtfs, deleted) -> do
                forM_ sNtfs $ \(serviceId_, ntfs') -> case serviceId_ of
                  Just sId -> getSubscribedClient sId serviceSubscribers >>= mapM_ (deliverServiceNtfs ntfs')
                  Nothing -> do -- legacy code that does almost the same as before for non-service subscribers
                    cIds <- IS.toList <$> readTVarIO subClients
                    forM_ cIds $ \cId -> getServerClient cId srv >>= mapM_ (deliverQueueNtfs ntfs')
                atomically $ modifyTVar' ns (`M.withoutKeys` S.fromList (map fst deleted))
          where
            deliverQueueNtfs ntfs' c@Client {ntfSubscriptions} =
              whenM (currentClient readTVarIO c) $ do
                subs <- readTVarIO ntfSubscriptions
                unless (M.null subs) $ do
                  let ntfs'' = filter (\(nId, _) -> M.member nId subs) ntfs'
                  tryAny (atomically $ flushSubscribedNtfs ntfs'' c) >>= updateNtfStats c
            deliverServiceNtfs ntfs' cv = readTVarIO cv >>= mapM_ deliver
              where
                deliver c = tryAny (atomically $ withSubscribed $ flushSubscribedNtfs ntfs') >>= updateNtfStats c
                withSubscribed :: (Client s -> STM Int) -> STM Int
                withSubscribed a = readTVar cv >>= maybe (throwSTM $ userError "service unsubscribed") a
            flushSubscribedNtfs :: [(NotifierId, TVar [MsgNtf])] -> Client s' -> STM Int
            flushSubscribedNtfs ntfs c@Client {sndQ} = do
              ts_ <- foldM addNtfs [] ntfs
              forM_ (L.nonEmpty ts_) $ \ts -> do
                let cancelNtfs s = throwSTM $ userError $ s <> ", " <> show (length ts_) <> " ntfs kept"
                unlessM (currentClient readTVar c) $ cancelNtfs "not current client"
                whenM (isFullTBQueue sndQ) $ cancelNtfs "sending queue full"
                writeTBQueue sndQ ts
              pure $ length ts_
            currentClient :: Monad m => (forall a. TVar a -> m a) -> Client s' -> m Bool
            currentClient rd Client {clientId, connected} = (&&) <$> rd connected <*> (IS.member clientId <$> rd subClients)
            addNtfs :: [Transmission BrokerMsg] -> (NotifierId, TVar [MsgNtf]) -> STM [Transmission BrokerMsg]
            addNtfs acc (nId, v) =
              readTVar v >>= \case
                [] -> pure acc
                ntfs -> do
                  writeTVar v []
                  pure $ foldl' (\acc' ntf -> nmsg nId ntf : acc') acc ntfs -- reverses, to order by time
            nmsg nId MsgNtf {ntfNonce, ntfEncMeta} = (CorrId "", nId, NMSG ntfNonce ntfEncMeta)
            updateNtfStats :: Client s' -> Either SomeException Int -> IO ()
            updateNtfStats Client {clientId} = \case
              Right 0 -> pure ()
              Right len -> do
                atomicModifyIORef'_ (ntfCount stats) (subtract len)
                atomicModifyIORef'_ (msgNtfs stats) (+ len)
                atomicModifyIORef'_ (msgNtfsB stats) (+ (len `div` 80 + 1)) -- up to 80 NMSG in the batch
              Left e -> logNote $ "NOTIFICATIONS: cancelled for client #" <> tshow clientId <> ", reason: " <> tshow e

    sendPendingEvtsThread :: Server s -> M s ()
    sendPendingEvtsThread srv@Server {subscribers, ntfSubscribers} = do
      endInt <- asks $ pendingENDInterval . config
      stats <- asks serverStats
      liftIO $ forever $ do
        threadDelay endInt
        sendPending subscribers stats
        sendPending ntfSubscribers stats
      where
        sendPending ServerSubscribers {pendingEvents} stats = do
          pending <- atomically $ swapTVar pendingEvents IM.empty
          unless (null pending) $ forM_ (IM.assocs pending) $ \(cId, evts) ->
            getServerClient cId srv >>= mapM_ (enqueueEvts evts)
          where
            enqueueEvts evts c@Client {connected, sndQ} =
              whenM (readTVarIO connected) $ do
                sent <- atomically $ tryWriteTBQueue sndQ ts
                if sent
                  then updateEndStats
                  else -- if queue is full it can block
                    forkClient c ("sendPendingEvtsThread.queueEvts") $
                      atomically (writeTBQueue sndQ ts) >> updateEndStats
              where
                ts = L.map (\(entId, evt) -> (CorrId "", entId, evt)) evts
                -- this accounts for both END and DELD events
                updateEndStats = do
                  let len = L.length evts
                  when (len > 0) $ do
                    atomicModifyIORef'_ (qSubEnd stats) (+ len)
                    atomicModifyIORef'_ (qSubEndB stats) (+ (len `div` 255 + 1)) -- up to 255 ENDs or DELDs in the batch

    receiveFromProxyAgent :: ProxyAgent -> M s ()
    receiveFromProxyAgent ProxyAgent {smpAgent = SMPClientAgent {agentQ}} =
      forever $
        atomically (readTBQueue agentQ) >>= \case
          CAConnected srv _service_ -> logInfo $ "SMP server connected " <> showServer' srv
          CADisconnected srv qIds -> logError $ "SMP server disconnected " <> showServer' srv <> " / subscriptions: " <> tshow (length qIds)
          -- the errors below should never happen - messaging proxy does not make any subscriptions
          CASubscribed srv serviceId qIds -> logError $ "SMP server subscribed queues " <> asService <> showServer' srv <> " / subscriptions: " <> tshow (length qIds)
            where
              asService = if isJust serviceId then "as service " else ""
          CASubError srv errs -> logError $ "SMP server subscription errors " <> showServer' srv <> " / errors: " <> tshow (length errs)
          CAServiceDisconnected {} -> logError "CAServiceDisconnected"
          CAServiceSubscribed {} -> logError "CAServiceSubscribed"
          CAServiceSubError {} -> logError "CAServiceSubError"
          CAServiceUnavailable {} -> logError "CAServiceUnavailable"
      where
        showServer' = decodeLatin1 . strEncode . host

    expireMessagesThread_ :: ServerConfig s -> [M s ()]
    expireMessagesThread_ ServerConfig {messageExpiration = Just msgExp} = [expireMessagesThread msgExp]
    expireMessagesThread_ _ = []

    expireMessagesThread :: ExpirationConfig -> M s ()
    expireMessagesThread ExpirationConfig {checkInterval, ttl} = do
      ms <- asks msgStore
      let interval = checkInterval * 1000000
      stats <- asks serverStats
      labelMyThread "expireMessagesThread"
      liftIO $ forever $ expire ms stats interval
      where
        expire :: s -> ServerStats -> Int64 -> IO ()
        expire ms stats interval = do
          threadDelay' interval
          logNote "Started expiring messages..."
          n <- compactQueues @(StoreQueue s) $ queueStore ms
          when (n > 0) $ logNote $ "Removed " <> tshow n <> " old deleted queues from the database."
          now <- systemSeconds <$> getSystemTime
          tryAny (expireOldMessages False ms now ttl) >>= \case
            Right msgStats@MessageStats {storedMsgsCount = stored, expiredMsgsCount = expired} -> do
              atomicWriteIORef (msgCount stats) stored
              atomicModifyIORef'_ (msgExpired stats) (+ expired)
              printMessageStats "STORE: messages" msgStats
            Left e -> logError $ "STORE: withAllMsgQueues, error expiring messages, " <> tshow e

    expireNtfsThread :: ServerConfig s -> M s ()
    expireNtfsThread ServerConfig {notificationExpiration = expCfg} = do
      ns <- asks ntfStore
      let interval = checkInterval expCfg * 1000000
      stats <- asks serverStats
      labelMyThread "expireNtfsThread"
      liftIO $ forever $ do
        threadDelay' interval
        old <- expireBeforeEpoch expCfg
        expired <- deleteExpiredNtfs ns old
        when (expired > 0) $ do
          atomicModifyIORef'_ (msgNtfExpired stats) (+ expired)
          atomicModifyIORef'_ (ntfCount stats) (subtract expired)

    serverStatsThread_ :: ServerConfig s -> [M s ()]
    serverStatsThread_ ServerConfig {logStatsInterval = Just interval, logStatsStartTime, serverStatsLogFile} =
      [logServerStats logStatsStartTime interval serverStatsLogFile]
    serverStatsThread_ _ = []

    logServerStats :: Int64 -> Int64 -> FilePath -> M s ()
    logServerStats startAt logInterval statsFilePath = do
      labelMyThread "logServerStats"
      initialDelay <- (startAt -) . fromIntegral . (`div` 1000000_000000) . diffTimeToPicoseconds . utctDayTime <$> liftIO getCurrentTime
      liftIO $ putStrLn $ "server stats log enabled: " <> statsFilePath
      liftIO $ threadDelay' $ 1000000 * (initialDelay + if initialDelay < 0 then 86400 else 0)
      ss@ServerStats {fromTime, qCreated, qSecured, qDeletedAll, qDeletedAllB, qDeletedNew, qDeletedSecured, qSub, qSubAllB, qSubAuth, qSubDuplicate, qSubProhibited, qSubEnd, qSubEndB, ntfCreated, ntfDeleted, ntfDeletedB, ntfSub, ntfSubB, ntfSubAuth, ntfSubDuplicate, msgSent, msgSentAuth, msgSentQuota, msgSentLarge, msgRecv, msgRecvGet, msgGet, msgGetNoMsg, msgGetAuth, msgGetDuplicate, msgGetProhibited, msgExpired, activeQueues, msgSentNtf, msgRecvNtf, activeQueuesNtf, qCount, msgCount, ntfCount, pRelays, pRelaysOwn, pMsgFwds, pMsgFwdsOwn, pMsgFwdsRecv, rcvServices, ntfServices}
        <- asks serverStats
      st <- asks msgStore
      EntityCounts {queueCount, notifierCount, rcvServiceCount, ntfServiceCount, rcvServiceQueuesCount, ntfServiceQueuesCount} <-
        liftIO $ getEntityCounts @(StoreQueue s) $ queueStore st
      let interval = 1000000 * logInterval
      forever $ do
        withFile statsFilePath AppendMode $ \h -> liftIO $ do
          hSetBuffering h LineBuffering
          ts <- getCurrentTime
          fromTime' <- atomicSwapIORef fromTime ts
          qCreated' <- atomicSwapIORef qCreated 0
          qSecured' <- atomicSwapIORef qSecured 0
          qDeletedAll' <- atomicSwapIORef qDeletedAll 0
          qDeletedAllB' <- atomicSwapIORef qDeletedAllB 0
          qDeletedNew' <- atomicSwapIORef qDeletedNew 0
          qDeletedSecured' <- atomicSwapIORef qDeletedSecured 0
          qSub' <- atomicSwapIORef qSub 0
          qSubAllB' <- atomicSwapIORef qSubAllB 0
          qSubAuth' <- atomicSwapIORef qSubAuth 0
          qSubDuplicate' <- atomicSwapIORef qSubDuplicate 0
          qSubProhibited' <- atomicSwapIORef qSubProhibited 0
          qSubEnd' <- atomicSwapIORef qSubEnd 0
          qSubEndB' <- atomicSwapIORef qSubEndB 0
          ntfCreated' <- atomicSwapIORef ntfCreated 0
          ntfDeleted' <- atomicSwapIORef ntfDeleted 0
          ntfDeletedB' <- atomicSwapIORef ntfDeletedB 0
          ntfSub' <- atomicSwapIORef ntfSub 0
          ntfSubB' <- atomicSwapIORef ntfSubB 0
          ntfSubAuth' <- atomicSwapIORef ntfSubAuth 0
          ntfSubDuplicate' <- atomicSwapIORef ntfSubDuplicate 0
          msgSent' <- atomicSwapIORef msgSent 0
          msgSentAuth' <- atomicSwapIORef msgSentAuth 0
          msgSentQuota' <- atomicSwapIORef msgSentQuota 0
          msgSentLarge' <- atomicSwapIORef msgSentLarge 0
          msgRecv' <- atomicSwapIORef msgRecv 0
          msgRecvGet' <- atomicSwapIORef msgRecvGet 0
          msgGet' <- atomicSwapIORef msgGet 0
          msgGetNoMsg' <- atomicSwapIORef msgGetNoMsg 0
          msgGetAuth' <- atomicSwapIORef msgGetAuth 0
          msgGetDuplicate' <- atomicSwapIORef msgGetDuplicate 0
          msgGetProhibited' <- atomicSwapIORef msgGetProhibited 0
          msgExpired' <- atomicSwapIORef msgExpired 0
          ps <- liftIO $ periodStatCounts activeQueues ts
          msgSentNtf' <- atomicSwapIORef msgSentNtf 0
          msgRecvNtf' <- atomicSwapIORef msgRecvNtf 0
          psNtf <- liftIO $ periodStatCounts activeQueuesNtf ts
          msgNtfs' <- atomicSwapIORef (msgNtfs ss) 0
          msgNtfsB' <- atomicSwapIORef (msgNtfsB ss) 0
          msgNtfNoSub' <- atomicSwapIORef (msgNtfNoSub ss) 0
          msgNtfLost' <- atomicSwapIORef (msgNtfLost ss) 0
          msgNtfExpired' <- atomicSwapIORef (msgNtfExpired ss) 0
          pRelays' <- getResetProxyStatsData pRelays
          pRelaysOwn' <- getResetProxyStatsData pRelaysOwn
          pMsgFwds' <- getResetProxyStatsData pMsgFwds
          pMsgFwdsOwn' <- getResetProxyStatsData pMsgFwdsOwn
          pMsgFwdsRecv' <- atomicSwapIORef pMsgFwdsRecv 0
          rcvServices' <- getServiceStatsData rcvServices
          ntfServices' <- getServiceStatsData ntfServices
          qCount' <- readIORef qCount
          msgCount' <- readIORef msgCount
          ntfCount' <- readIORef ntfCount
          T.hPutStrLn h $
            T.intercalate
              ","
              ( [ T.pack $ iso8601Show $ utctDay fromTime',
                  tshow qCreated',
                  tshow qSecured',
                  tshow qDeletedAll',
                  tshow msgSent',
                  tshow msgRecv',
                  dayCount ps,
                  weekCount ps,
                  monthCount ps,
                  tshow msgSentNtf',
                  tshow msgRecvNtf',
                  dayCount psNtf,
                  weekCount psNtf,
                  monthCount psNtf,
                  tshow qCount',
                  tshow msgCount',
                  tshow msgExpired',
                  tshow qDeletedNew',
                  tshow qDeletedSecured'
                ]
                  <> showProxyStats pRelays'
                  <> showProxyStats pRelaysOwn'
                  <> showProxyStats pMsgFwds'
                  <> showProxyStats pMsgFwdsOwn'
                  <> [ tshow pMsgFwdsRecv',
                       tshow qSub',
                       tshow qSubAuth',
                       tshow qSubDuplicate',
                       tshow qSubProhibited',
                       tshow msgSentAuth',
                       tshow msgSentQuota',
                       tshow msgSentLarge',
                       tshow msgNtfs',
                       tshow msgNtfNoSub',
                       tshow msgNtfLost',
                       "0", -- qSubNoMsg' is removed for performance.
                       -- Use qSubAllB for the approximate number of all subscriptions.
                       -- Average observed batch size is 25-30 subscriptions.
                       tshow msgRecvGet',
                       tshow msgGet',
                       tshow msgGetNoMsg',
                       tshow msgGetAuth',
                       tshow msgGetDuplicate',
                       tshow msgGetProhibited',
                       "0", -- dayCount psSub; psSub is removed to reduce memory usage
                       "0", -- weekCount psSub
                       "0", -- monthCount psSub
                       tshow queueCount,
                       tshow ntfCreated',
                       tshow ntfDeleted',
                       tshow ntfSub',
                       tshow ntfSubAuth',
                       tshow ntfSubDuplicate',
                       tshow notifierCount,
                       tshow qDeletedAllB',
                       tshow qSubAllB',
                       tshow qSubEnd',
                       tshow qSubEndB',
                       tshow ntfDeletedB',
                       tshow ntfSubB',
                       tshow msgNtfsB',
                       tshow msgNtfExpired',
                       tshow ntfCount',
                       tshow rcvServiceCount,
                       tshow ntfServiceCount,
                       tshow rcvServiceQueuesCount,
                       tshow ntfServiceQueuesCount
                     ]
                       <> showServiceStats rcvServices'
                       <> showServiceStats ntfServices'
              )
        liftIO $ threadDelay' interval
      where
        showProxyStats ProxyStatsData {_pRequests, _pSuccesses, _pErrorsConnect, _pErrorsCompat, _pErrorsOther} =
          map tshow [_pRequests, _pSuccesses, _pErrorsConnect, _pErrorsCompat, _pErrorsOther]
        showServiceStats ServiceStatsData {_srvAssocNew, _srvAssocDuplicate, _srvAssocUpdated, _srvAssocRemoved, _srvSubCount, _srvSubDuplicate, _srvSubQueues, _srvSubEnd} =
          map tshow [_srvAssocNew, _srvAssocDuplicate, _srvAssocUpdated, _srvAssocRemoved, _srvSubCount, _srvSubDuplicate, _srvSubQueues, _srvSubEnd]

    prometheusMetricsThread_ :: ServerConfig s -> [M s ()]
    prometheusMetricsThread_ ServerConfig {prometheusInterval = Just interval, prometheusMetricsFile} =
      [savePrometheusMetrics interval prometheusMetricsFile]
    prometheusMetricsThread_ _ = []

    savePrometheusMetrics :: Int -> FilePath -> M s ()
    savePrometheusMetrics saveInterval metricsFile = do
      labelMyThread "savePrometheusMetrics"
      liftIO $ putStrLn $ "Prometheus metrics saved every " <> show saveInterval <> " seconds to " <> metricsFile
      st <- asks msgStore
      ss <- asks serverStats
      env <- ask
      rtsOpts <- liftIO $ maybe ("set " <> rtsOptionsEnv) T.pack <$> lookupEnv (T.unpack rtsOptionsEnv)
      let interval = 1000000 * saveInterval
      liftIO $ forever $ do
        threadDelay interval
        ts <- getCurrentTime
        sm <- getServerMetrics st ss rtsOpts
        rtm <- getRealTimeMetrics env
        T.writeFile metricsFile $ prometheusMetrics sm rtm ts

    getServerMetrics :: s -> ServerStats -> Text -> IO ServerMetrics
    getServerMetrics st ss rtsOptions = do
      d <- getServerStatsData ss
      let ps = periodStatDataCounts $ _activeQueues d
          psNtf = periodStatDataCounts $ _activeQueuesNtf d
      entityCounts <- getEntityCounts @(StoreQueue s) $ queueStore st
      pure ServerMetrics {statsData = d, activeQueueCounts = ps, activeNtfCounts = psNtf, entityCounts, rtsOptions}

    getRealTimeMetrics :: Env s -> IO RealTimeMetrics
    getRealTimeMetrics Env {sockets, msgStore_ = ms, server = srv@Server {subscribers, ntfSubscribers}} = do
      socketStats <- mapM (traverse getSocketStats) =<< readTVarIO sockets
#if MIN_VERSION_base(4,18,0)
      threadsCount <- length <$> listThreads
#else
      let threadsCount = 0
#endif
      clientsCount <- IM.size <$> getServerClients srv
      (deliveredSubs, deliveredTimes) <- getDeliveredMetrics =<< getSystemSeconds
      smpSubs <- getSubscribersMetrics subscribers
      ntfSubs <- getSubscribersMetrics ntfSubscribers
      loadedCounts <- loadedQueueCounts $ fromMsgStore ms
      pure RealTimeMetrics {socketStats, threadsCount, clientsCount, deliveredSubs, deliveredTimes, smpSubs, ntfSubs, loadedCounts}
      where
        getSubscribersMetrics ServerSubscribers {queueSubscribers, serviceSubscribers, subClients} = do
          subsCount <- M.size <$> getSubscribedClients queueSubscribers
          subClientsCount <- IS.size <$> readTVarIO subClients
          subServicesCount <- M.size <$> getSubscribedClients serviceSubscribers
          pure RTSubscriberMetrics {subsCount, subClientsCount, subServicesCount}
        getDeliveredMetrics (RoundedSystemTime ts') = foldM countClnt (RTSubscriberMetrics 0 0 0, TimeAggregations 0 0 IM.empty) =<< getServerClients srv
          where
            countClnt acc@(metrics, times) Client {subscriptions} = do
              (cnt, times') <- foldM countSubs (0, times) =<< readTVarIO subscriptions
              pure $ if cnt > 0
                then (metrics {subsCount = subsCount metrics + cnt, subClientsCount = subClientsCount metrics + 1}, times')
                else acc
            countSubs acc@(!cnt, TimeAggregations {sumTime, maxTime, timeBuckets}) Sub {delivered} = do
              delivered_ <- atomically $ tryReadTMVar delivered
              pure $ case delivered_ of
                Nothing -> acc
                Just (_, RoundedSystemTime ts) ->
                  let t = ts' - ts
                      seconds
                        | t <= 5 = fromIntegral t
                        | t <= 30 = t `toBucket` 5
                        | t <= 60 = t `toBucket` 10
                        | t <= 180 = t `toBucket` 30
                        | otherwise = t `toBucket` 60
                      toBucket n m = - fromIntegral (((- n) `div` m) * m) -- round up
                      times' =
                        TimeAggregations
                          { sumTime = sumTime + t,
                            maxTime = max maxTime t,
                            timeBuckets = IM.alter (Just . maybe 1 (+ 1)) seconds timeBuckets
                          }
                   in (cnt + 1, times')

    runClient :: Transport c => X.CertificateChain -> C.APrivateSignKey -> TProxy c 'TServer -> c 'TServer -> M s ()
    runClient srvCert srvSignKey tp h = do
      ms <- asks msgStore
      g <- asks random
      idSize <- asks $ queueIdBytes . config
      kh <- asks serverIdentity
      ks <- atomically . C.generateKeyPair =<< asks random
      ServerConfig {smpServerVRange, smpHandshakeTimeout} <- asks config
      labelMyThread $ "smp handshake for " <> transportName tp
      liftIO (timeout smpHandshakeTimeout . runExceptT $ smpServerHandshake srvCert srvSignKey h ks kh smpServerVRange $ getClientService ms g idSize) >>= \case
        Just (Right th) -> runClientTransport th
        _ -> pure ()

    getClientService :: s -> TVar ChaChaDRG -> Int -> SMPServiceRole -> X.CertificateChain -> XV.Fingerprint -> ExceptT TransportError IO ServiceId
    getClientService ms g idSize role cert fp = do
      newServiceId <- EntityId <$> atomically (C.randomBytes idSize g)
      ts <- liftIO getSystemDate
      let sr = ServiceRec {serviceId = newServiceId, serviceRole = role, serviceCert = cert, serviceCertHash = fp, serviceCreatedAt = ts}
      withExceptT (const $ TEHandshake BAD_SERVICE) $ ExceptT $
        getCreateService @(StoreQueue s) (queueStore ms) sr

    controlPortThread_ :: ServerConfig s -> [M s ()]
    controlPortThread_ ServerConfig {controlPort = Just port} = [runCPServer port]
    controlPortThread_ _ = []

    runCPServer :: ServiceName -> M s ()
    runCPServer port = do
      srv <- asks server
      cpStarted <- newEmptyTMVarIO
      u <- askUnliftIO
      liftIO $ do
        labelMyThread "control port server"
        runLocalTCPServer cpStarted port $ runCPClient u srv
      where
        runCPClient :: UnliftIO (ReaderT (Env s) IO) -> Server s -> Socket -> IO ()
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
                cls <- getServerClients srv
                hPutStrLn h "clientId,sessionId,connected,createdAt,rcvActiveAt,sndActiveAt,age,subscriptions"
                forM_ (IM.toList cls) $ \(cid, Client {clientTHParams = THandleParams {sessionId}, connected, createdAt, rcvActiveAt, sndActiveAt, subscriptions}) -> do
                  connected' <- bshow <$> readTVarIO connected
                  rcvActiveAt' <- strEncode <$> readTVarIO rcvActiveAt
                  sndActiveAt' <- strEncode <$> readTVarIO sndActiveAt
                  now <- liftIO getSystemTime
                  let age = systemSeconds now - systemSeconds createdAt
                  subscriptions' <- bshow . M.size <$> readTVarIO subscriptions
                  hPutStrLn h . B.unpack $ B.intercalate "," [bshow cid, encode sessionId, connected', strEncode createdAt, rcvActiveAt', sndActiveAt', bshow age, subscriptions']
              CPStats -> withUserRole $ do
                ss <- unliftIO u $ asks serverStats
                st <- unliftIO u $ asks msgStore
                EntityCounts {queueCount, notifierCount, rcvServiceCount, ntfServiceCount, rcvServiceQueuesCount, ntfServiceQueuesCount} <-
                  getEntityCounts @(StoreQueue s) $ queueStore st
                let getStat :: (ServerStats -> IORef a) -> IO a
                    getStat var = readIORef (var ss)
                    putStat :: Show a => String -> (ServerStats -> IORef a) -> IO ()
                    putStat label var = getStat var >>= \v -> hPutStrLn h $ label <> ": " <> show v
                    putProxyStat :: String -> (ServerStats -> ProxyStats) -> IO ()
                    putProxyStat label var = do
                      ProxyStatsData {_pRequests, _pSuccesses, _pErrorsConnect, _pErrorsCompat, _pErrorsOther} <- getProxyStatsData $ var ss
                      hPutStrLn h $ label <> ": requests=" <> show _pRequests <> ", successes=" <> show _pSuccesses <> ", errorsConnect=" <> show _pErrorsConnect <> ", errorsCompat=" <> show _pErrorsCompat <> ", errorsOther=" <> show _pErrorsOther
                putStat "fromTime" fromTime
                putStat "qCreated" qCreated
                putStat "qSecured" qSecured
                putStat "qDeletedAll" qDeletedAll
                putStat "qDeletedAllB" qDeletedAllB
                putStat "qDeletedNew" qDeletedNew
                putStat "qDeletedSecured" qDeletedSecured
                getStat (day . activeQueues) >>= \v -> hPutStrLn h $ "daily active queues: " <> show (IS.size v)
                -- removed to reduce memory usage
                -- getStat (day . subscribedQueues) >>= \v -> hPutStrLn h $ "daily subscribed queues: " <> show (S.size v)
                putStat "qSub" qSub
                putStat "qSubAllB" qSubAllB
                putStat "qSubEnd" qSubEnd
                putStat "qSubEndB" qSubEndB
                subs <- (,,) <$> getStat qSubAuth <*> getStat qSubDuplicate <*> getStat qSubProhibited
                hPutStrLn h $ "other SUB events (auth, duplicate, prohibited): " <> show subs
                putStat "msgSent" msgSent
                putStat "msgRecv" msgRecv
                putStat "msgRecvGet" msgRecvGet
                putStat "msgGet" msgGet
                putStat "msgGetNoMsg" msgGetNoMsg
                gets <- (,,) <$> getStat msgGetAuth <*> getStat msgGetDuplicate <*> getStat msgGetProhibited
                hPutStrLn h $ "other GET events (auth, duplicate, prohibited): " <> show gets
                putStat "msgSentNtf" msgSentNtf
                putStat "msgRecvNtf" msgRecvNtf
                putStat "msgNtfs" msgNtfs
                putStat "msgNtfsB" msgNtfsB
                putStat "msgNtfExpired" msgNtfExpired
                putStat "qCount" qCount
                hPutStrLn h $ "qCount 2: " <> show queueCount
                hPutStrLn h $ "notifiers: " <> show notifierCount
                putStat "msgCount" msgCount
                putStat "ntfCount" ntfCount
                readTVarIO role >>= \case
                  CPRAdmin -> do
                    NtfStore ns <- unliftIO u $ asks ntfStore
                    ntfCount2 <- liftIO . foldM (\(!n) q -> (n +) . length <$> readTVarIO q) 0 =<< readTVarIO ns
                    hPutStrLn h $ "ntfCount 2: " <> show ntfCount2
                  _ -> pure ()
                putProxyStat "pRelays" pRelays
                putProxyStat "pRelaysOwn" pRelaysOwn
                putProxyStat "pMsgFwds" pMsgFwds
                putProxyStat "pMsgFwdsOwn" pMsgFwdsOwn
                putStat "pMsgFwdsRecv" pMsgFwdsRecv
                hPutStrLn h $ "rcvServiceCount: " <> show rcvServiceCount
                hPutStrLn h $ "ntfServiceCount: " <> show ntfServiceCount
                hPutStrLn h $ "rcvServiceQueuesCount: " <> show rcvServiceQueuesCount
                hPutStrLn h $ "ntfServiceQueuesCount: " <> show ntfServiceQueuesCount
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
              CPSockets -> withUserRole $ unliftIO u (asks sockets) >>= readTVarIO >>= mapM_ putSockets
                where
                  putSockets (tcpPort, socketsState) = do
                    ss <- getSocketStats socketsState
                    hPutStrLn h $ "Sockets for port " <> tcpPort <> ":"
                    hPutStrLn h $ "accepted: " <> show (socketsAccepted ss)
                    hPutStrLn h $ "closed: " <> show (socketsClosed ss)
                    hPutStrLn h $ "active: " <> show (socketsActive ss)
                    hPutStrLn h $ "leaked: " <> show (socketsLeaked ss)
              CPSocketThreads -> withAdminRole $ do
#if MIN_VERSION_base(4,18,0)
                unliftIO u (asks sockets) >>= readTVarIO >>= mapM_ putSocketThreads
                where
                  putSocketThreads (tcpPort, (_, _, active')) = do
                    active <- readTVarIO active'
                    forM_ (IM.toList active) $ \(sid, tid') ->
                      deRefWeak tid' >>= \case
                        Nothing -> hPutStrLn h $ intercalate "," [tcpPort, show sid, "", "gone", ""]
                        Just tid -> do
                          label <- threadLabel tid
                          status <- threadStatus tid
                          hPutStrLn h $ intercalate "," [tcpPort, show sid, show tid, show status, fromMaybe "" label]
#else
                hPutStrLn h "Not available on GHC 8.10"
#endif
              CPServerInfo -> readTVarIO role >>= \case
                CPRNone -> do
                  logError "Unauthorized control port command"
                  hPutStrLn h "AUTH"
                r -> do
#if MIN_VERSION_base(4,18,0)
                  threads <- liftIO listThreads
                  hPutStrLn h $ "Threads: " <> show (length threads)
#else
                  hPutStrLn h "Threads: not available on GHC 8.10"
#endif
                  let Server {subscribers, ntfSubscribers} = srv
                  activeClients <- getServerClients srv
                  hPutStrLn h $ "Clients: " <> show (IM.size activeClients)
                  when (r == CPRAdmin) $ do
                    clQs <- clientTBQueueLengths' activeClients
                    hPutStrLn h $ "Client queues (rcvQ, sndQ, msgQ): " <> show clQs
                    (smpSubCnt, smpSubCntByGroup, smpClCnt, smpClQs) <- countClientSubs subscriptions (Just countSMPSubs) activeClients
                    hPutStrLn h $ "SMP subscriptions (via clients): " <> show smpSubCnt
                    hPutStrLn h $ "SMP subscriptions (by group: NoSub, SubPending, SubThread, ProhibitSub): " <> show smpSubCntByGroup
                    hPutStrLn h $ "SMP subscribed clients (via clients): " <> show smpClCnt
                    hPutStrLn h $ "SMP subscribed clients queues (via clients, rcvQ, sndQ, msgQ): " <> show smpClQs
                    (ntfSubCnt, _, ntfClCnt, ntfClQs) <- countClientSubs ntfSubscriptions Nothing activeClients
                    hPutStrLn h $ "Ntf subscriptions (via clients): " <> show ntfSubCnt
                    hPutStrLn h $ "Ntf subscribed clients (via clients): " <> show ntfClCnt
                    hPutStrLn h $ "Ntf subscribed clients queues (via clients, rcvQ, sndQ, msgQ): " <> show ntfClQs
                  putSubscribersInfo "SMP" subscribers False
                  putSubscribersInfo "Ntf" ntfSubscribers True
                  where
                    putSubscribersInfo :: String -> ServerSubscribers s -> Bool -> IO ()
                    putSubscribersInfo protoName ServerSubscribers {queueSubscribers, subClients} showIds = do
                      activeSubs <- getSubscribedClients queueSubscribers
                      hPutStrLn h $ protoName <> " subscriptions: " <> show (M.size activeSubs)
                      -- TODO [certs] service subscriptions
                      clnts <- countSubClients activeSubs
                      hPutStrLn h $ protoName <> " subscribed clients: " <> show (IS.size clnts) <> (if showIds then " " <> show (IS.toList clnts) else "")
                      clnts' <- readTVarIO subClients
                      hPutStrLn h $ protoName <> " subscribed clients count 2: " <> show (IS.size clnts') <> (if showIds then " " <> show clnts' else "")
                      where
                        countSubClients :: Map QueueId (TVar (Maybe (Client s))) -> IO IS.IntSet
                        countSubClients = foldM (\ !s c -> maybe s ((`IS.insert` s) . clientId) <$> readTVarIO c) IS.empty
                    countClientSubs :: (Client s -> TMap QueueId a) -> Maybe (Map QueueId a -> IO (Int, Int, Int, Int)) -> IM.IntMap (Client s) -> IO (Int, (Int, Int, Int, Int), Int, (Natural, Natural, Natural))
                    countClientSubs subSel countSubs_ = foldM addSubs (0, (0, 0, 0, 0), 0, (0, 0, 0))
                      where
                        addSubs :: (Int, (Int, Int, Int, Int), Int, (Natural, Natural, Natural)) -> Client s -> IO (Int, (Int, Int, Int, Int), Int, (Natural, Natural, Natural))
                        addSubs (!subCnt, cnts@(!c1, !c2, !c3, !c4), !clCnt, !qs) cl = do
                          subs <- readTVarIO $ subSel cl
                          cnts' <- case countSubs_ of
                            Nothing -> pure cnts
                            Just countSubs -> do
                              (c1', c2', c3', c4') <- countSubs subs
                              pure (c1 + c1', c2 + c2', c3 + c3', c4 + c4')
                          let cnt = M.size subs
                              clCnt' = if cnt == 0 then clCnt else clCnt + 1
                          qs' <- if cnt == 0 then pure qs else addQueueLengths qs cl
                          pure (subCnt + cnt, cnts', clCnt', qs')
                    clientTBQueueLengths' :: Foldable t => t (Client s) -> IO (Natural, Natural, Natural)
                    clientTBQueueLengths' = foldM addQueueLengths (0, 0, 0)
                    addQueueLengths (!rl, !sl, !ml) cl = do
                      (rl', sl', ml') <- queueLengths cl
                      pure (rl + rl', sl + sl', ml + ml')
                    queueLengths Client {rcvQ, sndQ, msgQ} = do
                      rl <- atomically $ lengthTBQueue rcvQ
                      sl <- atomically $ lengthTBQueue sndQ
                      ml <- atomically $ lengthTBQueue msgQ
                      pure (rl, sl, ml)
                    countSMPSubs :: Map QueueId Sub -> IO (Int, Int, Int, Int)
                    countSMPSubs = foldM countSubs (0, 0, 0, 0)
                      where
                        countSubs (c1, c2, c3, c4) Sub {subThread} = case subThread of
                          ServerSub t -> do
                            st <- readTVarIO t
                            pure $ case st of
                              NoSub -> (c1 + 1, c2, c3, c4)
                              SubPending -> (c1, c2 + 1, c3, c4)
                              SubThread _ -> (c1, c2, c3 + 1, c4)
                          ProhibitSub -> pure (c1, c2, c3, c4 + 1)
              CPDelete sId -> withUserRole $ unliftIO u $ do
                st <- asks msgStore
                r <- liftIO $ runExceptT $ do
                  q <- ExceptT $ getQueue st SSender sId
                  ExceptT $ deleteQueueSize st q
                case r of
                  Left e -> liftIO $ hPutStrLn h $ "error: " <> show e
                  Right (qr, numDeleted) -> do
                    updateDeletedStats qr
                    liftIO $ hPutStrLn h $ "ok, " <> show numDeleted <> " messages deleted"
              CPStatus sId -> withUserRole $ unliftIO u $ do
                st <- asks msgStore
                q <- liftIO $ getQueueRec st SSender sId
                liftIO $ hPutStrLn h $ case q of
                  Left e -> "error: " <> show e
                  Right (_, QueueRec {queueMode, status, updatedAt}) ->
                    "status: " <> show status <> ", updatedAt: " <> show updatedAt <> ", queueMode: " <> show queueMode
              CPBlock sId info -> withUserRole $ unliftIO u $ do
                st <- asks msgStore
                r <- liftIO $ runExceptT $ do
                  q <- ExceptT $ getQueue st SSender sId
                  ExceptT $ blockQueue (queueStore st) q info
                case r of
                  Left e -> liftIO $ hPutStrLn h $ "error: " <> show e
                  Right () -> do
                    incStat . qBlocked =<< asks serverStats
                    liftIO $ hPutStrLn h "ok"
              CPUnblock sId -> withUserRole $ unliftIO u $ do
                st <- asks msgStore
                r <- liftIO $ runExceptT $ do
                  q <- ExceptT $ getQueue st SSender sId
                  ExceptT $ unblockQueue (queueStore st) q
                liftIO $ hPutStrLn h $ case r of
                  Left e -> "error: " <> show e
                  Right () -> "ok"
              CPSave -> withAdminRole $ withLock' (savingLock srv) "control" $ do
                hPutStrLn h "saving server state..."
                unliftIO u $ saveServer False
                hPutStrLn h "server state saved!"
              CPHelp -> hPutStrLn h "commands: stats, stats-rts, clients, sockets, socket-threads, threads, server-info, delete, save, help, quit"
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

runClientTransport :: forall c s. (Transport c, MsgStoreClass s) => THandleSMP c 'TServer -> M s ()
runClientTransport h@THandle {params = thParams@THandleParams {sessionId}} = do
  q <- asks $ tbqSize . config
  ts <- liftIO getSystemTime
  nextClientId <- asks clientSeq
  clientId <- atomically $ stateTVar nextClientId $ \next -> (next, next + 1)
  c <- liftIO $ newClient clientId q thParams ts
  runClientThreads c `finally` clientDisconnected c
  where
    runClientThreads :: Client s -> M s ()
    runClientThreads c = do
      s <- asks server
      ms <- asks msgStore
      whenM (liftIO $ insertServerClient c s) $ do
        expCfg <- asks $ inactiveClientExpiration . config
        th <- newMVar h -- put TH under a fair lock to interleave messages and command responses
        labelMyThread . B.unpack $ "client $" <> encode sessionId
        raceAny_ $ [liftIO $ send th c, liftIO $ sendMsg th c, client s ms c, receive h ms c] <> disconnectThread_ c s expCfg
    disconnectThread_ :: Client s -> Server s -> Maybe ExpirationConfig -> [M s ()]
    disconnectThread_ c s (Just expCfg) = [liftIO $ disconnectTransport h (rcvActiveAt c) (sndActiveAt c) expCfg (noSubscriptions c s)]
    disconnectThread_ _ _ _ = []
    noSubscriptions Client {clientId} s =
      not <$> anyM [hasSubs (subscribers s), hasSubs (ntfSubscribers s)]
      where
        hasSubs ServerSubscribers {subClients} = IS.member clientId <$> readTVarIO subClients

clientDisconnected :: forall s. Client s -> M s ()
clientDisconnected c@Client {clientId, subscriptions, ntfSubscriptions, serviceSubsCount, ntfServiceSubsCount, connected, clientTHParams = THandleParams {sessionId, thAuth}, endThreads} = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " disc"
  -- these can be in separate transactions,
  -- because the client already disconnected and they won't change
  atomically $ writeTVar connected False
  subs <- atomically $ swapTVar subscriptions M.empty
  ntfSubs <- atomically $ swapTVar ntfSubscriptions M.empty
  liftIO $ mapM_ cancelSub subs
  whenM (asks serverActive >>= readTVarIO) $ do
    srv@Server {subscribers, ntfSubscribers} <- asks server
    liftIO $ do
      deleteServerClient clientId srv
      updateSubscribers subs subscribers
      updateSubscribers ntfSubs ntfSubscribers
      case peerClientService =<< thAuth of
        Just THClientService {serviceId, serviceRole}
          | serviceRole == SRMessaging -> updateServiceSubs serviceId serviceSubsCount subscribers
          | serviceRole == SRNotifier -> updateServiceSubs serviceId ntfServiceSubsCount ntfSubscribers
        _ -> pure ()
  tIds <- atomically $ swapTVar endThreads IM.empty
  liftIO $ mapM_ (mapM_ killThread <=< deRefWeak) tIds
  where
    updateSubscribers :: Map QueueId a -> ServerSubscribers s -> IO ()
    updateSubscribers subs ServerSubscribers {queueSubscribers, subClients} = do
      mapM_ (\qId -> deleteSubcribedClient qId c queueSubscribers) (M.keys subs)
      atomically $ modifyTVar' subClients $ IS.delete clientId
    updateServiceSubs :: ServiceId -> TVar Int64 -> ServerSubscribers s -> IO ()
    updateServiceSubs serviceId subsCount ServerSubscribers {totalServiceSubs, serviceSubscribers} = do
      deleteSubcribedClient serviceId c serviceSubscribers
      atomically . modifyTVar' totalServiceSubs . subtract =<< readTVarIO subsCount

cancelSub :: Sub -> IO ()
cancelSub s = case subThread s of
  ServerSub st ->
    readTVarIO st >>= \case
      SubThread t -> liftIO $ deRefWeak t >>= mapM_ killThread
      _ -> pure ()
  ProhibitSub -> pure ()

type VerifiedTransmissionOrError s = Either (Transmission BrokerMsg) (VerifiedTransmission s)

receive :: forall c s. (Transport c, MsgStoreClass s) => THandleSMP c 'TServer -> s -> Client s -> M s ()
receive h@THandle {params = THandleParams {thAuth, sessionId}} ms Client {rcvQ, sndQ, rcvActiveAt} = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " receive"
  sa <- asks serverActive
  stats <- asks serverStats
  liftIO $ forever $ do
    ts <- tGetServer h
    unlessM (readTVarIO sa) $ throwIO $ userError "server stopped"
    atomically . (writeTVar rcvActiveAt $!) =<< getSystemTime
    let (es, ts') = partitionEithers $ L.toList ts
        errs = map (second ERR) es
    case ts' of
      (_, _, (_, _, Cmd p cmd)) : rest -> do
        let service = peerClientService =<< thAuth
        (errs', cmds) <- partitionEithers <$> case batchParty p of
          Just Dict | not (null rest) && all (sameParty p) ts'-> do
            updateBatchStats stats cmd -- even if nothing is verified
            let queueId (_, _, (_, qId, _)) = qId
            qs <- getQueueRecs ms p $ map queueId ts'
            zipWithM (\t -> verified stats t . verifyLoadedQueue service thAuth t) ts' qs
          _ -> mapM (\t -> verified stats t =<< verifyTransmission ms service thAuth t) ts'
        write rcvQ cmds
        write sndQ $ errs ++ errs'
      [] -> write sndQ errs
  where
    sameParty :: SParty p -> SignedTransmission Cmd -> Bool
    sameParty p (_, _, (_, _, Cmd p' _)) = isJust $ testEquality p p'
    updateBatchStats :: ServerStats -> Command p -> IO ()
    updateBatchStats stats = \case
      SUB -> incStat $ qSubAllB stats
      DEL -> incStat $ qDeletedAllB stats
      NDEL -> incStat $ ntfDeletedB stats
      NSUB -> incStat $ ntfSubB stats
      _ -> pure ()
    verified :: ServerStats -> SignedTransmission Cmd -> VerificationResult s -> IO (VerifiedTransmissionOrError s)
    verified stats (_, _, t@(corrId, entId, Cmd _ command)) = \case
      VRVerified q -> pure $ Right (q, t)
      VRFailed e -> Left (corrId, entId, ERR e) <$ when (e == AUTH) incAuthStat
        where
          incAuthStat = case command of
            SEND {} -> incStat $ msgSentAuth stats
            SUB -> incStat $ qSubAuth stats
            NSUB -> incStat $ ntfSubAuth stats
            GET -> incStat $ msgGetAuth stats
            _ -> pure ()
    write q = mapM_ (atomically . writeTBQueue q) . L.nonEmpty

send :: Transport c => MVar (THandleSMP c 'TServer) -> Client s -> IO ()
send th c@Client {sndQ, msgQ, clientTHParams = THandleParams {sessionId}} = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " send"
  forever $ atomically (readTBQueue sndQ) >>= sendTransmissions
  where
    sendTransmissions :: NonEmpty (Transmission BrokerMsg) -> IO ()
    sendTransmissions ts
      | L.length ts <= 2 = tSend th c ts
      | otherwise = do
          let (msgs_, ts') = mapAccumR splitMessages [] ts
          -- If the request had batched subscriptions and L.length ts > 2
          -- this will reply OK to all SUBs in the first batched transmission,
          -- to reduce client timeouts.
          tSend th c ts'
          -- After that all messages will be sent in separate transmissions,
          -- without any client response timeouts, and allowing them to interleave
          -- with other requests responses.
          mapM_ (atomically . writeTBQueue msgQ) $ L.nonEmpty msgs_
      where
        splitMessages :: [Transmission BrokerMsg] -> Transmission BrokerMsg -> ([Transmission BrokerMsg], Transmission BrokerMsg)
        splitMessages msgs t@(corrId, entId, cmd) = case cmd of
          -- replace MSG response with OK, accumulating MSG in a separate list.
          MSG {} -> ((CorrId "", entId, cmd) : msgs, (corrId, entId, OK))
          _ -> (msgs, t)

sendMsg :: Transport c => MVar (THandleSMP c 'TServer) -> Client s -> IO ()
sendMsg th c@Client {msgQ, clientTHParams = THandleParams {sessionId}} = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " sendMsg"
  forever $ atomically (readTBQueue msgQ) >>= mapM_ (\t -> tSend th c [t])

tSend :: Transport c => MVar (THandleSMP c 'TServer) -> Client s -> NonEmpty (Transmission BrokerMsg) -> IO ()
tSend th Client {sndActiveAt} ts = do
  withMVar th $ \h@THandle {params} ->
    void . tPut h $ L.map (\t -> Right (Nothing, encodeTransmission params t)) ts
  atomically . (writeTVar sndActiveAt $!) =<< liftIO getSystemTime

disconnectTransport :: Transport c => THandle v c 'TServer -> TVar SystemTime -> TVar SystemTime -> ExpirationConfig -> IO Bool -> IO ()
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

data VerificationResult s = VRVerified (Maybe (StoreQueue s, QueueRec)) | VRFailed ErrorType

-- This function verifies queue command authorization, with the objective to have constant time between the three AUTH error scenarios:
-- - the queue and party key exist, and the provided authorization has type matching queue key, but it is made with the different key.
-- - the queue and party key exist, but the provided authorization has incorrect type.
-- - the queue or party key do not exist.
-- In all cases, the time of the verification should depend only on the provided authorization type,
-- a dummy key is used to run verification in the last two cases, and failure is returned irrespective of the result.
verifyTransmission :: forall s. MsgStoreClass s => s -> Maybe THPeerClientService -> Maybe (THandleAuth 'TServer) -> SignedTransmission Cmd -> IO (VerificationResult s)
verifyTransmission ms service thAuth t@(_, _, (_, queueId, Cmd p _)) = case queueParty p of
  Just Dict -> verifyLoadedQueue service thAuth t <$> getQueueRec ms p queueId
  Nothing -> pure $ verifyQueueTransmission service thAuth t Nothing

verifyLoadedQueue :: Maybe THPeerClientService -> Maybe (THandleAuth 'TServer) -> SignedTransmission Cmd -> Either ErrorType (StoreQueue s, QueueRec) -> VerificationResult s
verifyLoadedQueue service thAuth t@(tAuth, authorized, (corrId, _, _)) = \case
  Right q -> verifyQueueTransmission service thAuth t (Just q)
  Left AUTH -> dummyVerifyCmd thAuth tAuth authorized corrId `seq` VRFailed AUTH
  Left e -> VRFailed e

verifyQueueTransmission :: forall s. Maybe THPeerClientService -> Maybe (THandleAuth 'TServer) -> SignedTransmission Cmd -> Maybe (StoreQueue s, QueueRec) -> VerificationResult s
verifyQueueTransmission service thAuth (tAuth, authorized, (corrId, _, command@(Cmd p cmd))) q_
  | not checkRole = VRFailed $ CMD PROHIBITED
  | not verifyServiceSig = VRFailed SERVICE
  | otherwise = vc p cmd
  where
    vc :: SParty p -> Command p -> VerificationResult s -- this pattern match works with ghc8.10.7, flat case sees it as non-exhastive.
    vc SCreator (NEW NewQueueReq {rcvAuthKey = k}) = verifiedWith k
    vc SRecipient SUB = verifyQueue $ \q -> verifiedWithKeys $ recipientKeys (snd q)
    vc SRecipient _ = verifyQueue $ \q -> verifiedWithKeys $ recipientKeys (snd q)
    vc SRecipientService SUBS = verifyServiceCmd
    vc SSender (SKEY k) = verifySecure k
    -- SEND will be accepted without authorization before the queue is secured with KEY, SKEY or LSKEY command
    vc SSender SEND {} = verifyQueue $ \q -> if maybe (isNothing tAuth) verify (senderKey $ snd q) then VRVerified q_ else VRFailed AUTH
    vc SIdleClient PING = VRVerified Nothing
    vc SSenderLink (LKEY k) = verifySecure k
    vc SSenderLink LGET = verifyQueue $ \q -> if isContactQueue (snd q) then VRVerified q_ else VRFailed AUTH
    vc SNotifier NSUB = verifyQueue $ \q -> maybe dummyVerify (\n -> verifiedWith $ notifierKey n) (notifier $ snd q)
    vc SNotifierService NSUBS = verifyServiceCmd
    vc SProxiedClient _ = VRVerified Nothing
    vc SProxyService (RFWD _) = VRVerified Nothing
    checkRole = case (service, partyClientRole p) of
      (Just THClientService {serviceRole}, Just role) -> serviceRole == role
      _ -> True
    verify = verifyCmdAuthorization thAuth tAuth authorized' corrId
    verifyServiceCmd :: VerificationResult s
    verifyServiceCmd = case (service, tAuth) of
      (Just THClientService {serviceKey = k}, Just (TASignature (C.ASignature C.SEd25519 s), Nothing))
        | C.verify' k s authorized -> VRVerified Nothing
      _ -> VRFailed SERVICE
    -- this function verify service signature for commands that use it in service sessions
    verifyServiceSig
      | useServiceAuth command = case (service, serviceSig) of
          (Just THClientService {serviceKey = k}, Just s) -> C.verify' k s authorized
          (Nothing, Nothing) -> True
          _ -> False
      | otherwise = isNothing serviceSig
    serviceSig = snd =<< tAuth
    authorized' = case (service, serviceSig) of
      (Just THClientService {serviceCertHash = XV.Fingerprint fp}, Just _) -> fp <> authorized
      _ -> authorized
    dummyVerify :: VerificationResult s
    dummyVerify = dummyVerifyCmd thAuth tAuth authorized corrId `seq` VRFailed AUTH
    -- That a specific command requires queue signature verification is determined by `queueParty`,
    -- it should be coordinated with the case in this function (`verifyQueueTransmission`)
    verifyQueue :: ((StoreQueue s, QueueRec) -> VerificationResult s) -> VerificationResult s
    verifyQueue v = maybe (VRFailed INTERNAL) v q_
    verifySecure :: SndPublicAuthKey -> VerificationResult s
    verifySecure k = verifyQueue $ \q -> if k `allowedKey` snd q then verifiedWith k else dummyVerify
    verifiedWith :: C.APublicAuthKey -> VerificationResult s
    verifiedWith k = if verify k then VRVerified q_ else VRFailed AUTH
    verifiedWithKeys :: NonEmpty C.APublicAuthKey -> VerificationResult s
    verifiedWithKeys ks = if any verify ks then VRVerified q_ else VRFailed AUTH
    allowedKey k = \case
      QueueRec {queueMode = Just QMMessaging, senderKey} -> maybe True (k ==) senderKey
      _ -> False

isContactQueue :: QueueRec -> Bool
isContactQueue QueueRec {queueMode, senderKey} = case queueMode of
  Just QMMessaging -> False
  Just QMContact -> True
  Nothing -> isNothing senderKey -- for backward compatibility with pre-SKEY contact addresses

isSecuredMsgQueue :: QueueRec -> Bool
isSecuredMsgQueue QueueRec {queueMode, senderKey} = case queueMode of
  Just QMContact -> False
  _ -> isJust senderKey

-- Random correlation ID is used as a nonce in case crypto_box authenticator is used to authorize transmission
verifyCmdAuthorization :: Maybe (THandleAuth 'TServer) -> Maybe TAuthorizations -> ByteString -> CorrId -> C.APublicAuthKey -> Bool
verifyCmdAuthorization thAuth tAuth authorized corrId key = maybe False (verify key) tAuth
  where
    verify :: C.APublicAuthKey -> TAuthorizations -> Bool
    verify (C.APublicAuthKey a k) = \case
      (TASignature (C.ASignature a' s), _) -> case testEquality a a' of
        Just Refl -> C.verify' k s authorized
        _ -> C.verify' (dummySignKey a') s authorized `seq` False
      (TAAuthenticator s, _) -> case a of
        C.SX25519 -> verifyCmdAuth thAuth k s authorized corrId
        _ -> verifyCmdAuth thAuth dummyKeyX25519 s authorized corrId `seq` False

verifyCmdAuth :: Maybe (THandleAuth 'TServer) -> C.PublicKeyX25519 -> C.CbAuthenticator -> ByteString -> CorrId -> Bool
verifyCmdAuth thAuth k authenticator authorized (CorrId corrId) = case thAuth of
  Just THAuthServer {serverPrivKey = pk} -> C.cbVerify k pk (C.cbNonce corrId) authenticator authorized
  Nothing -> False

dummyVerifyCmd :: Maybe (THandleAuth 'TServer) -> Maybe TAuthorizations -> ByteString -> CorrId -> Bool
dummyVerifyCmd thAuth tAuth authorized corrId = maybe False verify tAuth
  where
    verify = \case
      (TASignature (C.ASignature a s), _) -> C.verify' (dummySignKey a) s authorized
      (TAAuthenticator s, _) -> verifyCmdAuth thAuth dummyKeyX25519 s authorized corrId

-- These dummy keys are used with `dummyVerify` function to mitigate timing attacks
-- by having the same time of the response whether a queue exists or nor, for all valid key/signature sizes
dummySignKey :: C.SignatureAlgorithm a => C.SAlgorithm a -> C.PublicKey a
dummySignKey = \case
  C.SEd25519 -> dummyKeyEd25519
  C.SEd448 -> dummyKeyEd448

dummyKeyEd25519 :: C.PublicKey 'C.Ed25519
dummyKeyEd25519 = "MCowBQYDK2VwAyEA139Oqs4QgpqbAmB0o7rZf6T19ryl7E65k4AYe0kE3Qs="

dummyKeyEd448 :: C.PublicKey 'C.Ed448
dummyKeyEd448 = "MEMwBQYDK2VxAzoA6ibQc9XpkSLtwrf7PLvp81qW/etiumckVFImCMRdftcG/XopbOSaq9qyLhrgJWKOLyNrQPNVvpMA"

dummyKeyX25519 :: C.PublicKey 'C.X25519
dummyKeyX25519 = "MCowBQYDK2VuAyEA4JGSMYht18H4mas/jHeBwfcM7jLwNYJNOAhi2/g4RXg="

forkClient :: MonadUnliftIO m => Client s -> String -> m () -> m ()
forkClient Client {endThreads, endThreadSeq} label action = do
  tId <- atomically $ stateTVar endThreadSeq $ \next -> (next, next + 1)
  t <- forkIO $ do
    labelMyThread label
    action `finally` atomically (modifyTVar' endThreads $ IM.delete tId)
  mkWeakThreadId t >>= atomically . modifyTVar' endThreads . IM.insert tId

client :: forall s. MsgStoreClass s => Server s -> s -> Client s -> M s ()
client
  -- TODO [certs rcv] rcv subscriptions
  Server {subscribers, ntfSubscribers}
  ms
  clnt@Client {clientId, subscriptions, ntfSubscriptions, serviceSubsCount = _todo', ntfServiceSubsCount, rcvQ, sndQ, clientTHParams = thParams'@THandleParams {sessionId}, procThreads} = do
    labelMyThread . B.unpack $ "client $" <> encode sessionId <> " commands"
    let THandleParams {thVersion} = thParams'
        service = peerClientService =<< thAuth thParams'
    forever $
      atomically (readTBQueue rcvQ)
        >>= mapM (processCommand service thVersion)
        >>= mapM_ reply . L.nonEmpty . catMaybes . L.toList
  where
    reply :: MonadIO m => NonEmpty (Transmission BrokerMsg) -> m ()
    reply = atomically . writeTBQueue sndQ
    processProxiedCmd :: Transmission (Command 'ProxiedClient) -> M s (Maybe (Transmission BrokerMsg))
    processProxiedCmd (corrId, EntityId sessId, command) = (corrId,EntityId sessId,) <$$> case command of
      PRXY srv auth -> ifM allowProxy getRelay (pure $ Just $ ERR $ PROXY BASIC_AUTH)
        where
          allowProxy = do
            ServerConfig {allowSMPProxy, newQueueBasicAuth} <- asks config
            pure $ allowSMPProxy && maybe True ((== auth) . Just) newQueueBasicAuth
          getRelay = do
            ProxyAgent {smpAgent = a} <- asks proxyAgent
            liftIO (getConnectedSMPServerClient a srv) >>= \case
              Just r -> Just <$> proxyServerResponse a r
              Nothing ->
                forkProxiedCmd $
                  liftIO (runExceptT (getSMPServerClient'' a srv) `catch` (pure . Left . PCEIOError))
                    >>= proxyServerResponse a
          proxyServerResponse :: SMPClientAgent 'Sender -> Either SMPClientError (OwnServer, SMPClient) -> M s BrokerMsg
          proxyServerResponse a smp_ = do
            ServerStats {pRelays, pRelaysOwn} <- asks serverStats
            let inc = mkIncProxyStats pRelays pRelaysOwn
            case smp_ of
              Right (own, smp) -> do
                inc own pRequests
                case proxyResp smp of
                  r@PKEY {} -> r <$ inc own pSuccesses
                  r -> r <$ inc own pErrorsCompat
              Left e -> do
                let own = isOwnServer a srv
                inc own pRequests
                inc own $ if temporaryClientError e then pErrorsConnect else pErrorsOther
                logWarn $ "Error connecting: " <> decodeLatin1 (strEncode $ host srv) <> " " <> tshow e
                pure . ERR $ smpProxyError e
            where
              proxyResp smp =
                let THandleParams {sessionId = srvSessId, thVersion, thServerVRange, thAuth} = thParams smp
                  in case compatibleVRange thServerVRange proxiedSMPRelayVRange of
                      -- Cap the destination relay version range to prevent client version fingerprinting.
                      -- See comment for proxiedSMPRelayVersion.
                      Just (Compatible vr) | thVersion >= sendingProxySMPVersion -> case thAuth of
                        Just THAuthClient {peerServerCertKey} -> PKEY srvSessId vr peerServerCertKey
                        Nothing -> ERR $ transportErr TENoServerAuth
                      _ -> ERR $ transportErr TEVersion
      PFWD fwdV pubKey encBlock -> do
        ProxyAgent {smpAgent = a} <- asks proxyAgent
        ServerStats {pMsgFwds, pMsgFwdsOwn} <- asks serverStats
        let inc = mkIncProxyStats pMsgFwds pMsgFwdsOwn
        liftIO (lookupSMPServerClient a sessId) >>= \case
          Just (own, smp) -> do
            inc own pRequests
            if v >= sendingProxySMPVersion
              then forkProxiedCmd $ do
                liftIO (runExceptT (forwardSMPTransmission smp corrId fwdV pubKey encBlock) `catch` (pure . Left . PCEIOError))  >>= \case
                  Right r -> PRES r <$ inc own pSuccesses
                  Left e -> ERR (smpProxyError e) <$ case e of
                    PCEProtocolError {} -> inc own pSuccesses
                    _ -> inc own pErrorsOther
              else Just (ERR $ transportErr TEVersion) <$ inc own pErrorsCompat
            where
              THandleParams {thVersion = v} = thParams smp
          Nothing -> inc False pRequests >> inc False pErrorsConnect $> Just (ERR $ PROXY NO_SESSION)
      where
        forkProxiedCmd :: M s BrokerMsg -> M s (Maybe BrokerMsg)
        forkProxiedCmd cmdAction = do
          bracket_ wait signal . forkClient clnt (B.unpack $ "client $" <> encode sessionId <> " proxy") $ do
            -- commands MUST be processed under a reasonable timeout or the client would halt
            cmdAction >>= \t -> reply [(corrId, EntityId sessId, t)]
          pure Nothing
          where
            wait = do
              ServerConfig {serverClientConcurrency} <- asks config
              atomically $ do
                used <- readTVar procThreads
                when (used >= serverClientConcurrency) retry
                writeTVar procThreads $! used + 1
            signal = atomically $ modifyTVar' procThreads (\t -> t - 1)
    transportErr :: TransportError -> ErrorType
    transportErr = PROXY . BROKER . TRANSPORT
    mkIncProxyStats :: MonadIO m => ProxyStats -> ProxyStats -> OwnServer -> (ProxyStats -> IORef Int) -> m ()
    mkIncProxyStats ps psOwn own sel = do
      incStat $ sel ps
      when own $ incStat $ sel psOwn
    processCommand :: Maybe THPeerClientService -> VersionSMP -> VerifiedTransmission s -> M s (Maybe (Transmission BrokerMsg))
    processCommand service clntVersion (q_, (corrId, entId, cmd)) = case cmd of
      Cmd SProxiedClient command -> processProxiedCmd (corrId, entId, command)
      Cmd SSender command -> Just <$> case command of
        SKEY k -> withQueue $ \q qr -> checkMode QMMessaging qr $ secureQueue_ q k
        SEND flags msgBody -> withQueue_ False $ sendMessage flags msgBody
      Cmd SIdleClient PING -> pure $ Just (corrId, NoEntity, PONG)
      Cmd SProxyService (RFWD encBlock) -> Just . (corrId,NoEntity,) <$> processForwardedCommand encBlock
      Cmd SSenderLink command -> Just <$> case command of
        LKEY k -> withQueue $ \q qr -> checkMode QMMessaging qr $ secureQueue_ q k $>> getQueueLink_ q qr
        LGET -> withQueue $ \q qr -> checkContact qr $ getQueueLink_ q qr
      Cmd SNotifier NSUB -> Just . (corrId,entId,) <$> case q_ of
        Just (q, QueueRec {notifier = Just ntfCreds}) -> subscribeNotifications q ntfCreds
        _ -> pure $ ERR INTERNAL
      Cmd SNotifierService NSUBS -> Just . (corrId,entId,) <$> case service of
        Just s -> subscribeServiceNotifications s
        Nothing -> pure $ ERR INTERNAL
      Cmd SCreator (NEW nqr@NewQueueReq {auth_}) ->
        Just <$> ifM allowNew (createQueue nqr) (pure (corrId, entId, ERR AUTH))
          where
            allowNew = do
              ServerConfig {allowNewQueues, newQueueBasicAuth} <- asks config
              pure $ allowNewQueues && maybe True ((== auth_) . Just) newQueueBasicAuth
      Cmd SRecipient command ->
        Just <$> case command of
          SUB -> withQueue subscribeQueue
          GET -> withQueue getMessage
          ACK msgId -> withQueue $ acknowledgeMsg msgId
          KEY sKey -> withQueue $ \q _ -> either err (corrId,entId,) <$> secureQueue_ q sKey
          RKEY rKeys -> withQueue $ \q qr -> checkMode QMContact qr $ OK <$$ liftIO (updateKeys (queueStore ms) q rKeys)
          LSET lnkId d ->
            withQueue $ \q qr -> case queueData qr of
              _ | isSecuredMsgQueue qr -> pure $ err AUTH
              Just (lnkId', _) | lnkId' /= lnkId -> pure $ err AUTH -- can't change link ID
              _ -> liftIO $ either err (const ok) <$> addQueueLinkData (queueStore ms) q lnkId d
          LDEL ->
            withQueue $ \q qr -> case queueData qr of
              Just _ -> liftIO $ either err (const ok) <$> deleteQueueLinkData (queueStore ms) q
              Nothing -> pure ok
          NKEY nKey dhKey -> withQueue $ \q _ -> addQueueNotifier_ q nKey dhKey
          NDEL -> withQueue $ \q _ -> deleteQueueNotifier_ q
          OFF -> maybe (pure $ err INTERNAL) suspendQueue_ q_
          DEL -> maybe (pure $ err INTERNAL) delQueueAndMsgs q_
          QUE -> withQueue $ \q qr -> (corrId,entId,) <$> getQueueInfo q qr
      Cmd SRecipientService SUBS -> pure $ Just $ err (CMD PROHIBITED) -- "TODO [certs rcv]"
      where
        createQueue :: NewQueueReq -> M s (Transmission BrokerMsg)
        createQueue NewQueueReq {rcvAuthKey, rcvDhKey, subMode, queueReqData}
          | isJust service && subMode == SMOnlyCreate = pure (corrId, entId, ERR $ CMD PROHIBITED)
          | otherwise = time "NEW" $ do
              g <- asks random
              idSize <- asks $ queueIdBytes . config
              updatedAt <- Just <$> liftIO getSystemDate
              (rcvPublicDhKey, privDhKey) <- atomically $ C.generateKeyPair g
              -- TODO [notifications]
              -- ntfKeys_ <- forM ntfCreds $ \(NewNtfCreds notifierKey dhKey) -> do
              --   (ntfPubDhKey, ntfPrivDhKey) <- atomically $ C.generateKeyPair g
              --   pure (notifierKey, C.dh' dhKey ntfPrivDhKey, ntfPubDhKey)
              let randId = EntityId <$> atomically (C.randomBytes idSize g)
                  -- TODO [notifications] the remaining 24 bytes are reserver for notifier ID
                  sndId' = B.take 24 $ C.sha3_384 (bs corrId)
                  tryCreate 0 = pure $ ERR INTERNAL
                  tryCreate n = do
                    (sndId, clntIds, queueData) <- case queueReqData of
                      Just (QRMessaging (Just (sId, d))) -> (\linkId -> (sId, True, Just (linkId, d))) <$> randId
                      Just (QRContact (Just (linkId, (sId, d)))) -> pure (sId, True, Just (linkId, d))
                      _ -> (,False,Nothing) <$> randId
                    -- The condition that client-provided sender ID must match hash of correlation ID
                    -- prevents "ID oracle" attack, when creating queue with supplied ID can be used to check
                    -- if queue with this ID still exists.
                    if clntIds && unEntityId sndId /= sndId'
                      then pure $ ERR $ CMD PROHIBITED
                      else do
                        rcvId <- randId
                        -- TODO [notifications]
                        -- ntf <- forM ntfKeys_ $ \(notifierKey, rcvNtfDhSecret, rcvPubDhKey) -> do
                        --   notifierId <- randId
                        --   pure (NtfCreds {notifierId, notifierKey, rcvNtfDhSecret}, ServerNtfCreds notifierId rcvPubDhKey)
                        let queueMode = queueReqMode <$> queueReqData
                            rcvServiceId = (\THClientService {serviceId} -> serviceId) <$> service
                            qr =
                              QueueRec
                                { senderId = sndId,
                                  recipientKeys = [rcvAuthKey],
                                  rcvDhSecret = C.dh' rcvDhKey privDhKey,
                                  senderKey = Nothing,
                                  queueMode,
                                  queueData,
                                  -- TODO [notifications]
                                  notifier = Nothing, -- fst <$> ntf,
                                  status = EntityActive,
                                  updatedAt,
                                  rcvServiceId
                                }
                        liftIO (addQueue ms rcvId qr) >>= \case
                          Left DUPLICATE_ -- TODO [short links] possibly, we somehow need to understand which IDs caused collision to retry if it's not client-supplied?
                            | clntIds -> pure $ ERR AUTH -- no retry on collision if sender ID is client-supplied
                            | otherwise -> tryCreate (n - 1)
                          Left e -> pure $ ERR e
                          Right _q -> do
                            stats <- asks serverStats
                            incStat $ qCreated stats
                            incStat $ qCount stats
                            -- TODO [notifications]
                            -- when (isJust ntf) $ incStat $ ntfCreated stats
                            case subMode of
                              SMOnlyCreate -> pure ()
                              SMSubscribe -> void $ subscribeNewQueue rcvId qr -- no need to check if message is available, it's a new queue
                            pure $ IDS QIK {rcvId, sndId, rcvPublicDhKey, queueMode, linkId = fst <$> queueData, serviceId = rcvServiceId} -- , serverNtfCreds = snd <$> ntf
              (corrId,entId,) <$> tryCreate (3 :: Int)

        -- this check allows to support contact queues created prior to SKEY,
        -- using `queueMode == Just QMContact` would prevent it, as they have queueMode `Nothing`.
        checkContact :: QueueRec -> M s (Either ErrorType BrokerMsg) -> M s (Transmission BrokerMsg)
        checkContact qr a =
          either err (corrId,entId,)
            <$> if isContactQueue qr then a else pure $ Left AUTH

        checkMode :: QueueMode -> QueueRec -> M s (Either ErrorType BrokerMsg) -> M s (Transmission BrokerMsg)
        checkMode qm QueueRec {queueMode} a =
          either err (corrId,entId,)
            <$> if queueMode == Just qm then a else pure $ Left AUTH

        secureQueue_ :: StoreQueue s -> SndPublicAuthKey -> M s (Either ErrorType BrokerMsg)
        secureQueue_ q sKey = do
          liftIO (secureQueue (queueStore ms) q sKey)
            $>> (asks serverStats >>= incStat . qSecured) $> Right OK

        getQueueLink_ :: StoreQueue s -> QueueRec -> M s (Either ErrorType BrokerMsg)
        getQueueLink_ q qr = liftIO $ LNK (senderId qr) <$$> getQueueLinkData (queueStore ms) q entId

        addQueueNotifier_ :: StoreQueue s -> NtfPublicAuthKey -> RcvNtfPublicDhKey -> M s (Transmission BrokerMsg)
        addQueueNotifier_ q notifierKey dhKey = time "NKEY" $ do
          (rcvPublicDhKey, privDhKey) <- atomically . C.generateKeyPair =<< asks random
          let rcvNtfDhSecret = C.dh' dhKey privDhKey
          (corrId,entId,) <$> addNotifierRetry 3 rcvPublicDhKey rcvNtfDhSecret
          where
            addNotifierRetry :: Int -> RcvNtfPublicDhKey -> RcvNtfDhSecret -> M s BrokerMsg
            addNotifierRetry 0 _ _ = pure $ ERR INTERNAL
            addNotifierRetry n rcvPublicDhKey rcvNtfDhSecret = do
              notifierId <- randomId =<< asks (queueIdBytes . config)
              let ntfCreds = NtfCreds {notifierId, notifierKey, rcvNtfDhSecret, ntfServiceId = Nothing}
              liftIO (addQueueNotifier (queueStore ms) q ntfCreds) >>= \case
                Left DUPLICATE_ -> addNotifierRetry (n - 1) rcvPublicDhKey rcvNtfDhSecret
                Left e -> pure $ ERR e
                Right nc_ -> do
                  incStat . ntfCreated =<< asks serverStats
                  forM_ nc_ $ \NtfCreds {notifierId = nId, ntfServiceId} ->
                    atomically $ writeTQueue (subQ ntfSubscribers) (CSDeleted nId ntfServiceId, clientId)
                  pure $ NID notifierId rcvPublicDhKey

        deleteQueueNotifier_ :: StoreQueue s -> M s (Transmission BrokerMsg)
        deleteQueueNotifier_ q =
          liftIO (deleteQueueNotifier (queueStore ms) q) >>= \case
            Right (Just NtfCreds {notifierId = nId, ntfServiceId}) -> do
              -- Possibly, the same should be done if the queue is suspended, but currently we do not use it
              stats <- asks serverStats
              deleted <- asks ntfStore >>= liftIO . (`deleteNtfs` nId)
              when (deleted > 0) $ liftIO $ atomicModifyIORef'_ (ntfCount stats) (subtract deleted)
              atomically $ writeTQueue (subQ ntfSubscribers) (CSDeleted nId ntfServiceId, clientId)
              incStat $ ntfDeleted stats
              pure ok
            Right Nothing -> pure ok
            Left e -> pure $ err e

        suspendQueue_ :: (StoreQueue s, QueueRec) -> M s (Transmission BrokerMsg)
        suspendQueue_ (q, _) = liftIO $ either err (const ok) <$> suspendQueue (queueStore ms) q

        -- TODO [certs rcv] if serviceId is passed, associate with the service and respond with SOK
        subscribeQueue :: StoreQueue s -> QueueRec -> M s (Transmission BrokerMsg)
        subscribeQueue q qr =
          liftIO (TM.lookupIO rId subscriptions) >>= \case
            Nothing -> subscribeNewQueue rId qr >>= deliver True
            Just s@Sub {subThread} -> do
              stats <- asks serverStats
              case subThread of
                ProhibitSub -> do
                  -- cannot use SUB in the same connection where GET was used
                  incStat $ qSubProhibited stats
                  pure (corrId, rId, ERR $ CMD PROHIBITED)
                _ -> do
                  incStat $ qSubDuplicate stats
                  atomically (tryTakeTMVar $ delivered s) >> deliver False s
          where
            rId = recipientId q
            deliver :: Bool -> Sub -> M s (Transmission BrokerMsg)
            deliver inc sub = do
              stats <- asks serverStats
              fmap (either (\e -> (corrId, rId, ERR e)) id) $ liftIO $ runExceptT $ do
                msg_ <- tryPeekMsg ms q
                liftIO $ when (inc && isJust msg_) $ incStat (qSub stats)
                liftIO $ deliverMessage "SUB" qr rId sub msg_

        subscribeNewQueue :: RecipientId -> QueueRec -> M s Sub
        subscribeNewQueue rId QueueRec {rcvServiceId} = time "SUB newSub" . atomically $ do
          writeTQueue (subQ subscribers) (CSClient rId rcvServiceId Nothing, clientId)
          sub <- newSubscription NoSub
          TM.insert rId sub subscriptions
          pure sub

        -- clients that use GET are not added to server subscribers
        getMessage :: StoreQueue s -> QueueRec -> M s (Transmission BrokerMsg)
        getMessage q qr = time "GET" $ do
          atomically (TM.lookup entId subscriptions) >>= \case
            Nothing ->
              atomically newSub >>= (`getMessage_` Nothing)
            Just s@Sub {subThread} ->
              case subThread of
                ProhibitSub ->
                  atomically (tryTakeTMVar $ delivered s)
                    >>= getMessage_ s
                -- cannot use GET in the same connection where there is an active subscription
                _ -> do
                  stats <- asks serverStats
                  incStat $ msgGetProhibited stats
                  pure $ err $ CMD PROHIBITED
          where
            newSub :: STM Sub
            newSub = do
              s <- newProhibitedSub
              TM.insert entId s subscriptions
              -- Here we don't account for this client as subscribed in the server
              -- and don't notify other subscribed clients.
              -- This is tracked as "subscription" in the client to prevent these
              -- clients from being able to subscribe.
              pure s
            getMessage_ :: Sub -> Maybe (MsgId, RoundedSystemTime) -> M s (Transmission BrokerMsg)
            getMessage_ s delivered_ = do
              stats <- asks serverStats
              fmap (either err id) $ liftIO $ runExceptT $
                tryPeekMsg ms q >>= \case
                  Just msg -> do
                    let encMsg = encryptMsg qr msg
                    incStat $ (if isJust delivered_ then msgGetDuplicate else msgGet) stats
                    ts <- liftIO getSystemSeconds
                    atomically $ setDelivered s msg ts $> (corrId, entId, MSG encMsg)
                  Nothing -> incStat (msgGetNoMsg stats) $> ok

        withQueue :: (StoreQueue s -> QueueRec -> M s (Transmission BrokerMsg)) -> M s (Transmission BrokerMsg)
        withQueue = withQueue_ True

        -- SEND passes queueNotBlocked False here to update time, but it fails anyway on blocked queues (see code for SEND).
        withQueue_ :: Bool -> (StoreQueue s -> QueueRec -> M s (Transmission BrokerMsg)) -> M s (Transmission BrokerMsg)
        withQueue_ queueNotBlocked action = case q_ of
          Nothing -> pure $ err INTERNAL
          Just (q, qr@QueueRec {status, updatedAt}) -> case status of
            EntityBlocked info | queueNotBlocked -> pure $ err $ BLOCKED info
            _ -> do
              t <- liftIO getSystemDate
              if updatedAt == Just t
                then action q qr
                else liftIO (updateQueueTime (queueStore ms) q t) >>= either (pure . err) (action q)

        subscribeNotifications :: StoreQueue s -> NtfCreds -> M s BrokerMsg
        subscribeNotifications q NtfCreds {ntfServiceId} = do
          stats <- asks serverStats
          let incNtfSrvStat sel = incStat $ sel $ ntfServices stats
          case service of
            Just THClientService {serviceId}
              | ntfServiceId == Just serviceId -> do
                  -- duplicate queue-service association - can only happen in case of response error/timeout
                  hasSub <- atomically $ ifM hasServiceSub (pure True) (False <$ newServiceQueueSub)
                  unless hasSub $ do
                    incNtfSrvStat srvSubCount
                    incNtfSrvStat srvSubQueues
                  incNtfSrvStat srvAssocDuplicate
                  pure $ SOK $ Just serviceId
              | otherwise ->
                  -- new or updated queue-service association
                  liftIO (setQueueService (queueStore ms) q SNotifierService (Just serviceId)) >>= \case
                    Left e -> pure $ ERR e
                    Right () -> do
                      hasSub <- atomically $ (<$ newServiceQueueSub) =<< hasServiceSub
                      unless hasSub $ incNtfSrvStat srvSubCount
                      incNtfSrvStat srvSubQueues
                      incNtfSrvStat $ maybe srvAssocNew (const srvAssocUpdated) ntfServiceId
                      pure $ SOK $ Just serviceId
              where
                hasServiceSub = (0 /=) <$> readTVar ntfServiceSubsCount
                -- This function is used when queue is associated with the service.
                newServiceQueueSub = do
                  writeTQueue (subQ ntfSubscribers) (CSClient entId ntfServiceId (Just serviceId), clientId)
                  modifyTVar' ntfServiceSubsCount (+ 1) -- service count
                  modifyTVar' (totalServiceSubs ntfSubscribers) (+ 1) -- server count for all services
            Nothing -> case ntfServiceId of
              Just _ ->
                liftIO (setQueueService (queueStore ms) q SNotifierService Nothing) >>= \case
                  Left e -> pure $ ERR e
                  Right () -> do
                    -- hasSubscription should never be True in this branch, because queue was associated with service.
                    -- So unless storage and session states diverge, this check is redundant.
                    hasSub <- atomically $ hasSubscription >>= newSub
                    incNtfSrvStat srvAssocRemoved
                    sok hasSub
              Nothing -> do
                hasSub <- atomically $ ifM hasSubscription (pure True) (newSub False)
                sok hasSub
              where
                hasSubscription = TM.member entId ntfSubscriptions
                newSub hasSub = do
                  writeTQueue (subQ ntfSubscribers) (CSClient entId ntfServiceId Nothing, clientId)
                  unless (hasSub) $ TM.insert entId () ntfSubscriptions
                  pure hasSub
                sok hasSub = do
                  incStat $ if hasSub then ntfSubDuplicate stats else ntfSub stats
                  pure $ SOK Nothing

        subscribeServiceNotifications :: THPeerClientService -> M s BrokerMsg
        subscribeServiceNotifications THClientService {serviceId} = do
          srvSubs <- readTVarIO ntfServiceSubsCount
          if srvSubs == 0
            then
              liftIO (getNtfServiceQueueCount @(StoreQueue s) (queueStore ms) serviceId) >>= \case
                Left e -> pure $ ERR e
                Right count -> do
                  atomically $ do
                    modifyTVar' ntfServiceSubsCount (+ count) -- service count
                    modifyTVar' (totalServiceSubs ntfSubscribers) (+ count) -- server count for all services
                  atomically $ writeTQueue (subQ ntfSubscribers) (CSService serviceId, clientId)
                  pure $ SOKS count
            else pure $ SOKS srvSubs

        acknowledgeMsg :: MsgId -> StoreQueue s -> QueueRec -> M s (Transmission BrokerMsg)
        acknowledgeMsg msgId q qr = time "ACK" $ do
          liftIO (TM.lookupIO entId subscriptions) >>= \case
            Nothing -> pure $ err NO_MSG
            Just sub ->
              atomically (getDelivered sub) >>= \case
                Just st -> do
                  stats <- asks serverStats
                  fmap (either err id) $ liftIO $ runExceptT $ do
                    case st of
                      ProhibitSub -> do
                        deletedMsg_ <- tryDelMsg ms q msgId
                        liftIO $ mapM_ (updateStats stats True) deletedMsg_
                        pure ok
                      _ -> do
                        (deletedMsg_, msg_) <- tryDelPeekMsg ms q msgId
                        liftIO $ mapM_ (updateStats stats False) deletedMsg_
                        liftIO $ deliverMessage "ACK" qr entId sub msg_
                _ -> pure $ err NO_MSG
          where
            getDelivered :: Sub -> STM (Maybe ServerSub)
            getDelivered Sub {delivered, subThread} = do
              tryTakeTMVar delivered $>>= \v@(msgId', _) ->
                if msgId == msgId' || B.null msgId
                  then pure $ Just subThread
                  else putTMVar delivered v $> Nothing
            updateStats :: ServerStats -> Bool -> Message -> IO ()
            updateStats stats isGet = \case
              MessageQuota {} -> pure ()
              Message {msgFlags} -> do
                incStat $ msgRecv stats
                if isGet
                  then incStat $ msgRecvGet stats
                  else pure () -- TODO skip notification delivery for delivered message
                  -- skipping delivery fails tests, it should be counted in msgNtfSkipped
                  -- forM_ (notifierId <$> notifier qr) $ \nId -> do
                  --   ns <- asks ntfStore
                  --   atomically $ TM.lookup nId ns >>=
                  --     mapM_ (\MsgNtf {ntfMsgId} -> when (msgId == msgId') $ TM.delete nId ns)
                atomicModifyIORef'_ (msgCount stats) (subtract 1)
                updatePeriodStats (activeQueues stats) entId
                when (notification msgFlags) $ do
                  incStat $ msgRecvNtf stats
                  updatePeriodStats (activeQueuesNtf stats) entId

        sendMessage :: MsgFlags -> MsgBody -> StoreQueue s -> QueueRec -> M s (Transmission BrokerMsg)
        sendMessage msgFlags msgBody q qr
          | B.length msgBody > maxMessageLength clntVersion = do
              stats <- asks serverStats
              incStat $ msgSentLarge stats
              pure $ err LARGE_MSG
          | otherwise = do
              stats <- asks serverStats
              case status qr of
                EntityOff -> do
                  incStat $ msgSentAuth stats
                  pure $ err AUTH
                EntityBlocked info -> do
                  incStat $ msgSentBlock stats
                  pure $ err $ BLOCKED info
                EntityActive ->
                  case C.maxLenBS msgBody of
                    Left _ -> pure $ err LARGE_MSG
                    Right body -> do
                      when (isJust (queueData qr) && isSecuredMsgQueue qr) $ void $ liftIO $
                        deleteQueueLinkData (queueStore ms) q
                      ServerConfig {messageExpiration, msgIdBytes} <- asks config
                      msgId <- randomId' msgIdBytes
                      msg_ <- liftIO $ time "SEND" $ runExceptT $ do
                        expireMessages messageExpiration stats
                        msg <- liftIO $ mkMessage msgId body
                        writeMsg ms q True msg
                      case msg_ of
                        Left e -> pure $ err e
                        Right Nothing -> do
                          incStat $ msgSentQuota stats
                          pure $ err QUOTA
                        Right (Just (msg, wasEmpty)) -> time "SEND ok" $ do
                          when wasEmpty $ liftIO $ tryDeliverMessage msg
                          when (notification msgFlags) $ do
                            mapM_ (`enqueueNotification` msg) (notifier qr)
                            incStat $ msgSentNtf stats
                            liftIO $ updatePeriodStats (activeQueuesNtf stats) (recipientId q)
                          incStat $ msgSent stats
                          incStat $ msgCount stats
                          liftIO $ updatePeriodStats (activeQueues stats) (recipientId q)
                          pure ok
          where
            mkMessage :: MsgId -> C.MaxLenBS MaxMessageLen -> IO Message
            mkMessage msgId body = do
              msgTs <- getSystemTime
              pure $! Message msgId msgTs msgFlags body

            expireMessages :: Maybe ExpirationConfig -> ServerStats -> ExceptT ErrorType IO ()
            expireMessages msgExp stats = do
              deleted <- maybe (pure 0) (deleteExpiredMsgs ms q <=< liftIO . expireBeforeEpoch) msgExp
              liftIO $ when (deleted > 0) $ atomicModifyIORef'_ (msgExpired stats) (+ deleted)

            -- The condition for delivery of the message is:
            -- - the queue was empty when the message was sent,
            -- - there is subscribed recipient,
            -- - no message was "delivered" that was not acknowledged.
            -- If the send queue of the subscribed client is not full the message is put there in the same transaction.
            -- If the queue is not full, then the thread is created where these checks are made:
            -- - it is the same subscribed client (in case it was reconnected it would receive message via SUB command)
            -- - nothing was delivered to this subscription (to avoid race conditions with the recipient).
            tryDeliverMessage :: Message -> IO ()
            tryDeliverMessage msg =
              -- the subscribed client var is read outside of STM to avoid transaction cost
              -- in case no client is subscribed.
              getSubscribedClient rId (queueSubscribers subscribers)
                $>>= deliverToSub
                >>= mapM_ forkDeliver
              where
                rId = recipientId q
                deliverToSub rcv = do
                  ts <- getSystemSeconds
                  atomically $
                  -- reading client TVar in the same transaction,
                  -- so that if subscription ends, it re-evalutates
                  -- and delivery is cancelled -
                  -- the new client will receive message in response to SUB.
                    readTVar rcv
                      $>>= \rc@Client {subscriptions = subs, sndQ = sndQ'} -> TM.lookup rId subs
                      $>>= \s@Sub {subThread, delivered} -> case subThread of
                        ProhibitSub -> pure Nothing
                        ServerSub st -> readTVar st >>= \case
                          NoSub ->
                            tryTakeTMVar delivered >>= \case
                              Just _ -> pure Nothing -- if a message was already delivered, should not deliver more
                              Nothing ->
                                ifM
                                  (isFullTBQueue sndQ')
                                  (writeTVar st SubPending $> Just (rc, s, st))
                                  (deliver sndQ' s ts $> Nothing)
                          _ -> pure Nothing
                deliver sndQ' s ts = do
                  let encMsg = encryptMsg qr msg
                  writeTBQueue sndQ' [(CorrId "", rId, MSG encMsg)]
                  void $ setDelivered s msg ts
                forkDeliver (rc@Client {sndQ = sndQ'}, s@Sub {delivered}, st) = do
                  t <- mkWeakThreadId =<< forkIO deliverThread
                  atomically $ modifyTVar' st $ \case
                    -- this case is needed because deliverThread can exit before it
                    SubPending -> SubThread t
                    st' -> st'
                  where
                    deliverThread = do
                      labelMyThread $ B.unpack ("client $" <> encode sessionId) <> " deliver/SEND"
                      -- lookup can be outside of STM transaction,
                      -- as long as the check that it is the same client is inside.
                      getSubscribedClient rId (queueSubscribers subscribers) >>= mapM_ deliverIfSame
                    deliverIfSame rcv = time "deliver" $ do
                      ts <- getSystemSeconds
                      atomically $ whenM (sameClient rc rcv) $
                        tryTakeTMVar delivered >>= \case
                          Just _ -> pure () -- if a message was already delivered, should not deliver more
                          Nothing -> do
                            -- a separate thread is needed because it blocks when client sndQ is full.
                            deliver sndQ' s ts
                            writeTVar st NoSub

            enqueueNotification :: NtfCreds -> Message -> M s ()
            enqueueNotification _ MessageQuota {} = pure ()
            enqueueNotification NtfCreds {notifierId = nId, rcvNtfDhSecret} Message {msgId, msgTs} = do
              ns <- asks ntfStore
              ntf <- mkMessageNotification msgId msgTs rcvNtfDhSecret
              liftIO $ storeNtf ns nId ntf
              incStat . ntfCount =<< asks serverStats

            mkMessageNotification :: ByteString -> SystemTime -> RcvNtfDhSecret -> M s MsgNtf
            mkMessageNotification msgId msgTs rcvNtfDhSecret = do
              ntfNonce <- atomically . C.randomCbNonce =<< asks random
              let msgMeta = NMsgMeta {msgId, msgTs}
                  encNMsgMeta = C.cbEncrypt rcvNtfDhSecret ntfNonce (smpEncode msgMeta) 128
              pure $ MsgNtf {ntfMsgId = msgId, ntfTs = msgTs, ntfNonce, ntfEncMeta = fromRight "" encNMsgMeta}

        processForwardedCommand :: EncFwdTransmission -> M s BrokerMsg
        processForwardedCommand (EncFwdTransmission s) = fmap (either ERR RRES) . runExceptT $ do
          THAuthServer {serverPrivKey, sessSecret'} <- maybe (throwE $ transportErr TENoServerAuth) pure (thAuth thParams')
          sessSecret <- maybe (throwE $ transportErr TENoServerAuth) pure sessSecret'
          let proxyNonce = C.cbNonce $ bs corrId
          s' <- liftEitherWith (const CRYPTO) $ C.cbDecryptNoPad sessSecret proxyNonce s
          FwdTransmission {fwdCorrId, fwdVersion, fwdKey, fwdTransmission = EncTransmission et} <- liftEitherWith (const $ CMD SYNTAX) $ smpDecode s'
          let clientSecret = C.dh' fwdKey serverPrivKey
              clientNonce = C.cbNonce $ bs fwdCorrId
          b <- liftEitherWith (const CRYPTO) $ C.cbDecrypt clientSecret clientNonce et
          let clntTHParams = smpTHParamsSetVersion fwdVersion thParams'
          -- only allowing single forwarded transactions
          t' <- case tParse clntTHParams b of
            t :| [] -> pure $ tDecodeServer clntTHParams t
            _ -> throwE BLOCK
          let clntThAuth = Just $ THAuthServer {serverPrivKey, peerClientService = Nothing, sessSecret' = Just clientSecret}
          -- process forwarded command
          r <-
            lift (rejectOrVerify clntThAuth t') >>= \case
              Left r -> pure r
              -- rejectOrVerify filters allowed commands, no need to repeat it here.
              -- INTERNAL is used because processCommand never returns Nothing for sender commands (could be extracted for better types).
              Right t''@(_, (corrId', entId', _)) -> fromMaybe (corrId', entId', ERR INTERNAL) <$> lift (processCommand Nothing fwdVersion t'')
          -- encode response
          r' <- case batchTransmissions clntTHParams [Right (Nothing, encodeTransmission clntTHParams r)] of
            [] -> throwE INTERNAL -- at least 1 item is guaranteed from NonEmpty/Right
            TBError _ _ : _ -> throwE BLOCK
            TBTransmission b' _ : _ -> pure b'
            TBTransmissions b' _ _ : _ -> pure b'
          -- encrypt to client
          r2 <- liftEitherWith (const BLOCK) $ EncResponse <$> C.cbEncrypt clientSecret (C.reverseNonce clientNonce) r' paddedProxiedTLength
          -- encrypt to proxy
          let fr = FwdResponse {fwdCorrId, fwdResponse = r2}
              r3 = EncFwdResponse $ C.cbEncryptNoPad sessSecret (C.reverseNonce proxyNonce) (smpEncode fr)
          stats <- asks serverStats
          incStat $ pMsgFwdsRecv stats
          pure r3
          where
            rejectOrVerify :: Maybe (THandleAuth 'TServer) -> SignedTransmissionOrError ErrorType Cmd -> M s (VerifiedTransmissionOrError s)
            rejectOrVerify clntThAuth = \case
              Left (corrId', entId', e) -> pure $ Left (corrId', entId', ERR e)
              Right t'@(_, _, t''@(corrId', entId', cmd'))
                | allowed -> liftIO $ verified <$> verifyTransmission ms Nothing clntThAuth t'
                | otherwise -> pure $ Left (corrId', entId', ERR $ CMD PROHIBITED)
                where
                  allowed = case cmd' of
                    Cmd SSender SEND {} -> True
                    Cmd SSender (SKEY _) -> True
                    Cmd SSenderLink (LKEY _) -> True
                    Cmd SSenderLink LGET -> True
                    _ -> False
                  verified = \case
                    VRVerified q -> Right (q, t'')
                    VRFailed e -> Left (corrId', entId', ERR e)

        deliverMessage :: T.Text -> QueueRec -> RecipientId -> Sub -> Maybe Message -> IO (Transmission BrokerMsg)
        deliverMessage name qr rId s@Sub {subThread} msg_ = time (name <> " deliver") $
          case subThread of
            ProhibitSub -> pure resp
            _ -> case msg_ of
              Just msg -> do
                ts <- getSystemSeconds
                let encMsg = encryptMsg qr msg
                atomically (setDelivered s msg ts) $> (corrId, rId, MSG encMsg)
              _ -> pure resp
          where
            resp = (corrId, rId, OK)

        time :: MonadIO m => T.Text -> m a -> m a
        time name = timed name entId

        encryptMsg :: QueueRec -> Message -> RcvMessage
        encryptMsg qr msg = encrypt . encodeRcvMsgBody $ case msg of
          Message {msgFlags, msgBody} -> RcvMsgBody {msgTs = msgTs', msgFlags, msgBody}
          MessageQuota {} -> RcvMsgQuota msgTs'
          where
            encrypt :: KnownNat i => C.MaxLenBS i -> RcvMessage
            encrypt body = RcvMessage msgId' . EncRcvMsgBody $ C.cbEncryptMaxLenBS (rcvDhSecret qr) (C.cbNonce msgId') body
            msgId' = messageId msg
            msgTs' = messageTs msg

        setDelivered :: Sub -> Message -> RoundedSystemTime -> STM Bool
        setDelivered Sub {delivered} msg !ts = do
          let !msgId = messageId msg
          tryPutTMVar delivered (msgId, ts)

        delQueueAndMsgs :: (StoreQueue s, QueueRec) -> M s (Transmission BrokerMsg)
        delQueueAndMsgs (q, QueueRec {rcvServiceId}) = do
          liftIO (deleteQueue ms q) >>= \case
            Right qr -> do
              -- Possibly, the same should be done if the queue is suspended, but currently we do not use it
              atomically $ do
                writeTQueue (subQ subscribers) (CSDeleted entId rcvServiceId, clientId)
                -- queue is usually deleted by the same client that is currently subscribed,
                -- we delete subscription here, so the client with no subscriptions can be disconnected.
                TM.delete entId subscriptions
              forM_ (notifier qr) $ \NtfCreds {notifierId = nId, ntfServiceId} -> do
                -- queue is deleted by a different client from the one subscribed to notifications,
                -- so we don't need to remove subscription from the current client.
                stats <- asks serverStats
                deleted <- asks ntfStore >>= liftIO . (`deleteNtfs` nId)
                when (deleted > 0) $ liftIO $ atomicModifyIORef'_ (ntfCount stats) (subtract deleted)
                atomically $ writeTQueue (subQ ntfSubscribers) (CSDeleted nId ntfServiceId, clientId)
              updateDeletedStats qr
              pure ok
            Left e -> pure $ err e

        getQueueInfo :: StoreQueue s -> QueueRec -> M s BrokerMsg
        getQueueInfo q QueueRec {senderKey, notifier} = do
          fmap (either ERR INFO) $ liftIO $ runExceptT $ do
            qiSub <- liftIO $ TM.lookupIO entId subscriptions >>= mapM mkQSub
            qiSize <- getQueueSize ms q
            qiMsg <- toMsgInfo <$$> tryPeekMsg ms q
            let info = QueueInfo {qiSnd = isJust senderKey, qiNtf = isJust notifier, qiSub, qiSize, qiMsg}
            pure info
          where
            mkQSub Sub {subThread, delivered} = do
              qSubThread <- case subThread of
                ServerSub t -> do
                  st <- readTVarIO t
                  pure $ case st of
                    NoSub -> QNoSub
                    SubPending -> QSubPending
                    SubThread _ -> QSubThread
                ProhibitSub -> pure QProhibitSub
              qDelivered <- atomically $ decodeLatin1 . encode . fst <$$> tryReadTMVar delivered
              pure QSub {qSubThread, qDelivered}

        ok :: Transmission BrokerMsg
        ok = (corrId, entId, OK)

        err :: ErrorType -> Transmission BrokerMsg
        err e = (corrId, entId, ERR e)

updateDeletedStats :: QueueRec -> M s ()
updateDeletedStats q = do
  stats <- asks serverStats
  let delSel = if isNothing (senderKey q) then qDeletedNew else qDeletedSecured
  incStat $ delSel stats
  incStat $ qDeletedAll stats
  liftIO $ atomicModifyIORef'_ (qCount stats) (subtract 1)

incStat :: MonadIO m => IORef Int -> m ()
incStat r = liftIO $ atomicModifyIORef'_ r (+ 1)
{-# INLINE incStat #-}

timed :: MonadIO m => T.Text -> RecipientId -> m a -> m a
timed name (EntityId qId) a = do
  t <- liftIO getSystemTime
  r <- a
  t' <- liftIO getSystemTime
  let int = diff t t'
  when (int > sec) . logDebug $ T.unwords [name, tshow $ encode qId, tshow int]
  pure r
  where
    diff t t' = (systemSeconds t' - systemSeconds t) * sec + fromIntegral (systemNanoseconds t' - systemNanoseconds t)
    sec = 1000_000000

randomId' :: Int -> M s ByteString
randomId' n = atomically . C.randomBytes n =<< asks random

randomId :: Int -> M s EntityId
randomId = fmap EntityId . randomId'
{-# INLINE randomId #-}

saveServerMessages :: Bool -> MsgStore s -> IO ()
saveServerMessages drainMsgs = \case
  StoreMemory ms@STMMsgStore {storeConfig = STMStoreConfig {storePath}} -> case storePath of
    Just f -> exportMessages False ms f drainMsgs
    Nothing -> logNote "undelivered messages are not saved"
  StoreJournal _ -> logNote "closed journal message storage"

exportMessages :: MsgStoreClass s => Bool -> s -> FilePath -> Bool -> IO ()
exportMessages tty ms f drainMsgs = do
  logNote $ "saving messages to file " <> T.pack f
  liftIO $ withFile f WriteMode $ \h ->
    tryAny (unsafeWithAllMsgQueues tty True ms $ saveQueueMsgs h) >>= \case
      Right (Sum total) -> logNote $ "messages saved: " <> tshow total
      Left e -> do
        logError $ "error exporting messages: " <> tshow e
        exitFailure
  where
    saveQueueMsgs h q = do
      msgs <-
        unsafeRunStore q "saveQueueMsgs" $
          getQueueMessages_ drainMsgs q =<< getMsgQueue ms q False
      BLD.hPutBuilder h $ encodeMessages (recipientId q) msgs
      pure $ Sum $ length msgs
    encodeMessages rId = mconcat . map (\msg -> BLD.byteString (strEncode $ MLRv3 rId msg) <> BLD.char8 '\n')

processServerMessages :: forall s'. StartOptions -> M s' (Maybe MessageStats)
processServerMessages StartOptions {skipWarnings} = do
  old_ <- asks (messageExpiration . config) $>>= (liftIO . fmap Just . expireBeforeEpoch)
  expire <- asks $ expireMessagesOnStart . config
  asks msgStore_ >>= liftIO . processMessages old_ expire
    where
      processMessages :: Maybe Int64 -> Bool -> MsgStore s' -> IO (Maybe MessageStats)
      processMessages old_ expire = \case
        StoreMemory ms@STMMsgStore {storeConfig = STMStoreConfig {storePath}} -> case storePath of
          Just f -> ifM (doesFileExist f) (Just <$> importMessages False ms f old_ skipWarnings) (pure Nothing)
          Nothing -> pure Nothing
        StoreJournal ms -> processJournalMessages old_ expire ms
      processJournalMessages :: forall s. Maybe Int64 -> Bool -> JournalMsgStore s -> IO (Maybe MessageStats)
      processJournalMessages old_ expire ms
        | expire = Just <$> case old_ of
            Just old -> do
              logNote "expiring journal store messages..."
              run $ processExpireQueue old
            Nothing -> do
              logNote "validating journal store messages..."
              run processValidateQueue
        | otherwise = logWarn "skipping message expiration" $> Nothing
        where
          run a = unsafeWithAllMsgQueues False False ms a `catchAny` \_ -> exitFailure
          processExpireQueue :: Int64 -> JournalQueue s -> IO MessageStats
          processExpireQueue old q = unsafeRunStore q "processExpireQueue" $ do
            mq <- getMsgQueue ms q False
            expiredMsgsCount <- deleteExpireMsgs_ old q mq
            storedMsgsCount <- getQueueSize_ mq
            pure MessageStats {storedMsgsCount, expiredMsgsCount, storedQueues = 1}
          processValidateQueue :: JournalQueue s -> IO MessageStats
          processValidateQueue q = unsafeRunStore q "processValidateQueue" $ do
            storedMsgsCount <- getQueueSize_ =<< getMsgQueue ms q False
            pure newMessageStats {storedMsgsCount, storedQueues = 1}

importMessages :: forall s. MsgStoreClass s => Bool -> s -> FilePath -> Maybe Int64 -> Bool -> IO MessageStats
importMessages tty ms f old_ skipWarnings  = do
  logNote $ "restoring messages from file " <> T.pack f
  (_, (storedMsgsCount, expiredMsgsCount, overQuota)) <-
    foldLogLines tty f restoreMsg (Nothing, (0, 0, M.empty))
  renameFile f $ f <> ".bak"
  mapM_ setOverQuota_ overQuota
  logQueueStates ms
  EntityCounts {queueCount} <- liftIO $ getEntityCounts @(StoreQueue s) $ queueStore ms
  pure MessageStats {storedMsgsCount, expiredMsgsCount, storedQueues = queueCount}
  where
    restoreMsg :: (Maybe (RecipientId, StoreQueue s), (Int, Int, Map RecipientId (StoreQueue s))) -> Bool -> ByteString -> IO (Maybe (RecipientId, StoreQueue s), (Int, Int, Map RecipientId (StoreQueue s)))
    restoreMsg (q_, counts@(!stored, !expired, !overQuota)) eof s = case strDecode s of
      Right (MLRv3 rId msg) -> runExceptT (addToMsgQueue rId msg) >>= either (exitErr . tshow) pure
      Left e
        | eof -> warnOrExit (parsingErr e) $> (q_, counts)
        | otherwise -> exitErr $ parsingErr e
      where
        exitErr e = do
          when tty $ putStrLn ""
          logError $ "error restoring messages: " <> e
          liftIO exitFailure
        parsingErr :: String -> Text
        parsingErr e = "parsing error (" <> T.pack e <> "): " <> safeDecodeUtf8 (B.take 100 s)
        addToMsgQueue rId msg = do
          qOrErr <- case q_ of
            -- to avoid lookup when restoring the next message to the same queue
            Just (rId', q') | rId' == rId -> pure $ Right q'
            _ -> liftIO $ getQueue ms SRecipient rId
          case qOrErr of
            Right q -> addToQueue_ q rId msg
            Left AUTH -> liftIO $ do
              when tty $ putStrLn ""
              warnOrExit $ "queue " <> safeDecodeUtf8 (encode $ unEntityId rId) <> " does not exist"
              pure (Nothing, counts)
            Left e -> throwE e
        addToQueue_ q rId msg =
          (Just (rId, q),) <$> case msg of
            Message {msgTs}
              | maybe True (systemSeconds msgTs >=) old_ -> do
                  writeMsg ms q False msg >>= \case
                    Just _ -> pure (stored + 1, expired, overQuota)
                    Nothing -> liftIO $ do
                      when tty $ putStrLn ""
                      logError $ decodeLatin1 $ "message queue " <> strEncode rId <> " is full, message not restored: " <> strEncode (messageId msg)
                      pure counts
              | otherwise -> pure (stored, expired + 1, overQuota)
            MessageQuota {} ->
              -- queue was over quota at some point,
              -- it will be set as over quota once fully imported
              mergeQuotaMsgs >> writeMsg ms q False msg $> (stored, expired, M.insert rId q overQuota)
              where
                -- if the first message in queue head is "quota", remove it.
                mergeQuotaMsgs =
                  withPeekMsgQueue ms q "mergeQuotaMsgs" $ maybe (pure ()) $ \case
                    (mq, MessageQuota {}) -> tryDeleteMsg_ q mq False
                    _ -> pure ()
        warnOrExit e
          | skipWarnings = logWarn e'
          | otherwise = do
              logWarn $ e' <> ", start with --skip-warnings option to ignore this error"
              exitFailure
          where
            e' = "warning restoring messages: " <> e

printMessageStats :: T.Text -> MessageStats -> IO ()
printMessageStats name MessageStats {storedMsgsCount, expiredMsgsCount, storedQueues} =
  logNote $ name <> " stored: " <> tshow storedMsgsCount <> ", expired: " <> tshow expiredMsgsCount <> ", queues: " <> tshow storedQueues

saveServerNtfs :: M s ()
saveServerNtfs = asks (storeNtfsFile . config) >>= mapM_ saveNtfs
  where
    saveNtfs f = do
      logNote $ "saving notifications to file " <> T.pack f
      NtfStore ns <- asks ntfStore
      liftIO . withFile f WriteMode $ \h ->
        readTVarIO ns >>= mapM_ (saveQueueNtfs h) . M.assocs
      logNote "notifications saved"
      where
        -- reverse on save, to save notifications in order, will become reversed again when restoring.
        saveQueueNtfs h (nId, v) = BLD.hPutBuilder h . encodeNtfs nId . reverse =<< readTVarIO v
        encodeNtfs nId = mconcat . map (\ntf -> BLD.byteString (strEncode $ NLRv1 nId ntf) <> BLD.char8 '\n')

restoreServerNtfs :: M s MessageStats
restoreServerNtfs =
  asks (storeNtfsFile . config) >>= \case
    Just f -> ifM (doesFileExist f) (restoreNtfs f) (pure newMessageStats)
    Nothing -> pure newMessageStats
  where
    restoreNtfs f = do
      logNote $ "restoring notifications from file " <> T.pack f
      ns <- asks ntfStore
      old <- asks (notificationExpiration . config) >>= liftIO . expireBeforeEpoch
      liftIO $
        LB.readFile f >>= runExceptT . foldM (restoreNtf ns old) (0, 0, 0) . LB.lines >>= \case
          Left e -> do
            logError . T.pack $ "error restoring notifications: " <> e
            liftIO exitFailure
          Right (lineCount, storedMsgsCount, expiredMsgsCount) -> do
            renameFile f $ f <> ".bak"
            let NtfStore ns' = ns
            storedQueues <- M.size <$> readTVarIO ns'
            logNote $ "notifications restored, " <> tshow lineCount <> " lines processed"
            pure MessageStats {storedMsgsCount, expiredMsgsCount, storedQueues}
      where
        restoreNtf :: NtfStore -> Int64 -> (Int, Int, Int) -> LB.ByteString -> ExceptT String IO (Int, Int, Int)
        restoreNtf ns old (!lineCount, !stored, !expired) s' = do
          NLRv1 nId ntf <- liftEither . first (ntfErr "parsing") $ strDecode s
          liftIO $ addToNtfs nId ntf
          where
            s = LB.toStrict s'
            addToNtfs nId ntf@MsgNtf {ntfTs}
              | systemSeconds ntfTs < old = pure (lineCount + 1, stored, expired + 1)
              | otherwise = storeNtf ns nId ntf $> (lineCount + 1, stored + 1, expired)
            ntfErr :: Show e => String -> e -> String
            ntfErr op e = op <> " error (" <> show e <> "): " <> B.unpack (B.take 100 s)

saveServerStats :: M s ()
saveServerStats =
  asks (serverStatsBackupFile . config)
    >>= mapM_ (\f -> asks serverStats >>= liftIO . getServerStatsData >>= liftIO . saveStats f)
  where
    saveStats f stats = do
      logNote $ "saving server stats to file " <> T.pack f
      B.writeFile f $ strEncode stats
      logNote "server stats saved"

restoreServerStats :: forall s. MsgStoreClass s => Maybe MessageStats -> MessageStats -> M s ()
restoreServerStats msgStats_ ntfStats = asks (serverStatsBackupFile . config) >>= mapM_ restoreStats
  where
    restoreStats f = whenM (doesFileExist f) $ do
      logNote $ "restoring server stats from file " <> T.pack f
      liftIO (strDecode <$> B.readFile f) >>= \case
        Right d@ServerStatsData {_qCount = statsQCount, _msgCount = statsMsgCount, _ntfCount = statsNtfCount} -> do
          s <- asks serverStats
          st <- asks msgStore
          EntityCounts {queueCount = _qCount} <- liftIO $ getEntityCounts @(StoreQueue s) $ queueStore st
          let _msgCount = maybe statsMsgCount storedMsgsCount msgStats_
              _ntfCount = storedMsgsCount ntfStats
              _msgExpired' = _msgExpired d + maybe 0 expiredMsgsCount msgStats_
              _msgNtfExpired' = _msgNtfExpired d + expiredMsgsCount ntfStats
          liftIO $ setServerStats s d {_qCount, _msgCount, _ntfCount, _msgExpired = _msgExpired', _msgNtfExpired = _msgNtfExpired'}
          renameFile f $ f <> ".bak"
          logNote "server stats restored"
          compareCounts "Queue" statsQCount _qCount
          compareCounts "Message" statsMsgCount _msgCount
          compareCounts "Notification" statsNtfCount _ntfCount
        Left e -> do
          logNote $ "error restoring server stats: " <> T.pack e
          liftIO exitFailure
    compareCounts name statsCnt storeCnt =
      when (statsCnt /= storeCnt) $ logWarn $ name <> " count differs: stats: " <> tshow statsCnt <> ", store: " <> tshow storeCnt