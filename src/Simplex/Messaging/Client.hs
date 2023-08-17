{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
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
    ProtocolClient (thVersion, sessionId, sessionTs),
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
    sendProtocolCommand,

    -- * Supporting types and client configuration
    ProtocolClientError (..),
    SMPClientError,
    ProtocolClientConfig (..),
    NetworkConfig (..),
    TransportSessionMode (..),
    defaultClientConfig,
    defaultNetworkConfig,
    transportClientConfig,
    chooseTransportHost,
    proxyUsername,
    temporaryClientError,
    ServerTransmission,
    ClientCommand,

    -- * For testing
    ClientBatch (..),
    PCTransmission,
    batchClientTransmissions,
    mkTransmission,
    clientStub,
  )
where

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except
import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Aeson as J
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import Data.Maybe (fromMaybe)
import Data.Time.Clock (UTCTime, getCurrentTime)
import GHC.Generics (Generic)
import Network.Socket (ServiceName)
import Numeric.Natural
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (dropPrefix, enumJSON)
import Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Client (SocksProxy, TransportClientConfig (..), TransportHost (..), runTransportClient)
import Simplex.Messaging.Transport.KeepAlive
import Simplex.Messaging.Transport.WebSockets (WS)
import Simplex.Messaging.Util (bshow, raceAny_, threadDelay')
import Simplex.Messaging.Version
import System.Timeout (timeout)

-- | 'SMPClient' is a handle used to send commands to a specific SMP server.
--
-- Use 'getSMPClient' to connect to an SMP server and create a client handle.
data ProtocolClient err msg = ProtocolClient
  { action :: Maybe (Async ()),
    sessionId :: SessionId,
    sessionTs :: UTCTime,
    thVersion :: Version,
    timeoutPerBlock :: Int,
    blockSize :: Int,
    batch :: Bool,
    client_ :: PClient err msg
  }

data PClient err msg = PClient
  { connected :: TVar Bool,
    transportSession :: TransportSession msg,
    transportHost :: TransportHost,
    tcpTimeout :: Int,
    batchDelay :: Maybe Int,
    pingErrorCount :: TVar Int,
    clientCorrId :: TVar Natural,
    sentCommands :: TMap CorrId (Request err msg),
    sndQ :: TBQueue ByteString,
    rcvQ :: TBQueue (NonEmpty (SignedTransmission err msg)),
    msgQ :: Maybe (TBQueue (ServerTransmission msg))
  }

clientStub :: ByteString -> STM (ProtocolClient err msg)
clientStub sessionId = do
  connected <- newTVar False
  clientCorrId <- newTVar 0
  sentCommands <- TM.empty
  sndQ <- newTBQueue 100
  rcvQ <- newTBQueue 100
  return
    ProtocolClient
      { action = Nothing,
        sessionId,
        sessionTs = undefined,
        thVersion = 5,
        timeoutPerBlock = undefined,
        blockSize = smpBlockSize,
        batch = undefined,
        client_ =
          PClient
            { connected,
              transportSession = undefined,
              transportHost = undefined,
              tcpTimeout = undefined,
              batchDelay = Nothing,
              pingErrorCount = undefined,
              clientCorrId,
              sentCommands,
              sndQ,
              rcvQ,
              msgQ = Nothing
            }
      }

type SMPClient = ProtocolClient ErrorType SMP.BrokerMsg

-- | Type for client command data
type ClientCommand msg = (Maybe C.APrivateSignKey, QueueId, ProtoCommand msg)

-- | Type synonym for transmission from some SPM server queue.
type ServerTransmission msg = (TransportSession msg, Version, SessionId, QueueId, msg)

data HostMode
  = -- | prefer (or require) onion hosts when connecting via SOCKS proxy
    HMOnionViaSocks
  | -- | prefer (or require) onion hosts
    HMOnion
  | -- | prefer (or require) public hosts
    HMPublic
  deriving (Eq, Show, Generic)

instance FromJSON HostMode where
  parseJSON = J.genericParseJSON . enumJSON $ dropPrefix "HM"

instance ToJSON HostMode where
  toJSON = J.genericToJSON . enumJSON $ dropPrefix "HM"
  toEncoding = J.genericToEncoding . enumJSON $ dropPrefix "HM"

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
    tcpTimeoutPerKb :: Int,
    -- | TCP keep-alive options, Nothing to skip enabling keep-alive
    tcpKeepAlive :: Maybe KeepAliveOpts,
    -- | period for SMP ping commands (microseconds, 0 to disable)
    smpPingInterval :: Int64,
    -- | the count of PING errors after which SMP client terminates (and will be reconnected), 0 to disable
    smpPingCount :: Int,
    logTLSErrors :: Bool
  }
  deriving (Eq, Show, Generic, FromJSON)

