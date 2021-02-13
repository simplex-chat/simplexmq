{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

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

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Control.Monad.Trans.Class
import Control.Monad.Trans.Except
import qualified Crypto.PubKey.RSA.Types as RSA
import Data.Bifunctor (bimap)
import qualified Data.ByteString.Char8 as B
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe
import GHC.IO.Exception (IOErrorType (..))
import Network.Socket (ServiceName)
import Numeric.Natural
import Simplex.Messaging.Agent.Transmission (SMPServer (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Transport
import Simplex.Messaging.Types
import Simplex.Messaging.Util
import System.IO
import System.IO.Error
import System.Timeout

data SMPClient = SMPClient
  { action :: Async (),
    connected :: TVar Bool,
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
    defaultPort :: ServiceName,
    tcpTimeout :: Int
  }

smpDefaultConfig :: SMPClientConfig
smpDefaultConfig =
  SMPClientConfig
    { qSize = 16,
      defaultPort = "5223",
      tcpTimeout = 2_000_000
    }

data Request = Request
  { queueId :: QueueId,
    responseVar :: TMVar (Either SMPClientError Cmd)
  }

getSMPClient :: SMPServer -> SMPClientConfig -> TBQueue SMPServerTransmission -> IO () -> IO SMPClient
getSMPClient
  smpServer@SMPServer {host, port}
  SMPClientConfig {qSize, defaultPort, tcpTimeout}
  msgQ
  disconnected = do
    c <- atomically mkSMPClient
    started <- newEmptyTMVarIO
    action <-
      async $
        runTCPClient host (fromMaybe defaultPort port) (client c started)
          `finally` atomically (putTMVar started False)
    tcpTimeout `timeout` atomically (takeTMVar started) >>= \case
      Just True -> return c {action}
      _ -> throwIO err
    where
      err :: IOException
      err = mkIOError TimeExpired "connection timeout" Nothing Nothing

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
              clientCorrId,
              sentCommands,
              sndQ,
              rcvQ,
              msgQ
            }

      client :: SMPClient -> TMVar Bool -> Handle -> IO ()
      client c started h = do
        _ <- getLn h -- "Welcome to SMP"
        atomically $ do
          modifyTVar (connected c) (const True)
          putTMVar started True
        raceAny_ [send c h, process c, receive c h]
          `finally` disconnected

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
  | SMPCryptoError RSA.Error
  | SMPClientError
  deriving (Eq, Show, Exception)

createSMPQueue :: SMPClient -> C.PrivateKey -> RecipientKey -> ExceptT SMPClientError IO (RecipientId, SenderId)
createSMPQueue c rpKey rKey =
  -- TODO add signing this request too - requires changes in the server
  sendSMPCommand c (Just rpKey) "" (Cmd SRecipient $ NEW rKey) >>= \case
    Cmd _ (IDS rId sId) -> return (rId, sId)
    _ -> throwE SMPUnexpectedResponse

subscribeSMPQueue :: SMPClient -> C.PrivateKey -> RecipientId -> ExceptT SMPClientError IO ()
subscribeSMPQueue c@SMPClient {smpServer, msgQ} rpKey rId =
  sendSMPCommand c (Just rpKey) rId (Cmd SRecipient SUB) >>= \case
    Cmd _ OK -> return ()
    Cmd _ cmd@MSG {} ->
      lift . atomically $ writeTBQueue msgQ (smpServer, rId, cmd)
    _ -> throwE SMPUnexpectedResponse

secureSMPQueue :: SMPClient -> C.PrivateKey -> RecipientId -> SenderKey -> ExceptT SMPClientError IO ()
secureSMPQueue c rpKey rId senderKey = okSMPCommand (Cmd SRecipient $ KEY senderKey) c rpKey rId

sendSMPMessage :: SMPClient -> Maybe C.PrivateKey -> SenderId -> MsgBody -> ExceptT SMPClientError IO ()
sendSMPMessage c spKey sId msg =
  sendSMPCommand c spKey sId (Cmd SSender $ SEND msg) >>= \case
    Cmd _ OK -> return ()
    _ -> throwE SMPUnexpectedResponse

ackSMPMessage :: SMPClient -> C.PrivateKey -> QueueId -> ExceptT SMPClientError IO ()
ackSMPMessage c@SMPClient {smpServer, msgQ} rpKey rId =
  sendSMPCommand c (Just rpKey) rId (Cmd SRecipient ACK) >>= \case
    Cmd _ OK -> return ()
    Cmd _ cmd@MSG {} ->
      lift . atomically $ writeTBQueue msgQ (smpServer, rId, cmd)
    _ -> throwE SMPUnexpectedResponse

suspendSMPQueue :: SMPClient -> C.PrivateKey -> QueueId -> ExceptT SMPClientError IO ()
suspendSMPQueue = okSMPCommand $ Cmd SRecipient OFF

deleteSMPQueue :: SMPClient -> C.PrivateKey -> QueueId -> ExceptT SMPClientError IO ()
deleteSMPQueue = okSMPCommand $ Cmd SRecipient DEL

okSMPCommand :: Cmd -> SMPClient -> C.PrivateKey -> QueueId -> ExceptT SMPClientError IO ()
okSMPCommand cmd c pKey qId =
  sendSMPCommand c (Just pKey) qId cmd >>= \case
    Cmd _ OK -> return ()
    _ -> throwE SMPUnexpectedResponse

sendSMPCommand :: SMPClient -> Maybe C.PrivateKey -> QueueId -> Cmd -> ExceptT SMPClientError IO Cmd
sendSMPCommand SMPClient {sndQ, sentCommands, clientCorrId} pKey qId cmd = ExceptT $ do
  corrId <- atomically getNextCorrId
  signTransmission (corrId, qId, cmd) pKey >>= \case
    Right t -> atomically (send corrId t) >>= atomically . takeTMVar
    Left e -> return $ Left e
  where
    getNextCorrId :: STM CorrId
    getNextCorrId = do
      i <- (+ 1) <$> readTVar clientCorrId
      writeTVar clientCorrId i
      return . CorrId . B.pack $ show i

    -- TODO this is a stub - to replace with cryptographic signature
    signTransmission :: Signed -> Maybe C.PrivateKey -> IO (Either SMPClientError Transmission)
    signTransmission signed = \case
      Nothing -> return $ Right (C.Signature "", signed)
      Just pk -> bimap SMPCryptoError (,signed) <$> C.signStub pk ""

    send :: CorrId -> Transmission -> STM (TMVar (Either SMPClientError Cmd))
    send corrId t = do
      r <- newEmptyTMVar
      modifyTVar sentCommands . M.insert corrId $ Request qId r
      writeTBQueue sndQ t
      return r
