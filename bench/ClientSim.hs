{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module ClientSim
  ( SimClient (..),
    connectClient,
    createQueue,
    subscribeQueue,
    sendMessage,
    receiveAndAck,
    connectN,
    benchKeyHash,
  )
where

import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.STM
import Control.Monad (forM_)
import Control.Monad.Except (runExceptT)
import Data.ByteString.Char8 (ByteString)
import Data.List (unfoldr)
import qualified Data.List.NonEmpty as L
import Network.Socket (ServiceName)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Protocol
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Client
import Simplex.Messaging.Version

data SimClient = SimClient
  { scHandle :: THandleSMP TLS 'TClient,
    scRcvKey :: C.APrivateAuthKey,
    scRcvId :: RecipientId,
    scSndId :: SenderId,
    scDhSecret :: C.DhSecret 'C.X25519
  }

benchKeyHash :: C.KeyHash
benchKeyHash = "LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI="

connectClient :: TransportHost -> ServiceName -> IO (THandleSMP TLS 'TClient)
connectClient host port = do
  let tcConfig = defaultTransportClientConfig {clientALPN = Just alpnSupportedSMPHandshakes}
  runTransportClient tcConfig Nothing host port (Just benchKeyHash) $ \h ->
    runExceptT (smpClientHandshake h Nothing benchKeyHash supportedClientSMPRelayVRange False Nothing) >>= \case
      Right th -> pure th
      Left e -> error $ "SMP handshake failed: " <> show e

connectN :: Int -> TransportHost -> ServiceName -> IO [THandleSMP TLS 'TClient]
connectN n host port = do
  let batches = chunksOf 100 [1 .. n]
  concat <$> mapM (\batch -> mapConcurrently (\_ -> connectClient host port) batch) batches

createQueue :: THandleSMP TLS 'TClient -> IO SimClient
createQueue h = do
  g <- C.newRandom
  (rPub, rKey) <- atomically $ C.generateAuthKeyPair C.SEd448 g
  (sPub, sKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (dhPub, dhPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
  -- NEW command
  Resp "1" NoEntity (Ids rId sId srvDh) <- signSendRecv h rKey ("1", NoEntity, New rPub dhPub)
  let dhShared = C.dh' srvDh dhPriv
  -- KEY command (secure queue)
  Resp "2" _ OK <- signSendRecv h rKey ("2", rId, KEY sPub)
  pure SimClient {scHandle = h, scRcvKey = rKey, scRcvId = rId, scSndId = sId, scDhSecret = dhShared}

subscribeQueue :: SimClient -> IO ()
subscribeQueue SimClient {scHandle = h, scRcvKey = rKey, scRcvId = rId} = do
  Resp "3" _ (SOK _) <- signSendRecv h rKey ("3", rId, SUB)
  pure ()

sendMessage :: THandleSMP TLS 'TClient -> C.APrivateAuthKey -> SenderId -> ByteString -> IO ()
sendMessage h sKey sId body = do
  Resp "4" _ OK <- signSendRecv h sKey ("4", sId, SEND noMsgFlags body)
  pure ()

receiveAndAck :: SimClient -> IO ()
receiveAndAck SimClient {scHandle = h, scRcvKey = rKey, scRcvId = rId} = do
  (_, _, Right (MSG RcvMessage {msgId = mId})) <- tGet1 h
  Resp "5" _ OK <- signSendRecv h rKey ("5", rId, ACK mId)
  pure ()

-- Helpers (same patterns as ServerTests.hs)

pattern Resp :: CorrId -> EntityId -> BrokerMsg -> Transmission (Either ErrorType BrokerMsg)
pattern Resp corrId queueId command <- (corrId, queueId, Right command)

pattern Ids :: RecipientId -> SenderId -> RcvPublicDhKey -> BrokerMsg
pattern Ids rId sId srvDh <- IDS (QIK rId sId srvDh _ _ Nothing Nothing)

pattern New :: RcvPublicAuthKey -> RcvPublicDhKey -> Command 'Creator
pattern New rPub dhPub = NEW (NewQueueReq rPub dhPub Nothing SMSubscribe (Just (QRMessaging Nothing)) Nothing)

signSendRecv :: (Transport c, PartyI p) => THandleSMP c 'TClient -> C.APrivateAuthKey -> (ByteString, EntityId, Command p) -> IO (Transmission (Either ErrorType BrokerMsg))
signSendRecv h pk t = do
  signSend h pk t
  (r L.:| _) <- tGetClient h
  pure r

signSend :: (Transport c, PartyI p) => THandleSMP c 'TClient -> C.APrivateAuthKey -> (ByteString, EntityId, Command p) -> IO ()
signSend h@THandle {params} (C.APrivateAuthKey a pk) (corrId, qId, cmd) = do
  let TransmissionForAuth {tForAuth, tToSend} = encodeTransmissionForAuth params (CorrId corrId, qId, cmd)
      authorize t = (,Nothing) <$> case a of
        C.SEd25519 -> Just . TASignature . C.ASignature C.SEd25519 $ C.sign' pk t
        C.SEd448 -> Just . TASignature . C.ASignature C.SEd448 $ C.sign' pk t
        C.SX25519 -> (\THAuthClient {peerServerPubKey = k} -> TAAuthenticator $ C.cbAuthenticate k pk (C.cbNonce corrId) t) <$> thAuth params
  Right () <- tPut1 h (authorize tForAuth, tToSend)
  pure ()

tPut1 :: Transport c => THandle v c 'TClient -> SentRawTransmission -> IO (Either TransportError ())
tPut1 h t = do
  rs <- tPut h (Right t L.:| [])
  case rs of
    (r : _) -> pure r
    [] -> error "tPut1: empty result"

tGet1 :: (ProtocolEncoding v err cmd, Transport c) => THandle v c 'TClient -> IO (Transmission (Either err cmd))
tGet1 h = do
  (r L.:| _) <- tGetClient h
  pure r

chunksOf :: Int -> [a] -> [[a]]
chunksOf n = unfoldr $ \xs -> if null xs then Nothing else Just (splitAt n xs)
