{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Client
  ( SMPClient,
    getSMPClient,
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

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Control.Monad.Trans.Class
import Control.Monad.Trans.Except
import qualified Data.ByteString.Char8 as B
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe
import Network.Socket (ServiceName)
import Numeric.Natural
import Simplex.Messaging.Agent.Transmission (SMPServer (..))
import Simplex.Messaging.Types
import Simplex.Messaging.Protocol
import Simplex.Messaging.Transport
import Simplex.Messaging.Util
import System.IO

data SMPClient = SMPClient
  { action :: Async (),
    smpServer :: SMPServer,
    clientCorrId :: TVar Natural,
    sentCommands :: TVar (Map CorrId Request),
    sndQ :: TBQueue Transmission,
    rcvQ :: TBQueue TransmissionOrError,
    msgQ :: TBQueue SMPServerTransmission
  }

type SMPServerTransmission = (SMPServer, RecipientId, Command 'Broker)

data SMPClientConfig = SMPClientConfig
  { qSize :: Natural,
    defaultPort :: ServiceName
  }

smpDefaultConfig :: SMPClientConfig
smpDefaultConfig = SMPClientConfig 16 "5223"

data Request = Request
  { queueId :: QueueId,
    responseVar :: TMVar (Either SMPClientError Cmd)
  }

getSMPClient :: SMPServer -> SMPClientConfig -> TBQueue SMPServerTransmission -> IO SMPClient
getSMPClient smpServer@SMPServer {host, port} SMPClientConfig {qSize, defaultPort} msgQ = do
  c <- atomically mkSMPClient
  action <- async $ runTCPClient host (fromMaybe defaultPort port) (client c)
  return c {action}
  where
    mkSMPClient :: STM SMPClient
    mkSMPClient = do
      clientCorrId <- newTVar 0
      sentCommands <- newTVar M.empty
      sndQ <- newTBQueue qSize
      rcvQ <- newTBQueue qSize
      return SMPClient {action = undefined, smpServer, clientCorrId, sentCommands, sndQ, rcvQ, msgQ}

    client :: SMPClient -> Handle -> IO ()
    client c h = do
      _line <- getLn h -- "Welcome to SMP"
      -- TODO test connection failure
      raceAny_ [send c h, process c, receive c h]

    send :: SMPClient -> Handle -> IO ()
    send SMPClient {sndQ} h = forever $ atomically (readTBQueue sndQ) >>= tPut h

    receive :: SMPClient -> Handle -> IO ()
    receive SMPClient {rcvQ} h = forever $ tGet fromServer h >>= atomically . writeTBQueue rcvQ

    process :: SMPClient -> IO ()
    process SMPClient {rcvQ, sentCommands} = forever $ do
      (_, (corrId, qId, respOrErr)) <- atomically $ readTBQueue rcvQ
      cs <- readTVarIO sentCommands
      case M.lookup corrId cs of
        Nothing -> do
          case respOrErr of
            Right (Cmd SBroker cmd) -> atomically $ writeTBQueue msgQ (smpServer, qId, cmd)
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

data SMPClientError
  = SMPServerError SMPErrorType
  | SMPResponseError SMPErrorType
  | SMPQueueIdError
  | SMPUnexpectedResponse
  | SMPResponseTimeout
  | SMPClientError
  deriving (Eq, Show, Exception)

createSMPQueue :: SMPClient -> PrivateKey -> RecipientKey -> ExceptT SMPClientError IO (RecipientId, SenderId)
createSMPQueue c _rpKey rKey =
  -- TODO add signing this request too - requires changes in the server
  sendSMPCommand c "" "" (Cmd SRecipient $ NEW rKey) >>= \case
    Cmd _ (IDS rId sId) -> return (rId, sId)
    _ -> throwE SMPUnexpectedResponse

subscribeSMPQueue :: SMPClient -> PrivateKey -> RecipientId -> ExceptT SMPClientError IO ()
subscribeSMPQueue c@SMPClient {smpServer, msgQ} rpKey rId =
  sendSMPCommand c rpKey rId (Cmd SRecipient SUB) >>= \case
    Cmd _ OK -> return ()
    Cmd _ cmd@MSG {} ->
      lift . atomically $ writeTBQueue msgQ (smpServer, rId, cmd)
    _ -> throwE SMPUnexpectedResponse

secureSMPQueue :: SMPClient -> PrivateKey -> RecipientId -> SenderKey -> ExceptT SMPClientError IO ()
secureSMPQueue c rpKey rId senderKey = okSMPCommand (Cmd SRecipient $ KEY senderKey) c rpKey rId

sendSMPMessage :: SMPClient -> PrivateKey -> SenderId -> MsgBody -> ExceptT SMPClientError IO ()
sendSMPMessage c spKey sId msg = okSMPCommand (Cmd SSender $ SEND msg) c spKey sId

ackSMPMessage :: SMPClient -> RecipientKey -> QueueId -> ExceptT SMPClientError IO ()
ackSMPMessage c@SMPClient {smpServer, msgQ} rpKey rId =
  sendSMPCommand c rpKey rId (Cmd SRecipient ACK) >>= \case
    Cmd _ OK -> return ()
    Cmd _ cmd@MSG {} ->
      lift . atomically $ writeTBQueue msgQ (smpServer, rId, cmd)
    _ -> throwE SMPUnexpectedResponse

suspendSMPQueue :: SMPClient -> RecipientKey -> QueueId -> ExceptT SMPClientError IO ()
suspendSMPQueue = okSMPCommand $ Cmd SRecipient OFF

deleteSMPQueue :: SMPClient -> RecipientKey -> QueueId -> ExceptT SMPClientError IO ()
deleteSMPQueue = okSMPCommand $ Cmd SRecipient DEL

okSMPCommand :: Cmd -> SMPClient -> PrivateKey -> QueueId -> ExceptT SMPClientError IO ()
okSMPCommand cmd c pKey qId =
  sendSMPCommand c pKey qId cmd >>= \case
    Cmd _ OK -> return ()
    _ -> throwE SMPUnexpectedResponse

sendSMPCommand :: SMPClient -> PrivateKey -> QueueId -> Cmd -> ExceptT SMPClientError IO Cmd
sendSMPCommand SMPClient {sndQ, sentCommands, clientCorrId} pKey qId cmd = ExceptT $ do
  corrId <- atomically getNextCorrId
  t <- signTransmission (corrId, qId, cmd)
  atomically (send corrId t) >>= atomically . takeTMVar
  where
    getNextCorrId :: STM CorrId
    getNextCorrId = do
      i <- (+ 1) <$> readTVar clientCorrId
      writeTVar clientCorrId i
      return . CorrId . B.pack $ show i

    -- TODO this is a stub - to replace with cryptographic signature
    signTransmission :: Signed -> IO Transmission
    signTransmission signed = return (pKey, signed)

    send :: CorrId -> Transmission -> STM (TMVar (Either SMPClientError Cmd))
    send corrId t = do
      r <- newEmptyTMVar
      modifyTVar sentCommands . M.insert corrId $ Request qId r
      writeTBQueue sndQ t
      return r
