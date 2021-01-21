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
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Transport
import Simplex.Messaging.Util
import System.IO

data SMPClient = SMPClient
  { action :: Async (),
    smpServer :: SMPServer,
    clientCorrId :: TVar Natural,
    sentCommands :: TVar (Map SMP.CorrId Request),
    sndQ :: TBQueue SMP.Transmission,
    rcvQ :: TBQueue SMP.TransmissionOrError,
    msgQ :: TBQueue SMPServerTransmission
  }

type SMPServerTransmission = (SMPServer, SMP.RecipientId, SMP.Command 'SMP.Broker)

data SMPClientConfig = SMPClientConfig
  { qSize :: Natural,
    defaultPort :: ServiceName
  }

smpDefaultConfig :: SMPClientConfig
smpDefaultConfig = SMPClientConfig 16 "5223"

data Request = Request
  { queueId :: SMP.QueueId,
    responseVar :: TMVar (Either SMPClientError SMP.Cmd)
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
    send SMPClient {sndQ} h = forever $ atomically (readTBQueue sndQ) >>= SMP.tPut h

    receive :: SMPClient -> Handle -> IO ()
    receive SMPClient {rcvQ} h = forever $ SMP.tGet SMP.fromServer h >>= atomically . writeTBQueue rcvQ

    process :: SMPClient -> IO ()
    process SMPClient {rcvQ, sentCommands} = forever $ do
      (_, (corrId, qId, respOrErr)) <- atomically $ readTBQueue rcvQ
      cs <- readTVarIO sentCommands
      case M.lookup corrId cs of
        Nothing -> do
          case respOrErr of
            Right (SMP.Cmd SMP.SBroker cmd) -> atomically $ writeTBQueue msgQ (smpServer, qId, cmd)
            _ -> return ()
        Just Request {queueId, responseVar} -> atomically $ do
          modifyTVar sentCommands $ M.delete corrId
          putTMVar responseVar $
            if queueId == qId
              then case respOrErr of
                Left e -> Left $ SMPResponseError e
                Right (SMP.Cmd _ (SMP.ERR e)) -> Left $ SMPServerError e
                Right r -> Right r
              else Left SMPQueueIdError

data SMPClientError
  = SMPServerError SMP.ErrorType
  | SMPResponseError SMP.ErrorType
  | SMPQueueIdError
  | SMPUnexpectedResponse
  | SMPResponseTimeout
  | SMPClientError
  deriving (Eq, Show, Exception)

createSMPQueue :: SMPClient -> SMP.PrivateKey -> SMP.RecipientKey -> ExceptT SMPClientError IO (SMP.RecipientId, SMP.SenderId)
createSMPQueue c _rpKey rKey =
  -- TODO add signing this request too - requires changes in the server
  sendSMPCommand c "" "" (SMP.Cmd SMP.SRecipient $ SMP.NEW rKey) >>= \case
    SMP.Cmd _ (SMP.IDS rId sId) -> return (rId, sId)
    _ -> throwE SMPUnexpectedResponse

subscribeSMPQueue :: SMPClient -> SMP.PrivateKey -> SMP.RecipientId -> ExceptT SMPClientError IO ()
subscribeSMPQueue c@SMPClient {smpServer, msgQ} rpKey rId =
  sendSMPCommand c rpKey rId (SMP.Cmd SMP.SRecipient SMP.SUB) >>= \case
    SMP.Cmd _ SMP.OK -> return ()
    SMP.Cmd _ cmd@SMP.MSG {} ->
      lift . atomically $ writeTBQueue msgQ (smpServer, rId, cmd)
    _ -> throwE SMPUnexpectedResponse

secureSMPQueue :: SMPClient -> SMP.PrivateKey -> SMP.RecipientId -> SMP.SenderKey -> ExceptT SMPClientError IO ()
secureSMPQueue c rpKey rId senderKey = okSMPCommand (SMP.Cmd SMP.SRecipient $ SMP.KEY senderKey) c rpKey rId

sendSMPMessage :: SMPClient -> SMP.PrivateKey -> SMP.SenderId -> SMP.MsgBody -> ExceptT SMPClientError IO ()
sendSMPMessage c spKey sId msg = okSMPCommand (SMP.Cmd SMP.SSender $ SMP.SEND msg) c spKey sId

ackSMPMessage :: SMPClient -> SMP.RecipientKey -> SMP.QueueId -> ExceptT SMPClientError IO ()
ackSMPMessage c@SMPClient {smpServer, msgQ} rpKey rId =
  sendSMPCommand c rpKey rId (SMP.Cmd SMP.SRecipient SMP.ACK) >>= \case
    SMP.Cmd _ SMP.OK -> return ()
    SMP.Cmd _ cmd@SMP.MSG {} ->
      lift . atomically $ writeTBQueue msgQ (smpServer, rId, cmd)
    _ -> throwE SMPUnexpectedResponse

suspendSMPQueue :: SMPClient -> SMP.RecipientKey -> SMP.QueueId -> ExceptT SMPClientError IO ()
suspendSMPQueue = okSMPCommand $ SMP.Cmd SMP.SRecipient SMP.OFF

deleteSMPQueue :: SMPClient -> SMP.RecipientKey -> SMP.QueueId -> ExceptT SMPClientError IO ()
deleteSMPQueue = okSMPCommand $ SMP.Cmd SMP.SRecipient SMP.DEL

okSMPCommand :: SMP.Cmd -> SMPClient -> SMP.PrivateKey -> SMP.QueueId -> ExceptT SMPClientError IO ()
okSMPCommand cmd c pKey qId =
  sendSMPCommand c pKey qId cmd >>= \case
    SMP.Cmd _ SMP.OK -> return ()
    _ -> throwE SMPUnexpectedResponse

sendSMPCommand :: SMPClient -> SMP.PrivateKey -> SMP.QueueId -> SMP.Cmd -> ExceptT SMPClientError IO SMP.Cmd
sendSMPCommand SMPClient {sndQ, sentCommands, clientCorrId} pKey qId cmd = ExceptT $ do
  corrId <- atomically getNextCorrId
  t <- signTransmission (corrId, qId, cmd)
  atomically (send corrId t) >>= atomically . takeTMVar
  where
    getNextCorrId :: STM SMP.CorrId
    getNextCorrId = do
      i <- (+ 1) <$> readTVar clientCorrId
      writeTVar clientCorrId i
      return . SMP.CorrId . B.pack $ show i

    -- TODO this is a stub - to replace with cryptographic signature
    signTransmission :: SMP.Signed -> IO SMP.Transmission
    signTransmission signed = return (pKey, signed)

    send :: SMP.CorrId -> SMP.Transmission -> STM (TMVar (Either SMPClientError SMP.Cmd))
    send corrId t = do
      r <- newEmptyTMVar
      modifyTVar sentCommands . M.insert corrId $ Request qId r
      writeTBQueue sndQ t
      return r
