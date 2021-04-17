{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Client
  ( SMPClient,
    getSMPClient,
    closeSMPClient,
    createSMPQueue,
    subscribeSMPQueue,
    secureSMPQueue,
    sendSMPMessage,
    ackSMPMessage,
    sendSMPCommand,
    suspendSMPQueue,
    deleteSMPQueue,
    SMPClientError (..),
    SMPClientConfig (..),
    smpDefaultConfig,
    SMPServerTransmission,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Control.Monad.Trans.Class
import Control.Monad.Trans.Except
import qualified Crypto.PubKey.RSA.Types as RSA
import Data.ByteString.Char8 (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe
import Network.Socket (ServiceName)
import Numeric.Natural
import Simplex.Messaging.Agent.Transmission (SMPServer (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Transport
import Simplex.Messaging.Util (bshow, liftEitherError, raceAny_)
import System.IO
import System.Timeout

data SMPClient = SMPClient
  { action :: Async (),
    connected :: TVar Bool,
    smpServer :: SMPServer,
    tcpTimeout :: Int,
    clientCorrId :: TVar Natural,
    sentCommands :: TVar (Map CorrId Request),
    sndQ :: TBQueue SignedRawTransmission,
    rcvQ :: TBQueue SignedTransmissionOrError,
    msgQ :: TBQueue SMPServerTransmission
  }

type SMPServerTransmission = (SMPServer, RecipientId, Command 'Broker)

data SMPClientConfig = SMPClientConfig
  { qSize :: Natural,
    defaultPort :: ServiceName,
    tcpTimeout :: Int,
    smpPing :: Int,
    blockSize :: Int,
    smpCommandSize :: Int
  }

smpDefaultConfig :: SMPClientConfig
smpDefaultConfig =
  SMPClientConfig
    { qSize = 16,
      defaultPort = "5223",
      tcpTimeout = 4_000_000,
      smpPing = 30_000_000,
      blockSize = 8_192, -- 16_384,
      smpCommandSize = 256
    }

data Request = Request
  { queueId :: QueueId,
    responseVar :: TMVar Response
  }

type Response = Either SMPClientError Cmd

getSMPClient :: SMPServer -> SMPClientConfig -> TBQueue SMPServerTransmission -> IO () -> IO (Either SMPClientError SMPClient)
getSMPClient
  smpServer@SMPServer {host, port, keyHash}
  SMPClientConfig {qSize, defaultPort, tcpTimeout, smpPing}
  msgQ
  disconnected = do
    c <- atomically mkSMPClient
    err <- newEmptyTMVarIO
    action <-
      async $
        runTCPClient host (fromMaybe defaultPort port) (client c err)
          `finally` atomically (putTMVar err $ Just SMPNetworkError)
    tcpTimeout `timeout` atomically (takeTMVar err) >>= \case
      Just Nothing -> pure $ Right c {action}
      Just (Just e) -> pure $ Left e
      Nothing -> pure $ Left SMPNetworkError
    where
      mkSMPClient :: STM SMPClient
      mkSMPClient = do
        connected <- newTVar False
        clientCorrId <- newTVar 0
        sentCommands <- newTVar M.empty
        sndQ <- newTBQueue qSize
        rcvQ <- newTBQueue qSize
        return
          SMPClient
            { action = undefined,
              connected,
              smpServer,
              tcpTimeout,
              clientCorrId,
              sentCommands,
              sndQ,
              rcvQ,
              msgQ
            }

      client :: SMPClient -> TMVar (Maybe SMPClientError) -> Handle -> IO ()
      client c err h =
        runExceptT (clientHandshake h keyHash) >>= \case
          Right th -> clientTransport c err th
          Left _ -> atomically . putTMVar err $ Just SMPTransportError

      clientTransport :: SMPClient -> TMVar (Maybe SMPClientError) -> THandle -> IO ()
      clientTransport c err th = do
        atomically $ do
          writeTVar (connected c) True
          putTMVar err Nothing
        raceAny_ [send c th, process c, receive c th, ping c]
          `finally` disconnected

      send :: SMPClient -> THandle -> IO ()
      send SMPClient {sndQ} h = forever $ atomically (readTBQueue sndQ) >>= tPut h

      receive :: SMPClient -> THandle -> IO ()
      receive SMPClient {rcvQ} h = forever $ tGet fromServer h >>= atomically . writeTBQueue rcvQ

      ping :: SMPClient -> IO ()
      ping c = forever $ do
        threadDelay smpPing
        runExceptT $ sendSMPCommand c Nothing "" (Cmd SSender PING)

      process :: SMPClient -> IO ()
      process SMPClient {rcvQ, sentCommands} = forever $ do
        (_, (corrId, qId, respOrErr)) <- atomically $ readTBQueue rcvQ
        cs <- readTVarIO sentCommands
        case M.lookup corrId cs of
          Nothing -> do
            case respOrErr of
              Right (Cmd SBroker cmd) -> atomically $ writeTBQueue msgQ (smpServer, qId, cmd)
              -- TODO send everything else to errQ and log in agent
              _ -> return ()
          Just Request {queueId, responseVar} -> atomically $ do
            modifyTVar sentCommands $ M.delete corrId
            putTMVar responseVar $
              if queueId == qId
                then case respOrErr of
                  Left e -> Left $ SMPResponseError e
                  Right (Cmd _ (ERR e)) -> Left $ SMPServerError e
                  Right r -> Right r
                else Left SMPQueueIdError

closeSMPClient :: SMPClient -> IO ()
closeSMPClient = uninterruptibleCancel . action

data SMPClientError
  = SMPServerError ErrorType
  | SMPResponseError ErrorType
  | SMPQueueIdError
  | SMPUnexpectedResponse
  | SMPResponseTimeout
  | SMPNetworkError
  | SMPTransportError
  | SMPCryptoError RSA.Error
  deriving (Eq, Show, Exception)

createSMPQueue ::
  SMPClient ->
  RecipientPrivateKey ->
  RecipientPublicKey ->
  ExceptT SMPClientError IO (RecipientId, SenderId)
createSMPQueue c rpKey rKey =
  -- TODO add signing this request too - requires changes in the server
  sendSMPCommand c (Just rpKey) "" (Cmd SRecipient $ NEW rKey) >>= \case
    Cmd _ (IDS rId sId) -> return (rId, sId)
    _ -> throwE SMPUnexpectedResponse

subscribeSMPQueue :: SMPClient -> RecipientPrivateKey -> RecipientId -> ExceptT SMPClientError IO ()
subscribeSMPQueue c@SMPClient {smpServer, msgQ} rpKey rId =
  sendSMPCommand c (Just rpKey) rId (Cmd SRecipient SUB) >>= \case
    Cmd _ OK -> return ()
    Cmd _ cmd@MSG {} ->
      lift . atomically $ writeTBQueue msgQ (smpServer, rId, cmd)
    _ -> throwE SMPUnexpectedResponse

secureSMPQueue :: SMPClient -> RecipientPrivateKey -> RecipientId -> SenderPublicKey -> ExceptT SMPClientError IO ()
secureSMPQueue c rpKey rId senderKey = okSMPCommand (Cmd SRecipient $ KEY senderKey) c rpKey rId

sendSMPMessage :: SMPClient -> Maybe SenderPrivateKey -> SenderId -> MsgBody -> ExceptT SMPClientError IO ()
sendSMPMessage c spKey sId msg =
  sendSMPCommand c spKey sId (Cmd SSender $ SEND msg) >>= \case
    Cmd _ OK -> return ()
    _ -> throwE SMPUnexpectedResponse

ackSMPMessage :: SMPClient -> RecipientPrivateKey -> QueueId -> ExceptT SMPClientError IO ()
ackSMPMessage c@SMPClient {smpServer, msgQ} rpKey rId =
  sendSMPCommand c (Just rpKey) rId (Cmd SRecipient ACK) >>= \case
    Cmd _ OK -> return ()
    Cmd _ cmd@MSG {} ->
      lift . atomically $ writeTBQueue msgQ (smpServer, rId, cmd)
    _ -> throwE SMPUnexpectedResponse

suspendSMPQueue :: SMPClient -> RecipientPrivateKey -> QueueId -> ExceptT SMPClientError IO ()
suspendSMPQueue = okSMPCommand $ Cmd SRecipient OFF

deleteSMPQueue :: SMPClient -> RecipientPrivateKey -> QueueId -> ExceptT SMPClientError IO ()
deleteSMPQueue = okSMPCommand $ Cmd SRecipient DEL

okSMPCommand :: Cmd -> SMPClient -> C.SafePrivateKey -> QueueId -> ExceptT SMPClientError IO ()
okSMPCommand cmd c pKey qId =
  sendSMPCommand c (Just pKey) qId cmd >>= \case
    Cmd _ OK -> return ()
    _ -> throwE SMPUnexpectedResponse

sendSMPCommand :: SMPClient -> Maybe C.SafePrivateKey -> QueueId -> Cmd -> ExceptT SMPClientError IO Cmd
sendSMPCommand SMPClient {sndQ, sentCommands, clientCorrId, tcpTimeout} pKey qId cmd = do
  corrId <- lift_ getNextCorrId
  t <- signTransmission $ serializeTransmission (corrId, qId, cmd)
  ExceptT $ sendRecv corrId t
  where
    lift_ :: STM a -> ExceptT SMPClientError IO a
    lift_ action = ExceptT $ Right <$> atomically action

    getNextCorrId :: STM CorrId
    getNextCorrId = do
      i <- (+ 1) <$> readTVar clientCorrId
      writeTVar clientCorrId i
      return . CorrId $ bshow i

    signTransmission :: ByteString -> ExceptT SMPClientError IO SignedRawTransmission
    signTransmission t = case pKey of
      Nothing -> return ("", t)
      Just pk -> do
        sig <- liftEitherError SMPCryptoError $ C.sign pk t
        return (sig, t)

    -- two separate "atomically" needed to avoid blocking
    sendRecv :: CorrId -> SignedRawTransmission -> IO Response
    sendRecv corrId t =
      fromMaybe (Left SMPResponseTimeout) <$> do
        r <- atomically (send corrId t)
        (timeout tcpTimeout . atomically . takeTMVar) r

    send :: CorrId -> SignedRawTransmission -> STM (TMVar Response)
    send corrId t = do
      r <- newEmptyTMVar
      modifyTVar sentCommands . M.insert corrId $ Request qId r
      writeTBQueue sndQ t
      return r
