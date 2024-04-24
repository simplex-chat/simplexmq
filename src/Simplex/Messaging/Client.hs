{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module      : Simplex.Messaging.Client
-- Copyright   : (c) simplex.chat
-- License     : AGPL-3
--
-- Maintainer  : chat@simplex.chat
-- Stability   : experimental
-- Portability : non-portable
--
-- This module provides a functional client API for SMP protocol.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md
module Simplex.Messaging.Client
  ( -- * Connect (disconnect) client to (from) SMP server
    TransportSession,
    ProtocolClient (thParams, sessionTs),
    SMPClient,
    getProtocolClient,
    closeProtocolClient,
    protocolClientServer,
    transportHost',
    transportSession',

    -- * SMP protocol command functions
    createSMPQueue,
    subscribeSMPQueue,
    subscribeSMPQueues,
    streamSubscribeSMPQueues,
    getSMPMessage,
    subscribeSMPQueueNotifications,
    subscribeSMPQueuesNtfs,
    secureSMPQueue,
    enableSMPQueueNotifications,
    disableSMPQueueNotifications,
    enableSMPQueuesNtfs,
    disableSMPQueuesNtfs,
    sendSMPMessage,
    ackSMPMessage,
    suspendSMPQueue,
    deleteSMPQueue,
    deleteSMPQueues,
    createSMPProxySession,
    proxySMPMessage,
    forwardSMPMessage,
    sendProtocolCommand,

    -- * Supporting types and client configuration
    ProtocolClientError (..),
    SMPClientError,
    ProtocolClientConfig (..),
    NetworkConfig (..),
    TransportSessionMode (..),
    defaultClientConfig,
    defaultSMPClientConfig,
    defaultNetworkConfig,
    transportClientConfig,
    chooseTransportHost,
    proxyUsername,
    temporaryClientError,
    smpProxyError,
    ServerTransmission,
    ClientCommand,

    -- * For testing
    PCTransmission,
    mkTransmission,
    authTransmission,
    smpClientStub,
  )
where

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except
import Crypto.Random (ChaChaDRG)
import qualified Data.Aeson.TH as J
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import Data.Maybe (fromMaybe)
import Data.Time.Clock (UTCTime (..), getCurrentTime)
import qualified Data.X509 as X
import qualified Data.X509.Validation as XV
import Network.Socket (ServiceName)
import Numeric.Natural
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (defaultJSON, dropPrefix, enumJSON)
import Simplex.Messaging.Protocol
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Client (SocksProxy, TransportClientConfig (..), TransportHost (..), runTransportClient)
import Simplex.Messaging.Transport.KeepAlive
import Simplex.Messaging.Transport.WebSockets (WS)
import Simplex.Messaging.Util (bshow, liftEitherWith, raceAny_, threadDelay')
import Simplex.Messaging.Version
import System.Timeout (timeout)

-- | 'SMPClient' is a handle used to send commands to a specific SMP server.
--
-- Use 'getSMPClient' to connect to an SMP server and create a client handle.
data ProtocolClient v err msg = ProtocolClient
  { action :: Maybe (Async ()),
    thParams :: THandleParams v 'TClient,
    sessionTs :: UTCTime,
    client_ :: PClient v err msg
  }

data PClient v err msg = PClient
  { connected :: TVar Bool,
    transportSession :: TransportSession msg,
    transportHost :: TransportHost,
    tcpTimeout :: Int,
    pingErrorCount :: TVar Int,
    clientCorrId :: TVar ChaChaDRG,
    sentCommands :: TMap CorrId (Request err msg),
    sndQ :: TBQueue ByteString,
    rcvQ :: TBQueue (NonEmpty (SignedTransmission err msg)),
    msgQ :: Maybe (TBQueue (ServerTransmission v msg))
  }

smpClientStub :: TVar ChaChaDRG -> ByteString -> VersionSMP -> Maybe (THandleAuth 'TClient) -> STM SMPClient
smpClientStub g sessionId thVersion thAuth = do
  connected <- newTVar False
  clientCorrId <- C.newRandomDRG g
  sentCommands <- TM.empty
  pingErrorCount <- newTVar 0
  sndQ <- newTBQueue 100
  rcvQ <- newTBQueue 100
  return
    ProtocolClient
      { action = Nothing,
        thParams =
          THandleParams
            { sessionId,
              thVersion,
              thAuth,
              blockSize = smpBlockSize,
              implySessId = thVersion >= authCmdsSMPVersion,
              batch = True
            },
        sessionTs = UTCTime (read "2024-03-31") 0,
        client_ =
          PClient
            { connected,
              transportSession = (1, "smp://LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI=@localhost:5001", Nothing),
              transportHost = "localhost",
              tcpTimeout = 15_000_000,
              pingErrorCount,
              clientCorrId,
              sentCommands,
              sndQ,
              rcvQ,
              msgQ = Nothing
            }
      }

type SMPClient = ProtocolClient SMPVersion ErrorType BrokerMsg

-- | Type for client command data
type ClientCommand msg = (Maybe C.APrivateAuthKey, EntityId, ProtoCommand msg)

-- | Type synonym for transmission from some SPM server queue.
type ServerTransmission v msg = (TransportSession msg, Version v, SessionId, EntityId, msg)

data HostMode
  = -- | prefer (or require) onion hosts when connecting via SOCKS proxy
    HMOnionViaSocks
  | -- | prefer (or require) onion hosts
    HMOnion
  | -- | prefer (or require) public hosts
    HMPublic
  deriving (Eq, Show)

-- | network configuration for the client
data NetworkConfig = NetworkConfig
  { -- | use SOCKS5 proxy
    socksProxy :: Maybe SocksProxy,
    -- | determines critera which host is chosen from the list
    hostMode :: HostMode,
    -- | if above criteria is not met, if the below setting is True return error, otherwise use the first host
    requiredHostMode :: Bool,
    -- | transport sessions are created per user or per entity
    sessionMode :: TransportSessionMode,
    -- | timeout for the initial client TCP/TLS connection (microseconds)
    tcpConnectTimeout :: Int,
    -- | timeout of protocol commands (microseconds)
    tcpTimeout :: Int,
    -- | additional timeout per kilobyte (1024 bytes) to be sent
    tcpTimeoutPerKb :: Int64,
    -- | TCP keep-alive options, Nothing to skip enabling keep-alive
    tcpKeepAlive :: Maybe KeepAliveOpts,
    -- | period for SMP ping commands (microseconds, 0 to disable)
    smpPingInterval :: Int64,
    -- | the count of PING errors after which SMP client terminates (and will be reconnected), 0 to disable
    smpPingCount :: Int,
    logTLSErrors :: Bool
  }
  deriving (Eq, Show)

data TransportSessionMode = TSMUser | TSMEntity
  deriving (Eq, Show)

defaultNetworkConfig :: NetworkConfig
defaultNetworkConfig =
  NetworkConfig
    { socksProxy = Nothing,
      hostMode = HMOnionViaSocks,
      requiredHostMode = False,
      sessionMode = TSMUser,
      tcpConnectTimeout = 20_000_000,
      tcpTimeout = 15_000_000,
      tcpTimeoutPerKb = 5_000,
      tcpKeepAlive = Just defaultKeepAliveOpts,
      smpPingInterval = 600_000_000, -- 10min
      smpPingCount = 3,
      logTLSErrors = False
    }

transportClientConfig :: NetworkConfig -> TransportClientConfig
transportClientConfig NetworkConfig {socksProxy, tcpKeepAlive, logTLSErrors} =
  TransportClientConfig {socksProxy, tcpKeepAlive, logTLSErrors, clientCredentials = Nothing, alpn = Nothing}
{-# INLINE transportClientConfig #-}

-- | protocol client configuration.
data ProtocolClientConfig v = ProtocolClientConfig
  { -- | size of TBQueue to use for server commands and responses
    qSize :: Natural,
    -- | default server port if port is not specified in ProtocolServer
    defaultTransport :: (ServiceName, ATransport),
    -- | network configuration
    networkConfig :: NetworkConfig,
    -- | client-server protocol version range
    serverVRange :: VersionRange v,
    -- | agree shared session secret (used in SMP proxy)
    agreeSecret :: Bool
  }

-- | Default protocol client configuration.
defaultClientConfig :: VersionRange v -> ProtocolClientConfig v
defaultClientConfig serverVRange =
  ProtocolClientConfig
    { qSize = 64,
      defaultTransport = ("443", transport @TLS),
      networkConfig = defaultNetworkConfig,
      serverVRange,
      agreeSecret = False
    }
{-# INLINE defaultClientConfig #-}

defaultSMPClientConfig :: ProtocolClientConfig SMPVersion
defaultSMPClientConfig = defaultClientConfig supportedClientSMPRelayVRange
{-# INLINE defaultSMPClientConfig #-}

data Request err msg = Request
  { entityId :: EntityId,
    responseVar :: TMVar (Either (ProtocolClientError err) msg)
  }

data Response err msg = Response
  { entityId :: EntityId,
    response :: Either (ProtocolClientError err) msg
  }

chooseTransportHost :: NetworkConfig -> NonEmpty TransportHost -> Either (ProtocolClientError err) TransportHost
chooseTransportHost NetworkConfig {socksProxy, hostMode, requiredHostMode} hosts =
  firstOrError $ case hostMode of
    HMOnionViaSocks -> maybe publicHost (const onionHost) socksProxy
    HMOnion -> onionHost
    HMPublic -> publicHost
  where
    firstOrError
      | requiredHostMode = maybe (Left PCEIncompatibleHost) Right
      | otherwise = Right . fromMaybe (L.head hosts)
    isOnionHost = \case THOnionHost _ -> True; _ -> False
    onionHost = find isOnionHost hosts
    publicHost = find (not . isOnionHost) hosts

protocolClientServer :: ProtocolTypeI (ProtoType msg) => ProtocolClient v err msg -> String
protocolClientServer = B.unpack . strEncode . snd3 . transportSession . client_
  where
    snd3 (_, s, _) = s
{-# INLINE protocolClientServer #-}

transportHost' :: ProtocolClient v err msg -> TransportHost
transportHost' = transportHost . client_
{-# INLINE transportHost' #-}

transportSession' :: ProtocolClient v err msg -> TransportSession msg
transportSession' = transportSession . client_
{-# INLINE transportSession' #-}

type UserId = Int64

-- | Transport session key - includes entity ID if `sessionMode = TSMEntity`.
type TransportSession msg = (UserId, ProtoServer msg, Maybe EntityId)

-- | Connects to 'ProtocolServer' using passed client configuration
-- and queue for messages and notifications.
--
-- A single queue can be used for multiple 'SMPClient' instances,
-- as 'SMPServerTransmission' includes server information.
getProtocolClient :: forall v err msg. Protocol v err msg => TVar ChaChaDRG -> TransportSession msg -> ProtocolClientConfig v -> Maybe (TBQueue (ServerTransmission v msg)) -> (ProtocolClient v err msg -> IO ()) -> IO (Either (ProtocolClientError err) (ProtocolClient v err msg))
getProtocolClient g transportSession@(_, srv, _) cfg@ProtocolClientConfig {qSize, networkConfig, serverVRange, agreeSecret} msgQ disconnected = do
  case chooseTransportHost networkConfig (host srv) of
    Right useHost ->
      (atomically (mkProtocolClient useHost) >>= runClient useTransport useHost)
        `catch` \(e :: IOException) -> pure . Left $ PCEIOError e
    Left e -> pure $ Left e
  where
    NetworkConfig {tcpConnectTimeout, tcpTimeout, smpPingInterval} = networkConfig
    mkProtocolClient :: TransportHost -> STM (PClient v err msg)
    mkProtocolClient transportHost = do
      connected <- newTVar False
      pingErrorCount <- newTVar 0
      clientCorrId <- C.newRandomDRG g
      sentCommands <- TM.empty
      sndQ <- newTBQueue qSize
      rcvQ <- newTBQueue qSize
      return
        PClient
          { connected,
            transportSession,
            transportHost,
            tcpTimeout,
            pingErrorCount,
            clientCorrId,
            sentCommands,
            sndQ,
            rcvQ,
            msgQ
          }

    runClient :: (ServiceName, ATransport) -> TransportHost -> PClient v err msg -> IO (Either (ProtocolClientError err) (ProtocolClient v err msg))
    runClient (port', ATransport t) useHost c = do
      cVar <- newEmptyTMVarIO
      let tcConfig = transportClientConfig networkConfig
          username = proxyUsername transportSession
      action <-
        async $
          runTransportClient tcConfig (Just username) useHost port' (Just $ keyHash srv) (client t c cVar)
            `finally` atomically (tryPutTMVar cVar $ Left PCENetworkError)
      c_ <- tcpConnectTimeout `timeout` atomically (takeTMVar cVar)
      case c_ of
        Just (Right c') -> pure $ Right c' {action = Just action}
        Just (Left e) -> pure $ Left e
        Nothing -> cancel action $> Left PCENetworkError

    useTransport :: (ServiceName, ATransport)
    useTransport = case port srv of
      "" -> defaultTransport cfg
      "80" -> ("80", transport @WS)
      p -> (p, transport @TLS)

    client :: forall c. Transport c => TProxy c -> PClient v err msg -> TMVar (Either (ProtocolClientError err) (ProtocolClient v err msg)) -> c -> IO ()
    client _ c cVar h = do
      ks <- if agreeSecret then Just <$> atomically (C.generateKeyPair g) else pure Nothing
      runExceptT (protocolClientHandshake @v @err @msg h ks (keyHash srv) serverVRange) >>= \case
        Left e -> atomically . putTMVar cVar . Left $ PCETransportError e
        Right th@THandle {params} -> do
          sessionTs <- getCurrentTime
          let c' = ProtocolClient {action = Nothing, client_ = c, thParams = params, sessionTs}
          atomically $ do
            writeTVar (connected c) True
            putTMVar cVar $ Right c'
          raceAny_ ([send c' th, process c', receive c' th] <> [ping c' | smpPingInterval > 0])
            `finally` disconnected c'

    send :: Transport c => ProtocolClient v err msg -> THandle v c 'TClient -> IO ()
    send ProtocolClient {client_ = PClient {sndQ}} h = forever $ atomically (readTBQueue sndQ) >>= tPutLog h

    receive :: Transport c => ProtocolClient v err msg -> THandle v c 'TClient -> IO ()
    receive ProtocolClient {client_ = PClient {rcvQ}} h = forever $ tGet h >>= atomically . writeTBQueue rcvQ

    ping :: ProtocolClient v err msg -> IO ()
    ping c@ProtocolClient {client_ = PClient {pingErrorCount}} = do
      threadDelay' smpPingInterval
      runExceptT (sendProtocolCommand c Nothing "" $ protocolPing @v @err @msg) >>= \case
        Left PCEResponseTimeout -> do
          cnt <- atomically $ stateTVar pingErrorCount $ \cnt -> (cnt + 1, cnt + 1)
          when (maxCnt == 0 || cnt < maxCnt) $ ping c
        _ -> ping c -- sendProtocolCommand resets pingErrorCount
      where
        maxCnt = smpPingCount networkConfig

    process :: ProtocolClient v err msg -> IO ()
    process c = forever $ atomically (readTBQueue $ rcvQ $ client_ c) >>= mapM_ (processMsg c)

    processMsg :: ProtocolClient v err msg -> SignedTransmission err msg -> IO ()
    processMsg c@ProtocolClient {client_ = PClient {sentCommands}} (_, _, (corrId, entId, respOrErr)) =
      if B.null $ bs corrId
        then sendMsg respOrErr
        else do
          atomically (TM.lookup corrId sentCommands) >>= \case
            Nothing -> sendMsg respOrErr
            Just Request {entityId, responseVar} -> atomically $ do
              TM.delete corrId sentCommands
              putTMVar responseVar $ response entityId
      where
        response entityId
          | entityId == entId =
              case respOrErr of
                Left e -> Left $ PCEResponseError e
                Right r -> case protocolError r of
                  Just e -> Left $ PCEProtocolError e
                  _ -> Right r
          | otherwise = Left . PCEUnexpectedResponse $ bshow respOrErr
        sendMsg :: Either err msg -> IO ()
        sendMsg = \case
          Right msg -> atomically $ mapM_ (`writeTBQueue` serverTransmission c entId msg) msgQ
          Left e -> putStrLn $ "SMP client error: " <> show e

proxyUsername :: TransportSession msg -> ByteString
proxyUsername (userId, _, entityId_) = C.sha256Hash $ bshow userId <> maybe "" (":" <>) entityId_
{-# INLINE proxyUsername #-}

-- | Disconnects client from the server and terminates client threads.
closeProtocolClient :: ProtocolClient v err msg -> IO ()
closeProtocolClient = mapM_ uninterruptibleCancel . action
{-# INLINE closeProtocolClient #-}

-- | SMP client error type.
data ProtocolClientError err
  = -- | Correctly parsed SMP server ERR response.
    -- This error is forwarded to the agent client as `ERR SMP err`.
    PCEProtocolError err
  | -- | Invalid server response that failed to parse.
    -- Forwarded to the agent client as `ERR BROKER RESPONSE`.
    PCEResponseError err
  | -- | Different response from what is expected to a certain SMP command,
    -- e.g. server should respond `IDS` or `ERR` to `NEW` command,
    -- other responses would result in this error.
    -- Forwarded to the agent client as `ERR BROKER UNEXPECTED`.
    PCEUnexpectedResponse ByteString
  | -- | Used for TCP connection and command response timeouts.
    -- Forwarded to the agent client as `ERR BROKER TIMEOUT`.
    PCEResponseTimeout
  | -- | Failure to establish TCP connection.
    -- Forwarded to the agent client as `ERR BROKER NETWORK`.
    PCENetworkError
  | -- | No host compatible with network configuration
    PCEIncompatibleHost
  | -- | TCP transport handshake or some other transport error.
    -- Forwarded to the agent client as `ERR BROKER TRANSPORT e`.
    PCETransportError TransportError
  | -- | Error when cryptographically "signing" the command or when initializing crypto_box.
    PCECryptoError C.CryptoError
  | -- | IO Error
    PCEIOError IOException
  deriving (Eq, Show, Exception)

type SMPClientError = ProtocolClientError ErrorType

temporaryClientError :: ProtocolClientError err -> Bool
temporaryClientError = \case
  PCENetworkError -> True
  PCEResponseTimeout -> True
  PCEIOError _ -> True
  _ -> False
{-# INLINE temporaryClientError #-}

smpProxyError :: SMPClientError -> ErrorType
smpProxyError = \case
  PCEProtocolError et -> PROXY (PROTOCOL et)
  PCEResponseError et -> PROXY (RESPONSE et)
  PCEUnexpectedResponse bs -> PROXY (UNEXPECTED $ B.unpack $ B.take 32 bs)
  PCEResponseTimeout -> PROXY TIMEOUT
  PCENetworkError -> PROXY NETWORK
  PCEIncompatibleHost -> PROXY BAD_HOST
  PCETransportError t -> PROXY (TRANSPORT t)
  PCECryptoError _ -> INTERNAL
  PCEIOError _ -> INTERNAL

-- | Create a new SMP queue.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#create-queue-command
createSMPQueue ::
  SMPClient ->
  C.AAuthKeyPair -> -- SMP v6 - signature key pair, SMP v7 - DH key pair
  RcvPublicDhKey ->
  Maybe BasicAuth ->
  SubscriptionMode ->
  ExceptT SMPClientError IO QueueIdsKeys
createSMPQueue c (rKey, rpKey) dhKey auth subMode =
  sendSMPCommand c (Just rpKey) "" (NEW rKey dhKey auth subMode) >>= \case
    IDS qik -> pure qik
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Subscribe to the SMP queue.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#subscribe-to-queue
subscribeSMPQueue :: SMPClient -> RcvPrivateAuthKey -> RecipientId -> ExceptT SMPClientError IO ()
subscribeSMPQueue c rpKey rId =
  sendSMPCommand c (Just rpKey) rId SUB >>= \case
    OK -> return ()
    cmd@MSG {} -> liftIO $ writeSMPMessage c rId cmd
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Subscribe to multiple SMP queues batching commands if supported.
subscribeSMPQueues :: SMPClient -> NonEmpty (RcvPrivateAuthKey, RecipientId) -> IO (NonEmpty (Either SMPClientError ()))
subscribeSMPQueues c qs = sendProtocolCommands c cs >>= mapM (processSUBResponse c)
  where
    cs = L.map (\(rpKey, rId) -> (Just rpKey, rId, Cmd SRecipient SUB)) qs

streamSubscribeSMPQueues :: SMPClient -> NonEmpty (RcvPrivateAuthKey, RecipientId) -> ([(RecipientId, Either SMPClientError ())] -> IO ()) -> IO ()
streamSubscribeSMPQueues c qs cb = streamProtocolCommands c cs $ mapM process >=> cb
  where
    cs = L.map (\(rpKey, rId) -> (Just rpKey, rId, Cmd SRecipient SUB)) qs
    process r@(Response rId _) = (rId,) <$> processSUBResponse c r

processSUBResponse :: SMPClient -> Response ErrorType BrokerMsg -> IO (Either SMPClientError ())
processSUBResponse c (Response rId r) = case r of
  Right OK -> pure $ Right ()
  Right cmd@MSG {} -> writeSMPMessage c rId cmd $> Right ()
  Right r' -> pure . Left . PCEUnexpectedResponse $ bshow r'
  Left e -> pure $ Left e

writeSMPMessage :: SMPClient -> RecipientId -> BrokerMsg -> IO ()
writeSMPMessage c rId msg = atomically $ mapM_ (`writeTBQueue` serverTransmission c rId msg) (msgQ $ client_ c)

serverTransmission :: ProtocolClient v err msg -> RecipientId -> msg -> ServerTransmission v msg
serverTransmission ProtocolClient {thParams = THandleParams {thVersion, sessionId}, client_ = PClient {transportSession}} entityId message =
  (transportSession, thVersion, sessionId, entityId, message)

-- | Get message from SMP queue. The server returns ERR PROHIBITED if a client uses SUB and GET via the same transport connection for the same queue
--
-- https://github.covm/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#receive-a-message-from-the-queue
getSMPMessage :: SMPClient -> RcvPrivateAuthKey -> RecipientId -> ExceptT SMPClientError IO (Maybe RcvMessage)
getSMPMessage c rpKey rId =
  sendSMPCommand c (Just rpKey) rId GET >>= \case
    OK -> pure Nothing
    cmd@(MSG msg) -> liftIO (writeSMPMessage c rId cmd) $> Just msg
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Subscribe to the SMP queue notifications.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#subscribe-to-queue-notifications
subscribeSMPQueueNotifications :: SMPClient -> NtfPrivateAuthKey -> NotifierId -> ExceptT SMPClientError IO ()
subscribeSMPQueueNotifications = okSMPCommand NSUB
{-# INLINE subscribeSMPQueueNotifications #-}

-- | Subscribe to multiple SMP queues notifications batching commands if supported.
subscribeSMPQueuesNtfs :: SMPClient -> NonEmpty (NtfPrivateAuthKey, NotifierId) -> IO (NonEmpty (Either SMPClientError ()))
subscribeSMPQueuesNtfs = okSMPCommands NSUB
{-# INLINE subscribeSMPQueuesNtfs #-}

-- | Secure the SMP queue by adding a sender public key.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#secure-queue-command
secureSMPQueue :: SMPClient -> RcvPrivateAuthKey -> RecipientId -> SndPublicAuthKey -> ExceptT SMPClientError IO ()
secureSMPQueue c rpKey rId senderKey = okSMPCommand (KEY senderKey) c rpKey rId
{-# INLINE secureSMPQueue #-}

-- | Enable notifications for the queue for push notifications server.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#enable-notifications-command
enableSMPQueueNotifications :: SMPClient -> RcvPrivateAuthKey -> RecipientId -> NtfPublicAuthKey -> RcvNtfPublicDhKey -> ExceptT SMPClientError IO (NotifierId, RcvNtfPublicDhKey)
enableSMPQueueNotifications c rpKey rId notifierKey rcvNtfPublicDhKey =
  sendSMPCommand c (Just rpKey) rId (NKEY notifierKey rcvNtfPublicDhKey) >>= \case
    NID nId rcvNtfSrvPublicDhKey -> pure (nId, rcvNtfSrvPublicDhKey)
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Enable notifications for the multiple queues for push notifications server.
enableSMPQueuesNtfs :: SMPClient -> NonEmpty (RcvPrivateAuthKey, RecipientId, NtfPublicAuthKey, RcvNtfPublicDhKey) -> IO (NonEmpty (Either SMPClientError (NotifierId, RcvNtfPublicDhKey)))
enableSMPQueuesNtfs c qs = L.map process <$> sendProtocolCommands c cs
  where
    cs = L.map (\(rpKey, rId, notifierKey, rcvNtfPublicDhKey) -> (Just rpKey, rId, Cmd SRecipient $ NKEY notifierKey rcvNtfPublicDhKey)) qs
    process (Response _ r) = case r of
      Right (NID nId rcvNtfSrvPublicDhKey) -> Right (nId, rcvNtfSrvPublicDhKey)
      Right r' -> Left . PCEUnexpectedResponse $ bshow r'
      Left e -> Left e

-- | Disable notifications for the queue for push notifications server.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#disable-notifications-command
disableSMPQueueNotifications :: SMPClient -> RcvPrivateAuthKey -> RecipientId -> ExceptT SMPClientError IO ()
disableSMPQueueNotifications = okSMPCommand NDEL
{-# INLINE disableSMPQueueNotifications #-}

-- | Disable notifications for multiple queues for push notifications server.
disableSMPQueuesNtfs :: SMPClient -> NonEmpty (RcvPrivateAuthKey, RecipientId) -> IO (NonEmpty (Either SMPClientError ()))
disableSMPQueuesNtfs = okSMPCommands NDEL
{-# INLINE disableSMPQueuesNtfs #-}

-- | Send SMP message.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#send-message
sendSMPMessage :: SMPClient -> Maybe SndPrivateAuthKey -> SenderId -> MsgFlags -> MsgBody -> ExceptT SMPClientError IO ()
sendSMPMessage c spKey sId flags msg =
  sendSMPCommand c spKey sId (SEND flags msg) >>= \case
    OK -> pure ()
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Acknowledge message delivery (server deletes the message).
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#acknowledge-message-delivery
ackSMPMessage :: SMPClient -> RcvPrivateAuthKey -> QueueId -> MsgId -> ExceptT SMPClientError IO ()
ackSMPMessage c rpKey rId msgId =
  sendSMPCommand c (Just rpKey) rId (ACK msgId) >>= \case
    OK -> return ()
    cmd@MSG {} -> liftIO $ writeSMPMessage c rId cmd
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Irreversibly suspend SMP queue.
-- The existing messages from the queue will still be delivered.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#suspend-queue
suspendSMPQueue :: SMPClient -> RcvPrivateAuthKey -> QueueId -> ExceptT SMPClientError IO ()
suspendSMPQueue = okSMPCommand OFF
{-# INLINE suspendSMPQueue #-}

-- | Irreversibly delete SMP queue and all messages in it.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#delete-queue
deleteSMPQueue :: SMPClient -> RcvPrivateAuthKey -> RecipientId -> ExceptT SMPClientError IO ()
deleteSMPQueue = okSMPCommand DEL
{-# INLINE deleteSMPQueue #-}

-- | Delete multiple SMP queues batching commands if supported.
deleteSMPQueues :: SMPClient -> NonEmpty (RcvPrivateAuthKey, RecipientId) -> IO (NonEmpty (Either SMPClientError ()))
deleteSMPQueues = okSMPCommands DEL
{-# INLINE deleteSMPQueues #-}

-- TODO picture

-- send PRXY :: SMPServer -> Maybe BasicAuth -> Command Sender
-- receives PKEY :: SessionId -> X.CertificateChain -> X.SignedExact X.PubKey -> BrokerMsg
createSMPProxySession :: SMPClient -> SMPServer -> Maybe BasicAuth -> ExceptT SMPClientError IO (SessionId, VersionSMP, C.PublicKeyX25519)
createSMPProxySession c relayServ@ProtocolServer {keyHash = C.KeyHash kh} proxyAuth =
  sendSMPCommand c Nothing "" (PRXY relayServ proxyAuth) >>= \case
    -- XXX: rfc says sessionId should be in the entityId of response
    PKEY sId vr (chain, key) -> do
      case supportedClientSMPRelayVRange `compatibleVersion` vr of
        Nothing -> throwE PCEIncompatibleHost -- TODO different error
        Just (Compatible v) -> liftEitherWith x509Error $ (sId,v,) <$> validateRelay chain key
    r -> throwE . PCEUnexpectedResponse $ bshow r
  where
    x509Error :: String -> SMPClientError
    x509Error _msg = PCEResponseError $ error "TODO: x509 error" -- TODO different error
    validateRelay :: X.CertificateChain -> X.SignedExact X.PubKey -> Either String C.PublicKeyX25519
    validateRelay (X.CertificateChain cert) exact = do
      serverKey <- case cert of
        [leaf, ca]
          | XV.Fingerprint kh == XV.getFingerprint ca X.HashSHA256 ->
              C.x509ToPublic (X.certPubKey . X.signedObject $ X.getSigned leaf, []) >>= C.pubKey
        _ -> throwError "bad certificate"
      pubKey <- C.verifyX509 serverKey exact
      C.x509ToPublic (pubKey, []) >>= C.pubKey

-- consider how to process slow responses - is it handled somehow locally or delegated to the caller
-- this method is used in the client
-- sends PFWD :: C.PublicKeyX25519 -> EncTransmission -> Command Sender
-- receives PRES :: EncResponse -> BrokerMsg -- proxy to client
proxySMPMessage ::
  SMPClient ->
  -- proxy session from PKEY
  SessionId ->
  VersionSMP ->
  C.PublicKeyX25519 ->
  -- message to deliver
  Maybe SndPrivateAuthKey ->
  SenderId ->
  MsgFlags ->
  MsgBody ->
  ExceptT SMPClientError IO ()
-- TODO use version
proxySMPMessage c@ProtocolClient {thParams = proxyThParams, client_ = PClient {clientCorrId = g}} sessionId _v serverKey spKey sId flags msg = do
  -- prepare params
  let serverThAuth = (\ta -> ta {serverPeerPubKey = serverKey}) <$> thAuth proxyThParams
      serverThParams = proxyThParams {sessionId, thAuth = serverThAuth}
  (cmdPubKey, cmdPrivKey) <- liftIO . atomically $ C.generateKeyPair @'C.X25519 g
  let cmdSecret = C.dh' serverKey cmdPrivKey
  nonce@(C.CbNonce corrId) <- liftIO . atomically $ C.randomCbNonce g
  -- encode
  let TransmissionForAuth {tForAuth, tToSend} = encodeTransmissionForAuth serverThParams (CorrId corrId, sId, Cmd SSender $ SEND flags msg)
  auth <- liftEitherWith PCETransportError $ authTransmission serverThAuth spKey nonce tForAuth
  b <- case batchTransmissions (batch serverThParams) (blockSize serverThParams) [Right (auth, tToSend)] of
    [] -> throwE $ PCETransportError TELargeMsg -- some other error. Internal?
    TBError e _ : _ -> throwE $ PCETransportError e -- large message error?
    TBTransmission s _ : _ -> pure s
    TBTransmissions s _ _ : _ -> pure s
  et <- liftEitherWith PCECryptoError $ EncTransmission <$> C.cbEncrypt cmdSecret nonce b paddedProxiedMsgLength
  sendProtocolCommand_ c (Just nonce) Nothing sessionId (Cmd SProxiedClient (PFWD cmdPubKey et)) >>= \case
    -- TODO support PKEY + resend?
    PRES (EncResponse er) -> do
      t' <- liftEitherWith PCECryptoError $ C.cbDecrypt cmdSecret (C.reverseNonce nonce) er
      case tParse proxyThParams t' of
        t'' :| [] -> case tDecodeParseValidate proxyThParams t'' of
          (_auth, _signed, (_c, _e, r)) -> case r of -- TODO: verify
            Left e -> throwE $ PCEResponseError e
            Right OK -> pure ()
            Right (ERR e) -> throwE $ PCEProtocolError e
            Right u -> throwE . PCEUnexpectedResponse $ bshow u -- possibly differentiate unexpected response from server/proxy
        _ -> throwE $ PCETransportError TEBadBlock
    r -> throwE . PCEUnexpectedResponse $ bshow r -- from proxy

-- this method is used in the proxy
-- sends RFWD :: EncFwdTransmission -> Command Sender
-- receives RRES :: EncFwdResponse -> BrokerMsg
-- proxy should send PRES to the client with EncResponse
forwardSMPMessage :: SMPClient -> CorrId -> C.PublicKeyX25519 -> EncTransmission -> ExceptT SMPClientError IO EncResponse
forwardSMPMessage c@ProtocolClient {thParams, client_ = PClient {clientCorrId = g}} fwdCorrId fwdKey fwdTransmission = do
  -- prepare params
  sessSecret <- case thAuth thParams of
    Nothing -> throwError $ PCEProtocolError INTERNAL -- different error - proxy didn't pass key?
    Just THAuthClient {sessSecret} -> maybe (throwError $ PCEProtocolError INTERNAL) pure sessSecret
  nonce <- liftIO . atomically $ C.randomCbNonce g
  -- wrap
  let fwdT = FwdTransmission {fwdCorrId, fwdKey, fwdTransmission}
      eft = EncFwdTransmission $ C.cbEncryptNoPad sessSecret nonce (smpEncode fwdT)
  -- send
  sendProtocolCommand_ c (Just nonce) Nothing "" (Cmd SSender (RFWD eft)) >>= \case
    RRES (EncFwdResponse efr) -> do
      -- unwrap
      r' <- liftEitherWith PCECryptoError $ C.cbDecryptNoPad sessSecret (C.reverseNonce nonce) efr
      FwdResponse {fwdCorrId = _, fwdResponse} <- liftEitherWith (const $ PCEResponseError BLOCK) $ smpDecode r'
      pure fwdResponse
    r -> throwE . PCEUnexpectedResponse $ bshow r

okSMPCommand :: PartyI p => Command p -> SMPClient -> C.APrivateAuthKey -> QueueId -> ExceptT SMPClientError IO ()
okSMPCommand cmd c pKey qId =
  sendSMPCommand c (Just pKey) qId cmd >>= \case
    OK -> return ()
    r -> throwE . PCEUnexpectedResponse $ bshow r

okSMPCommands :: PartyI p => Command p -> SMPClient -> NonEmpty (C.APrivateAuthKey, QueueId) -> IO (NonEmpty (Either SMPClientError ()))
okSMPCommands cmd c qs = L.map process <$> sendProtocolCommands c cs
  where
    aCmd = Cmd sParty cmd
    cs = L.map (\(pKey, qId) -> (Just pKey, qId, aCmd)) qs
    process (Response _ r) = case r of
      Right OK -> Right ()
      Right r' -> Left . PCEUnexpectedResponse $ bshow r'
      Left e -> Left e

-- | Send SMP command
sendSMPCommand :: PartyI p => SMPClient -> Maybe C.APrivateAuthKey -> QueueId -> Command p -> ExceptT SMPClientError IO BrokerMsg
sendSMPCommand c pKey qId cmd = sendProtocolCommand c pKey qId (Cmd sParty cmd)
{-# INLINE sendSMPCommand #-}

type PCTransmission err msg = (Either TransportError SentRawTransmission, Request err msg)

-- | Send multiple commands with batching and collect responses
sendProtocolCommands :: forall v err msg. ProtocolEncoding v err (ProtoCommand msg) => ProtocolClient v err msg -> NonEmpty (ClientCommand msg) -> IO (NonEmpty (Response err msg))
sendProtocolCommands c@ProtocolClient {thParams = THandleParams {batch, blockSize}} cs = do
  bs <- batchTransmissions' batch blockSize <$> mapM (mkTransmission c) cs
  validate . concat =<< mapM (sendBatch c) bs
  where
    validate :: [Response err msg] -> IO (NonEmpty (Response err msg))
    validate rs
      | diff == 0 = pure $ L.fromList rs
      | diff > 0 = do
          putStrLn "send error: fewer responses than expected"
          pure $ L.fromList $ rs <> replicate diff (Response "" $ Left $ PCETransportError TEBadBlock)
      | otherwise = do
          putStrLn "send error: more responses than expected"
          pure $ L.fromList $ take (L.length cs) rs
      where
        diff = L.length cs - length rs

streamProtocolCommands :: forall v err msg. ProtocolEncoding v err (ProtoCommand msg) => ProtocolClient v err msg -> NonEmpty (ClientCommand msg) -> ([Response err msg] -> IO ()) -> IO ()
streamProtocolCommands c@ProtocolClient {thParams = THandleParams {batch, blockSize}} cs cb = do
  bs <- batchTransmissions' batch blockSize <$> mapM (mkTransmission c) cs
  mapM_ (cb <=< sendBatch c) bs

sendBatch :: ProtocolClient v err msg -> TransportBatch (Request err msg) -> IO [Response err msg]
sendBatch c@ProtocolClient {client_ = PClient {sndQ}} b = do
  case b of
    TBError e Request {entityId} -> do
      putStrLn "send error: large message"
      pure [Response entityId $ Left $ PCETransportError e]
    TBTransmissions s n rs
      | n > 0 -> do
          atomically $ writeTBQueue sndQ s
          mapConcurrently (getResponse c) rs
      | otherwise -> pure []
    TBTransmission s r -> do
      atomically $ writeTBQueue sndQ s
      (: []) <$> getResponse c r

-- | Send Protocol command
sendProtocolCommand :: forall v err msg. ProtocolEncoding v err (ProtoCommand msg) => ProtocolClient v err msg -> Maybe C.APrivateAuthKey -> EntityId -> ProtoCommand msg -> ExceptT (ProtocolClientError err) IO msg
sendProtocolCommand c = sendProtocolCommand_ c Nothing

sendProtocolCommand_ :: forall v err msg. ProtocolEncoding v err (ProtoCommand msg) => ProtocolClient v err msg -> Maybe C.CbNonce -> Maybe C.APrivateAuthKey -> EntityId -> ProtoCommand msg -> ExceptT (ProtocolClientError err) IO msg
sendProtocolCommand_ c@ProtocolClient {client_ = PClient {sndQ}, thParams = THandleParams {batch, blockSize}} nonce_ pKey entId cmd =
  ExceptT $ uncurry sendRecv =<< mkTransmission_ c nonce_ (pKey, entId, cmd)
  where
    -- two separate "atomically" needed to avoid blocking
    sendRecv :: Either TransportError SentRawTransmission -> Request err msg -> IO (Either (ProtocolClientError err) msg)
    sendRecv t_ r = case t_ of
      Left e -> pure . Left $ PCETransportError e
      Right t
        | B.length s > blockSize - 2 -> pure . Left $ PCETransportError TELargeMsg
        | otherwise -> atomically (writeTBQueue sndQ s) >> response <$> getResponse c r
        where
          s
            | batch = tEncodeBatch1 t
            | otherwise = tEncode t

-- TODO switch to timeout or TimeManager that supports Int64
getResponse :: ProtocolClient v err msg -> Request err msg -> IO (Response err msg)
getResponse ProtocolClient {client_ = PClient {tcpTimeout, pingErrorCount}} Request {entityId, responseVar} = do
  response <-
    timeout tcpTimeout (atomically (takeTMVar responseVar)) >>= \case
      -- BTW: another registerDelay candidate. Also, crashes caller with BlockedIndef.
      Just r -> atomically (writeTVar pingErrorCount 0) $> r
      Nothing -> pure $ Left PCEResponseTimeout
  pure Response {entityId, response}

mkTransmission :: ProtocolEncoding v err (ProtoCommand msg) => ProtocolClient v err msg -> ClientCommand msg -> IO (PCTransmission err msg)
mkTransmission c = mkTransmission_ c Nothing

mkTransmission_ :: forall v err msg. ProtocolEncoding v err (ProtoCommand msg) => ProtocolClient v err msg -> Maybe C.CbNonce -> ClientCommand msg -> IO (PCTransmission err msg)
mkTransmission_ ProtocolClient {thParams, client_ = PClient {clientCorrId, sentCommands}} nonce_ (pKey_, entId, cmd) = do
  nonce@(C.CbNonce corrId) <- maybe (atomically $ C.randomCbNonce clientCorrId) pure nonce_
  let TransmissionForAuth {tForAuth, tToSend} = encodeTransmissionForAuth thParams (CorrId corrId, entId, cmd)
      auth = authTransmission (thAuth thParams) pKey_ nonce tForAuth
  r <- atomically $ mkRequest (CorrId corrId)
  pure ((,tToSend) <$> auth, r)
  where
    mkRequest :: CorrId -> STM (Request err msg)
    mkRequest corrId = do
      r <- Request entId <$> newEmptyTMVar
      TM.insert corrId r sentCommands
      pure r

authTransmission :: Maybe (THandleAuth 'TClient) -> Maybe C.APrivateAuthKey -> C.CbNonce -> ByteString -> Either TransportError (Maybe TransmissionAuth)
authTransmission thAuth pKey_ nonce t = traverse authenticate pKey_
  where
    authenticate :: C.APrivateAuthKey -> Either TransportError TransmissionAuth
    authenticate (C.APrivateAuthKey a pk) = case a of
      C.SX25519 -> case thAuth of
        Just THAuthClient {serverPeerPubKey = k} -> Right $ TAAuthenticator $ C.cbAuthenticate k pk nonce t
        Nothing -> Left TENoServerAuth
      C.SEd25519 -> sign pk
      C.SEd448 -> sign pk
    sign :: forall a. (C.AlgorithmI a, C.SignatureAlgorithm a) => C.PrivateKey a -> Either TransportError TransmissionAuth
    sign pk = Right $ TASignature $ C.ASignature (C.sAlgorithm @a) (C.sign' pk t)

$(J.deriveJSON (enumJSON $ dropPrefix "HM") ''HostMode)

$(J.deriveJSON (enumJSON $ dropPrefix "TSM") ''TransportSessionMode)

$(J.deriveJSON defaultJSON ''NetworkConfig)