instance ToJSON NetworkConfig where
  toJSON = J.genericToJSON J.defaultOptions {J.omitNothingFields = True}
  toEncoding = J.genericToEncoding J.defaultOptions {J.omitNothingFields = True}

data TransportSessionMode = TSMUser | TSMEntity
  deriving (Eq, Show, Generic)

instance ToJSON TransportSessionMode where
  toJSON = J.genericToJSON . enumJSON $ dropPrefix "TSM"
  toEncoding = J.genericToEncoding . enumJSON $ dropPrefix "TSM"

instance FromJSON TransportSessionMode where
  parseJSON = J.genericParseJSON . enumJSON $ dropPrefix "TSM"

defaultNetworkConfig :: NetworkConfig
defaultNetworkConfig =
  NetworkConfig
    { socksProxy = Nothing,
      hostMode = HMOnionViaSocks,
      requiredHostMode = False,
      sessionMode = TSMUser,
      tcpConnectTimeout = 15_000_000,
      tcpTimeout = 10_000_000,
      tcpTimeoutPerKb = 20_000, -- 20ms, should be less than 130ms to avoid Int overflow on 32 bit systems
      tcpKeepAlive = Just defaultKeepAliveOpts,
      smpPingInterval = 600_000_000, -- 10min
      smpPingCount = 3,
      logTLSErrors = False
    }

transportClientConfig :: NetworkConfig -> TransportClientConfig
transportClientConfig NetworkConfig {socksProxy, tcpKeepAlive, logTLSErrors} =
  TransportClientConfig {socksProxy, tcpKeepAlive, logTLSErrors}

-- | protocol client configuration.
data ProtocolClientConfig = ProtocolClientConfig
  { -- | size of TBQueue to use for server commands and responses
    qSize :: Natural,
    -- | default server port if port is not specified in ProtocolServer
    defaultTransport :: (ServiceName, ATransport),
    -- | network configuration
    networkConfig :: NetworkConfig,
    -- | client-server protocol version range
    serverVRange :: VersionRange,
    -- | delay between sending batches of commands (microseconds)
    batchDelay :: Maybe Int
  }

-- | Default protocol client configuration.
defaultClientConfig :: ProtocolClientConfig
defaultClientConfig =
  ProtocolClientConfig
    { qSize = 64,
      defaultTransport = ("443", transport @TLS),
      networkConfig = defaultNetworkConfig,
      serverVRange = supportedSMPServerVRange,
      batchDelay = Nothing
    }

data Request err msg = Request
  { queueId :: QueueId,
    responseVar :: TResponse err msg
  }

type Response err msg = Either (ProtocolClientError err) msg

type TResponse err msg = TMVar (Response err msg)

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

protocolClientServer :: ProtocolTypeI (ProtoType msg) => ProtocolClient err msg -> String
protocolClientServer = B.unpack . strEncode . snd3 . transportSession . client_
  where
    snd3 (_, s, _) = s

transportHost' :: ProtocolClient err msg -> TransportHost
transportHost' = transportHost . client_

transportSession' :: ProtocolClient err msg -> TransportSession msg
transportSession' = transportSession . client_

type UserId = Int64

-- | Transport session key - includes entity ID if `sessionMode = TSMEntity`.
type TransportSession msg = (UserId, ProtoServer msg, Maybe EntityId)

