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
import qualified Data.Aeson.TH as JQ
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Default (def)
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
import Simplex.Messaging.Util (eitherToMaybe, ifM, liftEitherWith, safeDecodeUtf8, tshow)
import Simplex.Messaging.Version
import Simplex.RemoteControl.Discovery (getLocalAddress, startTLSServer)
import Simplex.RemoteControl.Invitation
import Simplex.RemoteControl.Types
import UnliftIO
import UnliftIO.Concurrent (forkIO)

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
    endSession :: TMVar (),
    tlsEnded :: TMVar (Either RCErrorType ())
  }

type RCHostConnection = (RCSignedInvitation, RCHostClient, RCStepTMVar (SessionCode, RCStepTMVar (RCHostSession, RCHostHello, RCHostPairing)))

connectRCHost :: TVar ChaChaDRG -> RCHostPairing -> J.Value -> ExceptT RCErrorType IO RCHostConnection
connectRCHost drg pairing@RCHostPairing {caKey, caCert, idPrivKey, knownHost} ctrlAppInfo = do
  r <- newEmptyTMVarIO
  host <- getLocalAddress >>= maybe (throwError RCENoLocalAddress) pure
  c@RCHClient_ {startedPort, tlsEnded} <- liftIO mkClient
  hostKeys <- liftIO genHostKeys
  action <- liftIO $ runClient c r hostKeys
  void . forkIO $ do
    res <- atomically $ takeTMVar tlsEnded
    either (logError . ("XRCP session ended with error: " <>) . tshow) (\() -> logInfo "XRCP session ended") res
    uninterruptibleCancel action
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
      tlsEnded <- newEmptyTMVarIO
      hostCAHash <- newEmptyTMVarIO
      pure RCHClient_ {startedPort, hostCAHash, endSession, tlsEnded}
    runClient :: RCHClient_ -> RCStepTMVar (ByteString, RCStepTMVar (RCHostSession, RCHostHello, RCHostPairing)) -> RCHostKeys -> IO (Async ())
    runClient RCHClient_ {startedPort, hostCAHash, endSession, tlsEnded} r hostKeys = do
      tlsCreds <- genTLSCredentials caKey caCert
      startTLSServer startedPort tlsCreds (tlsHooks r knownHost hostCAHash) $ \tls -> do
        res <- handleAny (pure . Left . RCEException . show) . runExceptT $ do
          logDebug "Incoming TLS connection"
          r' <- newEmptyTMVarIO
          atomically $ putTMVar r $ Right (tlsUniq tls, r')
          -- TODO lock session
          hostEncHello <- receiveRCPacket tls
          logDebug "Received host HELLO"
          hostCA <- atomically $ takeTMVar hostCAHash
          (ctrlEncHello, sessionKeys, helloBody, pairing') <- prepareHostSession drg hostCA pairing hostKeys hostEncHello
          sendRCPacket tls ctrlEncHello
          logDebug "Sent ctrl HELLO"
          atomically $ putTMVar r' $ Right (RCHostSession {tls, sessionKeys}, helloBody, pairing')
          -- can use `RCHostSession` until `endSession` is signalled
          logDebug "Holding session"
          atomically $ takeTMVar endSession
        logDebug $ "TLS connection finished with " <> tshow res
        atomically $ putTMVar tlsEnded res
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
                atomically $ putTMVar hostCAHash kh
                let accept = maybe True (\h -> h.hostFingerprint == kh) knownHost_
                pure $ if accept then TLS.CertificateUsageAccept else TLS.CertificateUsageReject TLS.CertificateRejectUnknownCA
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
    let sharedKey = kemHybridOrDHSecret dhPubKey dhPrivKey $ (\h -> h.storedSessKeys.kemSharedKey) <$> knownHost_
    helloBody <- liftEitherWith (const RCEDecrypt) $ kcbDecrypt sharedKey nonce encBody
    hostHello@RCHostHello {v, ca, kem = kemPubKey} <- liftEitherWith RCESyntax $ J.eitherDecodeStrict helloBody
    (kemCiphertext, kemSharedKey) <- liftIO $ sntrup761Enc drg kemPubKey
    let hybridKey = kemHybridSecret dhPubKey dhPrivKey kemSharedKey
    unless (isCompatible v supportedRCVRange) $ throwError RCEVersion
    let keys = HostSessKeys {hybridKey, idPrivKey, sessPrivKey}
        storedSessKeys = StoredHostSessKeys {hostDHPublicKey = dhPubKey, kemSharedKey}
    knownHost' <- updateKnownHost ca storedSessKeys
    let ctrlHello = RCCtrlHello {}
    -- TODO send error response if something fails
    nonce' <- liftIO . atomically $ C.pseudoRandomCbNonce drg
    encBody' <- liftEitherWith (const RCEBlockSize) $ kcbEncrypt hybridKey nonce' (LB.toStrict $ J.encode ctrlHello) helloBlockSize
    let ctrlEncHello = RCCtrlEncHello {kem = kemCiphertext, nonce = nonce', encBody = encBody'}
    pure (ctrlEncHello, keys, hostHello, pairing {knownHost = Just knownHost'})
    where
      updateKnownHost :: C.KeyHash -> StoredHostSessKeys -> ExceptT RCErrorType IO KnownHostPairing
      updateKnownHost ca storedSessKeys = case knownHost_ of
        Just h -> do
          unless (h.hostFingerprint == tlsHostFingerprint) . throwError $
            RCEInternal "TLS host CA is different from host pairing, should be caught in TLS handshake"
          unless (ca == tlsHostFingerprint) $ throwError RCEIdentity
          pure (h :: KnownHostPairing) {storedSessKeys}
        Nothing -> pure KnownHostPairing {hostFingerprint = ca, storedSessKeys}

data RCCtrlClient = RCCtrlClient
  { action :: Async (),
    client_ :: RCCClient_
  }

data RCCClient_ = RCCClient_
  { confirmSession :: TMVar Bool,
    endSession :: TMVar (),
    tlsEnded :: TMVar (Either RCErrorType ())
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
      let storedSessKeys = StoredCtrlSessKeys dhPrivKey Nothing
      pure RCCtrlPairing {caKey, caCert, ctrlFingerprint = ca, idPubKey = idkey, storedSessKeys, prevStoredSessKeys = Nothing}
    updateCtrlPairing :: RCCtrlPairing -> ExceptT RCErrorType IO RCCtrlPairing
    updateCtrlPairing pairing@RCCtrlPairing {ctrlFingerprint, idPubKey, storedSessKeys = currSSK} = do
      unless (ca == ctrlFingerprint && idPubKey == idkey) $ throwError RCEIdentity
      (_, dhPrivKey) <- liftIO C.generateKeyPair'
      pure pairing {storedSessKeys = currSSK {dhPrivKey}, prevStoredSessKeys = Just currSSK}

connectRCCtrl_ :: TVar ChaChaDRG -> RCCtrlPairing -> RCInvitation -> J.Value -> ExceptT RCErrorType IO RCCtrlConnection
connectRCCtrl_ drg pairing'@RCCtrlPairing {caKey, caCert} inv@RCInvitation {ca, host, port} hostAppInfo = do
  r <- newEmptyTMVarIO
  c <- liftIO mkClient
  action <- async $ runClient c r
  pure (RCCtrlClient {action, client_ = c}, r)
  where
    mkClient :: IO RCCClient_
    mkClient = do
      tlsEnded <- newEmptyTMVarIO
      confirmSession <- newEmptyTMVarIO
      endSession <- newEmptyTMVarIO
      pure RCCClient_ {confirmSession, endSession, tlsEnded}
    runClient :: RCCClient_ -> RCStepTMVar (SessionCode, RCStepTMVar (RCCtrlSession, RCCtrlPairing)) -> ExceptT RCErrorType IO ()
    runClient RCCClient_ {confirmSession, endSession, tlsEnded} r = do
      clientCredentials <-
        liftIO (genTLSCredentials caKey caCert) >>= \case
          TLS.Credentials [one] -> pure $ Just one
          _ -> throwError $ RCEInternal "genTLSCredentials must generate only one set of credentials"
      let clientConfig = defaultTransportClientConfig {clientCredentials}
      liftIO $ runTransportClient clientConfig Nothing host (show port) (Just ca) $ \tls -> do
        logDebug "Got TLS connection"
        -- TODO this seems incorrect still
        res <- handleAny (pure . Left . RCEException . show) . runExceptT $ do
          logDebug "Waiting for session confirmation"
          r' <- newEmptyTMVarIO
          atomically $ putTMVar r $ Right (tlsUniq tls, r') -- (RCCtrlSession {tls, sessionKeys = ctrlSessKeys}, pairing')
          ifM
            (atomically $ readTMVar confirmSession)
            (runSession tls r')
            (logDebug "Session rejected")
        atomically $ putTMVar tlsEnded res
      where
        runSession tls r' = do
          (sharedKey, kemPrivKey, hostEncHello) <- prepareHostHello drg pairing' inv hostAppInfo
          sendRCPacket tls hostEncHello
          ctrlEncHello <- receiveRCPacket tls
          logDebug "Received ctrl HELLO"
          (ctrlSessKeys, pairing'') <- prepareCtrlSession pairing' inv sharedKey kemPrivKey ctrlEncHello
          atomically $ putTMVar r' $ Right (RCCtrlSession {tls, sessionKeys = ctrlSessKeys}, pairing'')
          -- TODO receive OK response
          logDebug "Session started"
          -- release second putTMVar in confirmCtrlSession
          void . atomically $ takeTMVar confirmSession
          atomically $ takeTMVar endSession
          logDebug "Session ended"

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

prepareHostHello :: TVar ChaChaDRG -> RCCtrlPairing -> RCInvitation -> J.Value -> ExceptT RCErrorType IO (KEMHybridOrDHSecret, KEMSecretKey, RCHostEncHello)
prepareHostHello
  drg
  RCCtrlPairing {caCert, storedSessKeys = StoredCtrlSessKeys {dhPrivKey, kemSharedKey}}
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
            sharedKey = kemHybridOrDHSecret dhPubKey dhPrivKey kemSharedKey
        encBody <- liftEitherWith (const RCEBlockSize) $ kcbEncrypt sharedKey nonce (LB.toStrict $ J.encode helloBody) helloBlockSize
        -- let sessKeys = CtrlSessKeys {hybridKey, idPubKey, sessPubKey = skey}
        let hostEncHello = RCHostEncHello {dhPubKey = C.publicKey dhPrivKey, nonce, encBody}
        pure (sharedKey, kemPrivKey, hostEncHello)

prepareCtrlSession :: RCCtrlPairing -> RCInvitation -> KEMHybridOrDHSecret -> KEMSecretKey -> RCCtrlEncHello -> ExceptT RCErrorType IO (CtrlSessKeys, RCCtrlPairing)
prepareCtrlSession
  pairing@RCCtrlPairing {idPubKey, storedSessKeys = ssk@StoredCtrlSessKeys {dhPrivKey}}
  RCInvitation {skey, dh = dhPubKey}
  sharedKey
  kemPrivKey = \case
    RCCtrlEncHello {kem = kemCiphertext, nonce, encBody} -> do
      kemSharedKey <- liftIO $ sntrup761Dec kemCiphertext kemPrivKey
      let hybridKey = kemHybridSecret dhPubKey dhPrivKey kemSharedKey
      helloBody <- liftEitherWith (const RCEDecrypt) $ kcbDecrypt hybridKey nonce encBody
      logDebug "Decrypted ctrl HELLO"
      RCCtrlHello {} <- liftEitherWith RCESyntax $ J.eitherDecodeStrict helloBody
      let sessKeys = CtrlSessKeys {hybridKey, idPubKey, sessPubKey = skey}
          pairing' = (pairing :: RCCtrlPairing) {storedSessKeys = ssk {kemSharedKey = Just kemSharedKey}}
      pure (sessKeys, pairing')
    RCCtrlEncError {nonce, encMessage} -> do
      message <- liftEitherWith (const RCEDecrypt) $ kcbDecrypt sharedKey nonce encMessage
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
    decrypt (pairing@RCCtrlPairing {storedSessKeys, prevStoredSessKeys} : rest) =
      let r = decrypt_ storedSessKeys <|> (decrypt_ =<< prevStoredSessKeys)
       in maybe (decrypt rest) (Right . (pairing,)) r
    decrypt_ :: StoredCtrlSessKeys -> Maybe ByteString
    decrypt_ StoredCtrlSessKeys {dhPrivKey, kemSharedKey} =
      let key = kemHybridOrDHSecret dhPubKey dhPrivKey kemSharedKey
       in eitherToMaybe $ kcbDecrypt key nonce encInvitation

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
