{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module Simplex.RemoteControl.Client
  ( RCHostClient (action),
    RCHostConnection,
    newRCHostPairing,
    connectRCHost,
    cancelHostClient,
    RCCtrlClient (action),
    RCCtrlConnection,
    connectRCCtrlURI,
    connectKnownRCCtrlMulticast,
    confirmCtrlSession,
    cancelCtrlClient,
    RCStepTMVar,
  ) where

import Control.Applicative ((<|>))
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class
import Crypto.Random (ChaChaDRG)
import qualified Data.Aeson as J
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Default (def)
import Data.Functor (($>))
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import Data.Maybe (isNothing)
import qualified Data.Text as T
import Data.Time.Clock.System (getSystemTime)
import qualified Data.X509 as X509
import Data.X509.Validation (Fingerprint (..), getFingerprint)
import Network.Socket (PortNumber)
import qualified Network.TLS as TLS
import Simplex.Messaging.Agent.Client ()
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.SNTRUP761
import Simplex.Messaging.Crypto.SNTRUP761.Bindings
import Simplex.Messaging.Encoding
import Simplex.Messaging.Transport (TLS (tlsUniq), cGet, cPut)
import Simplex.Messaging.Transport.Client (TransportClientConfig (..), TransportHost, defaultTransportClientConfig, runTransportClient)
import Simplex.Messaging.Transport.Credentials (genCredentials, tlsCredentials)
import Simplex.Messaging.Util
import Simplex.Messaging.Version
import Simplex.RemoteControl.Discovery (getLocalAddress, startTLSServer)
import Simplex.RemoteControl.Invitation
import Simplex.RemoteControl.Types
import UnliftIO

currentRCVersion :: Version
currentRCVersion = 1

supportedRCVRange :: VersionRange
supportedRCVRange = mkVersionRange 1 currentRCVersion

xrcpBlockSize :: Int
xrcpBlockSize = 16384

helloBlockSize :: Int
helloBlockSize = 12288

newRCHostPairing :: IO RCHostPairing
newRCHostPairing = do
  ((_, caKey), caCert) <- genCredentials Nothing (-25, 24 * 999999) "ca"
  (_, idPrivKey) <- C.generateKeyPair'
  pure RCHostPairing {caKey, caCert, idPrivKey, knownHost = Nothing}

data RCHostClient = RCHostClient
  { action :: Async (),
    client_ :: RCHClient_
  }

data RCHClient_ = RCHClient_
  { startedPort :: TMVar (Maybe PortNumber),
    hostCAHash :: TMVar C.KeyHash,
    endSession :: TMVar ()
  }

type RCHostConnection = (RCSignedInvitation, RCHostClient, RCStepTMVar (SessionCode, RCStepTMVar (RCHostSession, RCHostHello, RCHostPairing)))

connectRCHost :: TVar ChaChaDRG -> RCHostPairing -> J.Value -> ExceptT RCErrorType IO RCHostConnection
connectRCHost drg pairing@RCHostPairing {caKey, caCert, idPrivKey, knownHost} ctrlAppInfo = do
  r <- newEmptyTMVarIO
  host <- getLocalAddress >>= maybe (throwError RCENoLocalAddress) pure
  c@RCHClient_ {startedPort} <- liftIO mkClient
  hostKeys <- liftIO genHostKeys
  action <- runClient c r hostKeys `putRCError` r
  -- wait for the port to make invitation
  -- TODO can't we actually find to which interface the server got connected to get host there?
  portNum <- atomically $ readTMVar startedPort
  signedInv <- maybe (throwError RCETLSStartFailed) (liftIO . mkInvitation hostKeys host) portNum
  pure (signedInv, RCHostClient {action, client_ = c}, r)
  where
    mkClient :: IO RCHClient_
    mkClient = do
      startedPort <- newEmptyTMVarIO
      endSession <- newEmptyTMVarIO
      hostCAHash <- newEmptyTMVarIO
      pure RCHClient_ {startedPort, hostCAHash, endSession}
    runClient :: RCHClient_ -> RCStepTMVar (ByteString, RCStepTMVar (RCHostSession, RCHostHello, RCHostPairing)) -> RCHostKeys -> ExceptT RCErrorType IO (Async ())
    runClient RCHClient_ {startedPort, hostCAHash, endSession} r hostKeys = do
      tlsCreds <- liftIO $ genTLSCredentials caKey caCert
      startTLSServer startedPort tlsCreds (tlsHooks r knownHost hostCAHash) $ \tls ->
        void . runExceptT $ do
          r' <- newEmptyTMVarIO
          whenM (atomically $ tryPutTMVar r $ Right (tlsUniq tls, r')) $
            runSession tls r' `putRCError` r'
      where
        runSession tls r' = do
          logDebug "Incoming TLS connection"
          hostEncHello <- receiveRCPacket tls
          logDebug "Received host HELLO"
          hostCA <- atomically $ takeTMVar hostCAHash
          (ctrlEncHello, sessionKeys, helloBody, pairing') <- prepareHostSession drg hostCA pairing hostKeys hostEncHello
          sendRCPacket tls ctrlEncHello
          logDebug "Sent ctrl HELLO"
          whenM (atomically $ tryPutTMVar r' $ Right (RCHostSession {tls, sessionKeys}, helloBody, pairing')) $ do
            -- can use `RCHostSession` until `endSession` is signalled
            logDebug "Holding session"
            atomically $ takeTMVar endSession
    tlsHooks :: TMVar a -> Maybe KnownHostPairing -> TMVar C.KeyHash -> TLS.ServerHooks
    tlsHooks r knownHost_ hostCAHash =
      def
        { TLS.onUnverifiedClientCert = pure True,
          TLS.onNewHandshake = \_ -> atomically $ isNothing <$> tryReadTMVar r,
          TLS.onClientCertificate = \(X509.CertificateChain chain) ->
            case chain of
              [_leaf, ca] -> do
                let Fingerprint fp = getFingerprint ca X509.HashSHA256
                    kh = C.KeyHash fp
                    accept = maybe True (\h -> h.hostFingerprint == kh) knownHost_
                if accept
                  then atomically (putTMVar hostCAHash kh) $> TLS.CertificateUsageAccept
                  else pure $ TLS.CertificateUsageReject TLS.CertificateRejectUnknownCA
              _ ->
                pure $ TLS.CertificateUsageReject TLS.CertificateRejectUnknownCA
        }
    genHostKeys :: IO RCHostKeys
    genHostKeys = do
      sessKeys <- C.generateKeyPair'
      dhKeys <- C.generateKeyPair'
      pure RCHostKeys {sessKeys, dhKeys}
    mkInvitation :: RCHostKeys -> TransportHost -> PortNumber -> IO RCSignedInvitation
    mkInvitation RCHostKeys {sessKeys, dhKeys} host portNum = do
      ts <- getSystemTime
      let inv =
            RCInvitation
              { ca = certFingerprint caCert,
                host,
                port = fromIntegral portNum,
                v = supportedRCVRange,
                app = ctrlAppInfo,
                ts,
                skey = fst sessKeys,
                idkey = C.publicKey idPrivKey,
                dh = fst dhKeys
              }
          signedInv = signInviteURL (snd sessKeys) idPrivKey inv
      pure signedInv

genTLSCredentials :: C.APrivateSignKey -> C.SignedCertificate -> IO TLS.Credentials
genTLSCredentials caKey caCert = do
  let caCreds = (C.signatureKeyPair caKey, caCert)
  leaf <- genCredentials (Just caCreds) (0, 24 * 999999) "localhost" -- session-signing cert
  pure . snd $ tlsCredentials (leaf :| [caCreds])

certFingerprint :: X509.SignedCertificate -> C.KeyHash
certFingerprint caCert = C.KeyHash fp
  where
    Fingerprint fp = getFingerprint caCert X509.HashSHA256

cancelHostClient :: RCHostClient -> IO ()
cancelHostClient RCHostClient {action, client_ = RCHClient_ {endSession}} = do
  atomically $ putTMVar endSession ()
  uninterruptibleCancel action

prepareHostSession :: TVar ChaChaDRG -> C.KeyHash -> RCHostPairing -> RCHostKeys -> RCHostEncHello -> ExceptT RCErrorType IO (RCCtrlEncHello, HostSessKeys, RCHostHello, RCHostPairing)
prepareHostSession
  drg
  tlsHostFingerprint
  pairing@RCHostPairing {idPrivKey, knownHost = knownHost_}
  RCHostKeys {sessKeys = (_, sessPrivKey), dhKeys = (_, dhPrivKey)}
  RCHostEncHello {dhPubKey, nonce, encBody} = do
    let sharedKey = C.dh' dhPubKey dhPrivKey
    helloBody <- liftEitherWith (const RCEDecrypt) $ C.cbDecrypt sharedKey nonce encBody
    hostHello@RCHostHello {v, ca, kem = kemPubKey} <- liftEitherWith RCESyntax $ J.eitherDecodeStrict helloBody
    unless (ca == tlsHostFingerprint) $ throwError RCEIdentity
    (kemCiphertext, kemSharedKey) <- liftIO $ sntrup761Enc drg kemPubKey
    let hybridKey = kemHybridSecret dhPubKey dhPrivKey kemSharedKey
    unless (isCompatible v supportedRCVRange) $ throwError RCEVersion
    let keys = HostSessKeys {hybridKey, idPrivKey, sessPrivKey}
    knownHost' <- updateKnownHost ca dhPubKey
    let ctrlHello = RCCtrlHello {}
    -- TODO send error response if something fails
    nonce' <- liftIO . atomically $ C.pseudoRandomCbNonce drg
    encBody' <- liftEitherWith (const RCEBlockSize) $ kcbEncrypt hybridKey nonce' (LB.toStrict $ J.encode ctrlHello) helloBlockSize
    let ctrlEncHello = RCCtrlEncHello {kem = kemCiphertext, nonce = nonce', encBody = encBody'}
    pure (ctrlEncHello, keys, hostHello, pairing {knownHost = Just knownHost'})
    where
      updateKnownHost :: C.KeyHash -> C.PublicKeyX25519 -> ExceptT RCErrorType IO KnownHostPairing
      updateKnownHost ca hostDhPubKey = case knownHost_ of
        Just h -> do
          unless (h.hostFingerprint == tlsHostFingerprint) . throwError $
            RCEInternal "TLS host CA is different from host pairing, should be caught in TLS handshake"
          pure (h :: KnownHostPairing) {hostDhPubKey}
        Nothing -> pure KnownHostPairing {hostFingerprint = ca, hostDhPubKey}

data RCCtrlClient = RCCtrlClient
  { action :: Async (),
    client_ :: RCCClient_
  }

data RCCClient_ = RCCClient_
  { confirmSession :: TMVar Bool,
    endSession :: TMVar ()
  }

type RCCtrlConnection = (RCCtrlClient, RCStepTMVar (SessionCode, RCStepTMVar (RCCtrlSession, RCCtrlPairing)))

connectRCCtrlURI :: TVar ChaChaDRG -> RCSignedInvitation -> Maybe RCCtrlPairing -> J.Value -> ExceptT RCErrorType IO RCCtrlConnection
connectRCCtrlURI drg signedInv@RCSignedInvitation {invitation} pairing_ hostAppInfo = do
  unless (verifySignedInviteURI signedInv) $ throwError RCECtrlAuth
  connectRCCtrl drg invitation pairing_ hostAppInfo

-- app should determine whether it is a new or known pairing based on CA fingerprint in the invitation
connectRCCtrl :: TVar ChaChaDRG -> RCInvitation -> Maybe RCCtrlPairing -> J.Value -> ExceptT RCErrorType IO RCCtrlConnection
connectRCCtrl drg inv@RCInvitation {ca, idkey} pairing_ hostAppInfo = do
  pairing' <- maybe (liftIO newCtrlPairing) updateCtrlPairing pairing_
  connectRCCtrl_ drg pairing' inv hostAppInfo
  where
    newCtrlPairing :: IO RCCtrlPairing
    newCtrlPairing = do
      ((_, caKey), caCert) <- genCredentials Nothing (0, 24 * 999999) "ca"
      (_, dhPrivKey) <- C.generateKeyPair'
      pure RCCtrlPairing {caKey, caCert, ctrlFingerprint = ca, idPubKey = idkey, dhPrivKey, prevDhPrivKey = Nothing}
    updateCtrlPairing :: RCCtrlPairing -> ExceptT RCErrorType IO RCCtrlPairing
    updateCtrlPairing pairing@RCCtrlPairing {ctrlFingerprint, idPubKey, dhPrivKey = currDhPrivKey} = do
      unless (ca == ctrlFingerprint && idPubKey == idkey) $ throwError RCEIdentity
      (_, dhPrivKey) <- liftIO C.generateKeyPair'
      pure pairing {dhPrivKey, prevDhPrivKey = Just currDhPrivKey}

connectRCCtrl_ :: TVar ChaChaDRG -> RCCtrlPairing -> RCInvitation -> J.Value -> ExceptT RCErrorType IO RCCtrlConnection
connectRCCtrl_ drg pairing'@RCCtrlPairing {caKey, caCert} inv@RCInvitation {ca, host, port} hostAppInfo = do
  r <- newEmptyTMVarIO
  c <- liftIO mkClient
  action <- async $ runClient c r `putRCError` r
  pure (RCCtrlClient {action, client_ = c}, r)
  where
    mkClient :: IO RCCClient_
    mkClient = do
      confirmSession <- newEmptyTMVarIO
      endSession <- newEmptyTMVarIO
      pure RCCClient_ {confirmSession, endSession}
    runClient :: RCCClient_ -> RCStepTMVar (SessionCode, RCStepTMVar (RCCtrlSession, RCCtrlPairing)) -> ExceptT RCErrorType IO ()
    runClient RCCClient_ {confirmSession, endSession} r = do
      clientCredentials <-
        liftIO (genTLSCredentials caKey caCert) >>= \case
          TLS.Credentials (creds : _) -> pure $ Just creds
          _ -> throwError $ RCEInternal "genTLSCredentials must generate credentials"
      let clientConfig = defaultTransportClientConfig {clientCredentials}
      liftIO . runTransportClient clientConfig Nothing host (show port) (Just ca) $ \tls ->
        void . runExceptT $ do
          logDebug "Got TLS connection"
          r' <- newEmptyTMVarIO
          whenM (atomically $ tryPutTMVar r $ Right (tlsUniq tls, r')) $ do
            logDebug "Waiting for session confirmation"
            whenM (atomically $ readTMVar confirmSession) (runSession tls r') `putRCError` r'
      where
        runSession tls r' = do
          (sharedKey, kemPrivKey, hostEncHello) <- prepareHostHello drg pairing' inv hostAppInfo
          sendRCPacket tls hostEncHello
          ctrlEncHello <- receiveRCPacket tls
          logDebug "Received ctrl HELLO"
          ctrlSessKeys <- prepareCtrlSession pairing' inv sharedKey kemPrivKey ctrlEncHello
          whenM (atomically $ tryPutTMVar r' $ Right (RCCtrlSession {tls, sessionKeys = ctrlSessKeys}, pairing')) $ do
            logDebug "Session started"
            -- release second putTMVar in confirmCtrlSession
            void . atomically $ takeTMVar confirmSession
            atomically $ takeTMVar endSession
            logDebug "Session ended"

catchRCError :: ExceptT RCErrorType IO a -> (RCErrorType -> ExceptT RCErrorType IO a) -> ExceptT RCErrorType IO a
catchRCError = catchAllErrors (RCEException . show)
{-# INLINE catchRCError #-}

putRCError :: ExceptT RCErrorType IO a -> TMVar (Either RCErrorType b) -> ExceptT RCErrorType IO a
a `putRCError` r = a `catchRCError` \e -> atomically (tryPutTMVar r $ Left e) >> throwError e

sendRCPacket :: Encoding a => TLS -> a -> ExceptT RCErrorType IO ()
sendRCPacket tls pkt = do
  b <- liftEitherWith (const RCEBlockSize) $ C.pad (smpEncode pkt) xrcpBlockSize
  liftIO $ cPut tls b

receiveRCPacket :: Encoding a => TLS -> ExceptT RCErrorType IO a
receiveRCPacket tls = do
  b <- liftIO $ cGet tls xrcpBlockSize
  when (B.length b /= xrcpBlockSize) $ throwError RCEBlockSize
  b' <- liftEitherWith (const RCEBlockSize) $ C.unPad b
  liftEitherWith RCESyntax $ smpDecode b'

prepareHostHello :: TVar ChaChaDRG -> RCCtrlPairing -> RCInvitation -> J.Value -> ExceptT RCErrorType IO (C.DhSecretX25519, KEMSecretKey, RCHostEncHello)
prepareHostHello
  drg
  RCCtrlPairing {caCert, dhPrivKey}
  RCInvitation {v, dh = dhPubKey}
  hostAppInfo = do
    logDebug "Preparing session"
    case compatibleVersion v supportedRCVRange of
      Nothing -> throwError RCEVersion
      Just (Compatible v') -> do
        nonce <- liftIO . atomically $ C.pseudoRandomCbNonce drg
        (kemPubKey, kemPrivKey) <- liftIO $ sntrup761Keypair drg
        let Fingerprint fp = getFingerprint caCert X509.HashSHA256
            helloBody = RCHostHello {v = v', ca = C.KeyHash fp, app = hostAppInfo, kem = kemPubKey}
            sharedKey = C.dh' dhPubKey dhPrivKey
        encBody <- liftEitherWith (const RCEBlockSize) $ C.cbEncrypt sharedKey nonce (LB.toStrict $ J.encode helloBody) helloBlockSize
        -- let sessKeys = CtrlSessKeys {hybridKey, idPubKey, sessPubKey = skey}
        let hostEncHello = RCHostEncHello {dhPubKey = C.publicKey dhPrivKey, nonce, encBody}
        pure (sharedKey, kemPrivKey, hostEncHello)

prepareCtrlSession :: RCCtrlPairing -> RCInvitation -> C.DhSecretX25519 -> KEMSecretKey -> RCCtrlEncHello -> ExceptT RCErrorType IO CtrlSessKeys
prepareCtrlSession
  RCCtrlPairing {idPubKey, dhPrivKey}
  RCInvitation {skey, dh = dhPubKey}
  sharedKey
  kemPrivKey = \case
    RCCtrlEncHello {kem = kemCiphertext, nonce, encBody} -> do
      kemSharedKey <- liftIO $ sntrup761Dec kemCiphertext kemPrivKey
      let hybridKey = kemHybridSecret dhPubKey dhPrivKey kemSharedKey
      helloBody <- liftEitherWith (const RCEDecrypt) $ kcbDecrypt hybridKey nonce encBody
      logDebug "Decrypted ctrl HELLO"
      RCCtrlHello {} <- liftEitherWith RCESyntax $ J.eitherDecodeStrict helloBody
      pure CtrlSessKeys {hybridKey, idPubKey, sessPubKey = skey}
    RCCtrlEncError {nonce, encMessage} -> do
      message <- liftEitherWith (const RCEDecrypt) $ C.cbDecrypt sharedKey nonce encMessage
      throwError $ RCECtrlError $ T.unpack $ safeDecodeUtf8 message

-- The application should save updated RCHostPairing after user confirmation of the session
-- TMVar resolves when TLS is connected
connectKnownRCCtrlMulticast :: TVar ChaChaDRG -> TVar Int -> NonEmpty RCCtrlPairing -> J.Value -> ExceptT RCErrorType IO RCCtrlConnection
connectKnownRCCtrlMulticast drg _subscribers pairings hostAppInfo = do
  -- start multicast
  -- receive packets
  let loop = undefined -- catch and log errors, fail on timeout
      receive = undefined
      parse = undefined
  (pairing, inv) <- loop $ receive >>= parse >>= findRCCtrlPairing pairings
  connectRCCtrl drg inv pairing hostAppInfo

findRCCtrlPairing :: NonEmpty RCCtrlPairing -> RCEncInvitation -> ExceptT RCErrorType IO (RCCtrlPairing, RCInvitation)
findRCCtrlPairing pairings RCEncInvitation {dhPubKey, nonce, encInvitation} = do
  (pairing, signedInvStr) <- liftEither $ decrypt (L.toList pairings)
  signedInv@RCSignedInvitation {invitation} <- liftEitherWith RCESyntax $ smpDecode signedInvStr
  unless (verifySignedInvitationMulticast signedInv) $ throwError RCECtrlAuth
  pure (pairing, invitation)
  where
    decrypt :: [RCCtrlPairing] -> Either RCErrorType (RCCtrlPairing, ByteString)
    decrypt [] = Left RCECtrlNotFound
    decrypt (pairing@RCCtrlPairing {dhPrivKey, prevDhPrivKey} : rest) =
      let r = decrypt_ dhPrivKey <|> (decrypt_ =<< prevDhPrivKey)
       in maybe (decrypt rest) (Right . (pairing,)) r
    decrypt_ :: C.PrivateKeyX25519 -> Maybe ByteString
    decrypt_ dhPrivKey =
      let key = C.dh' dhPubKey dhPrivKey
       in eitherToMaybe $ C.cbDecrypt key nonce encInvitation

-- application should call this function when TMVar resolves
confirmCtrlSession :: RCCtrlClient -> Bool -> IO ()
confirmCtrlSession RCCtrlClient {client_ = RCCClient_ {confirmSession}} res = do
  atomically $ putTMVar confirmSession res
  -- controler does takeTMVar, freeing the slot
  -- TODO add timeout
  atomically $ putTMVar confirmSession res -- wait for Ctrl to take the var

cancelCtrlClient :: RCCtrlClient -> IO ()
cancelCtrlClient RCCtrlClient {action, client_ = RCCClient_ {endSession}} = do
  atomically $ putTMVar endSession ()
  uninterruptibleCancel action