-- | Connects to 'ProtocolServer' using passed client configuration
-- and queue for messages and notifications.
--
-- A single queue can be used for multiple 'SMPClient' instances,
-- as 'SMPServerTransmission' includes server information.
getProtocolClient :: forall err msg. Protocol err msg => TransportSession msg -> ProtocolClientConfig -> Maybe (TBQueue (ServerTransmission msg)) -> (ProtocolClient err msg -> IO ()) -> IO (Either (ProtocolClientError err) (ProtocolClient err msg))
getProtocolClient transportSession@(_, srv, _) cfg@ProtocolClientConfig {qSize, networkConfig, serverVRange, batchDelay} msgQ disconnected = do
  case chooseTransportHost networkConfig (host srv) of
    Right useHost ->
      (atomically (mkProtocolClient useHost) >>= runClient useTransport useHost)
        `catch` \(e :: IOException) -> pure . Left $ PCEIOError e
    Left e -> pure $ Left e
  where
    NetworkConfig {tcpConnectTimeout, tcpTimeout, tcpTimeoutPerKb, smpPingInterval} = networkConfig
    mkProtocolClient :: TransportHost -> STM (PClient err msg)
    mkProtocolClient transportHost = do
      connected <- newTVar False
      pingErrorCount <- newTVar 0
      clientCorrId <- newTVar 0
      sentCommands <- TM.empty
      sndQ <- newTBQueue qSize
      rcvQ <- newTBQueue qSize
      return
        PClient
          { connected,
            transportSession,
            transportHost,
            tcpTimeout,
            batchDelay,
            pingErrorCount,
            clientCorrId,
            sentCommands,
            sndQ,
            rcvQ,
            msgQ
          }

    runClient :: (ServiceName, ATransport) -> TransportHost -> PClient err msg -> IO (Either (ProtocolClientError err) (ProtocolClient err msg))
    runClient (port', ATransport t) useHost c = do
      cVar <- newEmptyTMVarIO
      let tcConfig = transportClientConfig networkConfig
          username = proxyUsername transportSession
      action <-
        async $
          runTransportClient tcConfig (Just username) useHost port' (Just $ keyHash srv) (client t c cVar)
            `finally` atomically (putTMVar cVar $ Left PCENetworkError)
      c_ <- tcpConnectTimeout `timeout` atomically (takeTMVar cVar)
      pure $ case c_ of
        Just (Right c') -> Right c' {action = Just action}
        Just (Left e) -> Left e
        Nothing -> Left PCENetworkError

    useTransport :: (ServiceName, ATransport)
    useTransport = case port srv of
      "" -> defaultTransport cfg
      "80" -> ("80", transport @WS)
      p -> (p, transport @TLS)

    client :: forall c. Transport c => TProxy c -> PClient err msg -> TMVar (Either (ProtocolClientError err) (ProtocolClient err msg)) -> c -> IO ()
    client _ c cVar h =
      runExceptT (protocolClientHandshake @err @msg h (keyHash srv) serverVRange) >>= \case
        Left e -> atomically . putTMVar cVar . Left $ PCETransportError e
        Right th@THandle {sessionId, thVersion, blockSize, batch} -> do
          sessionTs <- getCurrentTime
          let timeoutPerBlock = (blockSize * tcpTimeoutPerKb) `div` 1024
              c' = ProtocolClient {action = Nothing, client_ = c, sessionId, thVersion, sessionTs, timeoutPerBlock, blockSize, batch}
          atomically $ do
            writeTVar (connected c) True
            putTMVar cVar $ Right c'
          raceAny_ ([send c' th, process c', receive c' th] <> [ping c' | smpPingInterval > 0])
            `finally` disconnected c'

    send :: Transport c => ProtocolClient err msg -> THandle c -> IO ()
    send ProtocolClient {client_ = PClient {sndQ}} h = forever $ atomically (readTBQueue sndQ) >>= tPutLog h

    receive :: Transport c => ProtocolClient err msg -> THandle c -> IO ()
    receive ProtocolClient {client_ = PClient {rcvQ}} h = forever $ tGet h >>= atomically . writeTBQueue rcvQ

    ping :: ProtocolClient err msg -> IO ()
    ping c@ProtocolClient {client_ = PClient {pingErrorCount}} = do
      threadDelay' smpPingInterval
      runExceptT (sendProtocolCommand c Nothing "" $ protocolPing @err @msg) >>= \case
        Left PCEResponseTimeout -> do
          cnt <- atomically $ stateTVar pingErrorCount $ \cnt -> (cnt + 1, cnt + 1)
          when (maxCnt == 0 || cnt < maxCnt) $ ping c
        _ -> ping c -- sendProtocolCommand resets pingErrorCount
      where
        maxCnt = smpPingCount networkConfig

    process :: ProtocolClient err msg -> IO ()
    process c = forever $ atomically (readTBQueue $ rcvQ $ client_ c) >>= mapM_ (processMsg c)

    processMsg :: ProtocolClient err msg -> SignedTransmission err msg -> IO ()
    processMsg c@ProtocolClient {client_ = PClient {sentCommands}} (_, _, (corrId, qId, respOrErr)) =
      if B.null $ bs corrId
        then sendMsg respOrErr
        else do
          atomically (TM.lookup corrId sentCommands) >>= \case
            Nothing -> sendMsg respOrErr
            Just Request {queueId, responseVar} -> atomically $ do
              TM.delete corrId sentCommands
              putTMVar responseVar $
                if queueId == qId
                  then case respOrErr of
                    Left e -> Left $ PCEResponseError e
                    Right r -> case protocolError r of
                      Just e -> Left $ PCEProtocolError e
                      _ -> Right r
                  else Left . PCEUnexpectedResponse $ bshow respOrErr
      where
        sendMsg :: Either err msg -> IO ()
        sendMsg = \case
          Right msg -> atomically $ mapM_ (`writeTBQueue` serverTransmission c qId msg) msgQ
          Left e -> putStrLn $ "SMP client error: " <> show e

proxyUsername :: TransportSession msg -> ByteString
proxyUsername (userId, _, entityId_) = C.sha256Hash $ bshow userId <> maybe "" (":" <>) entityId_

-- | Disconnects client from the server and terminates client threads.
closeProtocolClient :: ProtocolClient err msg -> IO ()
closeProtocolClient = mapM_ uninterruptibleCancel . action

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

-- | Create a new SMP queue.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#create-queue-command
createSMPQueue ::
  SMPClient ->
  RcvPrivateSignKey ->
  RcvPublicVerifyKey ->
  RcvPublicDhKey ->
  Maybe BasicAuth ->
  ExceptT SMPClientError IO QueueIdsKeys
createSMPQueue c rpKey rKey dhKey auth =
  sendSMPCommand c (Just rpKey) "" (NEW rKey dhKey auth) >>= \case
    IDS qik -> pure qik
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Subscribe to the SMP queue.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#subscribe-to-queue
subscribeSMPQueue :: SMPClient -> RcvPrivateSignKey -> RecipientId -> ExceptT SMPClientError IO ()
subscribeSMPQueue c rpKey rId =
  sendSMPCommand c (Just rpKey) rId SUB >>= \case
    OK -> return ()
    cmd@MSG {} -> liftIO $ writeSMPMessage c rId cmd
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Subscribe to multiple SMP queues batching commands if supported.
subscribeSMPQueues :: SMPClient -> NonEmpty (RcvPrivateSignKey, RecipientId) -> IO (NonEmpty (Either SMPClientError ()))
subscribeSMPQueues c qs = sendProtocolCommands c cs >>= mapM response . L.zip qs
  where
    cs = L.map (\(rpKey, rId) -> (Just rpKey, rId, Cmd SRecipient SUB)) qs
    response ((_, rId), r) = case r of
      Right OK -> pure $ Right ()
      Right cmd@MSG {} -> writeSMPMessage c rId cmd $> Right ()
      Right r' -> pure . Left . PCEUnexpectedResponse $ bshow r'
      Left e -> pure $ Left e

writeSMPMessage :: SMPClient -> RecipientId -> BrokerMsg -> IO ()
writeSMPMessage c rId msg = atomically $ mapM_ (`writeTBQueue` serverTransmission c rId msg) (msgQ $ client_ c)

serverTransmission :: ProtocolClient err msg -> RecipientId -> msg -> ServerTransmission msg
serverTransmission ProtocolClient {thVersion, sessionId, client_ = PClient {transportSession}} entityId message =
  (transportSession, thVersion, sessionId, entityId, message)

-- | Get message from SMP queue. The server returns ERR PROHIBITED if a client uses SUB and GET via the same transport connection for the same queue
--
-- https://github.covm/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#receive-a-message-from-the-queue
getSMPMessage :: SMPClient -> RcvPrivateSignKey -> RecipientId -> ExceptT SMPClientError IO (Maybe RcvMessage)
getSMPMessage c rpKey rId =
  sendSMPCommand c (Just rpKey) rId GET >>= \case
    OK -> pure Nothing
    cmd@(MSG msg) -> liftIO (writeSMPMessage c rId cmd) $> Just msg
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Subscribe to the SMP queue notifications.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#subscribe-to-queue-notifications
subscribeSMPQueueNotifications :: SMPClient -> NtfPrivateSignKey -> NotifierId -> ExceptT SMPClientError IO ()
subscribeSMPQueueNotifications = okSMPCommand NSUB

-- | Subscribe to multiple SMP queues notifications batching commands if supported.
subscribeSMPQueuesNtfs :: SMPClient -> NonEmpty (NtfPrivateSignKey, NotifierId) -> IO (NonEmpty (Either SMPClientError ()))
subscribeSMPQueuesNtfs = okSMPCommands NSUB

-- | Secure the SMP queue by adding a sender public key.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#secure-queue-command
secureSMPQueue :: SMPClient -> RcvPrivateSignKey -> RecipientId -> SndPublicVerifyKey -> ExceptT SMPClientError IO ()
secureSMPQueue c rpKey rId senderKey = okSMPCommand (KEY senderKey) c rpKey rId

-- | Enable notifications for the queue for push notifications server.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#enable-notifications-command
enableSMPQueueNotifications :: SMPClient -> RcvPrivateSignKey -> RecipientId -> NtfPublicVerifyKey -> RcvNtfPublicDhKey -> ExceptT SMPClientError IO (NotifierId, RcvNtfPublicDhKey)
enableSMPQueueNotifications c rpKey rId notifierKey rcvNtfPublicDhKey =
  sendSMPCommand c (Just rpKey) rId (NKEY notifierKey rcvNtfPublicDhKey) >>= \case
    NID nId rcvNtfSrvPublicDhKey -> pure (nId, rcvNtfSrvPublicDhKey)
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Enable notifications for the multiple queues for push notifications server.
enableSMPQueuesNtfs :: SMPClient -> NonEmpty (RcvPrivateSignKey, RecipientId, NtfPublicVerifyKey, RcvNtfPublicDhKey) -> IO (NonEmpty (Either SMPClientError (NotifierId, RcvNtfPublicDhKey)))
enableSMPQueuesNtfs c qs = L.map response <$> sendProtocolCommands c cs
  where
    cs = L.map (\(rpKey, rId, notifierKey, rcvNtfPublicDhKey) -> (Just rpKey, rId, Cmd SRecipient $ NKEY notifierKey rcvNtfPublicDhKey)) qs
    response = \case
      Right (NID nId rcvNtfSrvPublicDhKey) -> Right (nId, rcvNtfSrvPublicDhKey)
      Right r -> Left . PCEUnexpectedResponse $ bshow r
      Left e -> Left e

-- | Disable notifications for the queue for push notifications server.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#disable-notifications-command
disableSMPQueueNotifications :: SMPClient -> RcvPrivateSignKey -> RecipientId -> ExceptT SMPClientError IO ()
disableSMPQueueNotifications = okSMPCommand NDEL

-- | Disable notifications for multiple queues for push notifications server.
disableSMPQueuesNtfs :: SMPClient -> NonEmpty (RcvPrivateSignKey, RecipientId) -> IO (NonEmpty (Either SMPClientError ()))
disableSMPQueuesNtfs = okSMPCommands NDEL

-- | Send SMP message.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#send-message
sendSMPMessage :: SMPClient -> Maybe SndPrivateSignKey -> SenderId -> MsgFlags -> MsgBody -> ExceptT SMPClientError IO ()
sendSMPMessage c spKey sId flags msg =
  sendSMPCommand c spKey sId (SEND flags msg) >>= \case
    OK -> pure ()
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Acknowledge message delivery (server deletes the message).
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#acknowledge-message-delivery
ackSMPMessage :: SMPClient -> RcvPrivateSignKey -> QueueId -> MsgId -> ExceptT SMPClientError IO ()
ackSMPMessage c rpKey rId msgId =
  sendSMPCommand c (Just rpKey) rId (ACK msgId) >>= \case
    OK -> return ()
    cmd@MSG {} -> liftIO $ writeSMPMessage c rId cmd
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Irreversibly suspend SMP queue.
-- The existing messages from the queue will still be delivered.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#suspend-queue
suspendSMPQueue :: SMPClient -> RcvPrivateSignKey -> QueueId -> ExceptT SMPClientError IO ()
suspendSMPQueue = okSMPCommand OFF

-- | Irreversibly delete SMP queue and all messages in it.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#delete-queue
deleteSMPQueue :: SMPClient -> RcvPrivateSignKey -> RecipientId -> ExceptT SMPClientError IO ()
deleteSMPQueue = okSMPCommand DEL

-- | Delete multiple SMP queues batching commands if supported.
deleteSMPQueues :: SMPClient -> NonEmpty (RcvPrivateSignKey, RecipientId) -> IO (NonEmpty (Either SMPClientError ()))
deleteSMPQueues = okSMPCommands DEL

okSMPCommand :: PartyI p => Command p -> SMPClient -> C.APrivateSignKey -> QueueId -> ExceptT SMPClientError IO ()
okSMPCommand cmd c pKey qId =
  sendSMPCommand c (Just pKey) qId cmd >>= \case
    OK -> return ()
    r -> throwE . PCEUnexpectedResponse $ bshow r

okSMPCommands :: PartyI p => Command p -> SMPClient -> NonEmpty (C.APrivateSignKey, QueueId) -> IO (NonEmpty (Either SMPClientError ()))
okSMPCommands cmd c qs = L.map response <$> sendProtocolCommands c cs
  where
    aCmd = Cmd sParty cmd
    cs = L.map (\(pKey, qId) -> (Just pKey, qId, aCmd)) qs
    response = \case
      Right OK -> Right ()
      Right r -> Left . PCEUnexpectedResponse $ bshow r
      Left e -> Left e

-- | Send SMP command
sendSMPCommand :: PartyI p => SMPClient -> Maybe C.APrivateSignKey -> QueueId -> Command p -> ExceptT SMPClientError IO BrokerMsg
sendSMPCommand c pKey qId cmd = sendProtocolCommand c pKey qId (Cmd sParty cmd)

type PCTransmission err msg = (SentRawTransmission, TResponse err msg)

-- | Send multiple commands with batching and collect responses
-- TODO switch to timeout or TimeManager that supports Int64
sendProtocolCommands :: forall err msg. ProtocolEncoding err (ProtoCommand msg) => ProtocolClient err msg -> NonEmpty (ClientCommand msg) -> IO (NonEmpty (Response err msg))
sendProtocolCommands c@ProtocolClient {client_ = PClient {sndQ, tcpTimeout}, batch, blockSize} cs = do
  bs <- batchClientTransmissions batch blockSize <$> mapM (runExceptT . mkTransmission c) cs
  validate . concat =<< mapM sendBatch bs
  where
    validate :: [Response err msg] -> IO (NonEmpty (Response err msg))
    validate rs
      | diff == 0 = pure $ L.fromList rs
      | diff > 0 = do
        putStrLn "send error: fewer responses than expected"
        pure $ L.fromList $ rs <> replicate diff (Left $ PCETransportError TEBadBlock)
      | otherwise = do
        putStrLn "send error: more responses than expected"
        pure $ L.fromList $ take (L.length cs) rs
        where
          diff = L.length cs - length rs
    sendBatch :: ClientBatch err msg -> IO [Response err msg]
    sendBatch b = do
      case b of
        CBLargeTransmission -> [Left (PCETransportError TELargeMsg)] <$ putStrLn "send error: large message"
        CBTransmissions n s rs -> do
          when (n > 0) $ atomically $ writeTBQueue sndQ $ tEncodeBatch n s
          forConcurrently rs $ \case
            Right r -> withTimeout c tcpTimeout (atomically $ takeTMVar r)
            Left e -> pure $ Left e
        CBTransmission s r -> do
          atomically $ writeTBQueue sndQ s
          (: []) <$> withTimeout c tcpTimeout (atomically $ takeTMVar r)

-- ByteString does not include length byte, it is added by tEncodeBatch
type PCTransmissionOrErr err msg = Either (ProtocolClientError err) (PCTransmission err msg)

type TResponseOrErr err msg = Either (ProtocolClientError err) (TResponse err msg)

data ClientBatch err msg
  = CBTransmissions Int ByteString [TResponseOrErr err msg]
  | CBTransmission ByteString (TResponse err msg)
  | CBLargeTransmission

-- | encodes and batches transmissions into blocks, 
batchClientTransmissions :: forall err msg. Bool -> Int -> NonEmpty (PCTransmissionOrErr err msg) -> [ClientBatch err msg]
batchClientTransmissions batch bSize
  | batch = reverse . mkBatch []
  | otherwise = map mkBatch1 . L.toList
  where
    mkBatch :: [ClientBatch err msg] -> NonEmpty (PCTransmissionOrErr err msg) -> [ClientBatch err msg]
    mkBatch bs ts =
      let (b, ts_) = encodeBatch 0 "" [] ts
          bs' = b : bs
       in maybe bs' (mkBatch bs') ts_
    mkBatch1 :: PCTransmissionOrErr err msg -> ClientBatch err msg
    mkBatch1 = \case
      Left e -> CBTransmissions 0 "" [Left e]
      Right (t, r) ->
        let s = tEncode t
         in if B.length s > bSize - 2 then CBLargeTransmission else CBTransmission s r
    encodeBatch :: Int -> ByteString -> [TResponseOrErr err msg] -> NonEmpty (PCTransmissionOrErr err msg) -> (ClientBatch err msg, Maybe (NonEmpty (PCTransmissionOrErr err msg)))
    encodeBatch n s rs ts@(t_ :| ts_)
      | n == 255 = (res, Just ts)
      | otherwise = case t_ of
          Left e -> next n s (Left e : rs)
          Right (t, r)
            | B.length s' <= bSize - 3 -> next (n + 1) s' (Right r : rs)
            | null rs -> (CBLargeTransmission, L.nonEmpty ts_)
            | otherwise -> (res, Just ts)
            where
              s' = s <> smpEncode (Large $ tEncode t)
      where
        res = CBTransmissions n s (reverse rs)
        next n' s' rs' = case L.nonEmpty ts_ of
          Just ts' -> encodeBatch n' s' rs' ts'
          Nothing -> (CBTransmissions n' s' (reverse rs'), Nothing)

-- | Send Protocol command
sendProtocolCommand :: forall err msg. ProtocolEncoding err (ProtoCommand msg) => ProtocolClient err msg -> Maybe C.APrivateSignKey -> QueueId -> ProtoCommand msg -> ExceptT (ProtocolClientError err) IO msg
sendProtocolCommand c@ProtocolClient {client_ = PClient {sndQ, tcpTimeout}, batch, blockSize} pKey qId cmd = do
  (t, r) <- mkTransmission c (pKey, qId, cmd)
  ExceptT $ sendRecv t r
  where
    -- two separate "atomically" needed to avoid blocking
    sendRecv :: SentRawTransmission -> TResponse err msg -> IO (Response err msg)
    sendRecv t r
      | B.length s > blockSize - 2 = pure $ Left $ PCETransportError TELargeMsg
      | otherwise = atomically (writeTBQueue sndQ s) >> withTimeout c tcpTimeout (atomically $ takeTMVar r)
      where
        s
          | batch = tEncodeBatch 1 . smpEncode . Large $ tEncode t
          | otherwise = tEncode t

withTimeout :: ProtocolClient err msg -> Int -> IO (Response err msg) -> IO (Response err msg)
withTimeout ProtocolClient {client_ = PClient {pingErrorCount}} t a = do
  timeout t a >>= \case
    Just r -> atomically (writeTVar pingErrorCount 0) >> pure r
    _ -> pure $ Left PCEResponseTimeout

mkTransmission :: forall err msg. ProtocolEncoding err (ProtoCommand msg) => ProtocolClient err msg -> ClientCommand msg -> ExceptT (ProtocolClientError err) IO (PCTransmission err msg)
mkTransmission ProtocolClient {sessionId, thVersion, client_ = PClient {clientCorrId, sentCommands}} (pKey, qId, cmd) = do
  corrId <- liftIO $ atomically getNextCorrId
  let t = signTransmission $ encodeTransmission thVersion sessionId (corrId, qId, cmd)
  r <- liftIO . atomically $ mkRequest corrId
  pure (t, r)
  where
    getNextCorrId :: STM CorrId
    getNextCorrId = do
      i <- stateTVar clientCorrId $ \i -> (i, i + 1)
      pure . CorrId $ bshow i
    signTransmission :: ByteString -> SentRawTransmission
    signTransmission t = ((`C.sign` t) <$> pKey, t)
    mkRequest :: CorrId -> STM (TResponse err msg)
    mkRequest corrId = do
      r <- newEmptyTMVar
      TM.insert corrId (Request qId r) sentCommands
      pure r
