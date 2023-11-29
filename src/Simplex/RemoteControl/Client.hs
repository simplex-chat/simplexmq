{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
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
    connectRCCtrl,
    discoverRCCtrl,
    confirmCtrlSession,
    cancelCtrlClient,
    RCStepTMVar,
    rcEncryptBody,
    rcDecryptBody,
    xrcpBlockSize,
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
import Data.Word (Word16)
import qualified Data.X509 as X509
import Data.X509.Validation (Fingerprint (..), getFingerprint)
import Network.Socket (PortNumber, SockAddr (..), hostAddressToTuple)
import qualified Network.TLS as TLS
import qualified Network.UDP as UDP
import Simplex.Messaging.Agent.Client ()
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Lazy (LazyByteString)
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Crypto.SNTRUP761
import Simplex.Messaging.Crypto.SNTRUP761.Bindings
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Transport (TLS (..), cGet, cPut)
import Simplex.Messaging.Transport.Buffer (peekBuffered)
import Simplex.Messaging.Transport.Client (TransportClientConfig (..), TransportHost (..), defaultTransportClientConfig, runTransportClient)
import Simplex.Messaging.Transport.Credentials (genCredentials, tlsCredentials)
import Simplex.Messaging.Util
import Simplex.Messaging.Version
import Simplex.RemoteControl.Discovery (getLocalAddress, recvAnnounce, startTLSServer, withListener, withSender)
import Simplex.RemoteControl.Invitation
import Simplex.RemoteControl.Types
import UnliftIO
import UnliftIO.Concurrent

currentRCVersion :: Version
currentRCVersion = 1

supportedRCVRange :: VersionRange
supportedRCVRange = mkVersionRange 1 currentRCVersion

xrcpBlockSize :: Int
xrcpBlockSize = 16384

helloBlockSize :: Int
helloBlockSize = 12288

encInvitationSize :: Int
encInvitationSize = 900

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
    announcer :: TMVar (Async (Either RCErrorType ())),
    hostCAHash :: TMVar C.KeyHash,
    endSession :: TMVar ()
  }

type RCHostConnection = (NonEmpty RCCtrlAddress, RCSignedInvitation, RCHostClient, RCStepTMVar (SessionCode, TLS, RCStepTMVar (RCHostSession, RCHostHello, RCHostPairing)))

connectRCHost :: TVar ChaChaDRG -> RCHostPairing -> J.Value -> Bool -> Maybe RCCtrlAddress -> Maybe Word16 -> ExceptT RCErrorType IO RCHostConnection
connectRCHost drg pairing@RCHostPairing {caKey, caCert, idPrivKey, knownHost} ctrlAppInfo multicast rcAddrPrefs_ port_ = do
  r <- newEmptyTMVarIO
  found@(RCCtrlAddress {address} :| _) <- findCtrlAddress
  c@RCHClient_ {startedPort, announcer} <- liftIO mkClient
  hostKeys <- liftIO genHostKeys
  action <- runClient c r hostKeys `putRCError` r
  -- wait for the port to make invitation
  portNum <- atomically $ readTMVar startedPort
  signedInv@RCSignedInvitation {invitation} <- maybe (throwError RCETLSStartFailed) (liftIO . mkInvitation hostKeys address) portNum
  when multicast $ case knownHost of
    Nothing -> throwError RCENewController
    Just KnownHostPairing {hostDhPubKey} -> do
      ann <- async . liftIO . runExceptT $ announceRC drg 60 idPrivKey hostDhPubKey hostKeys invitation
      atomically $ putTMVar announcer ann
  pure (found, signedInv, RCHostClient {action, client_ = c}, r)
  where
    findCtrlAddress :: ExceptT RCErrorType IO (NonEmpty RCCtrlAddress)
    findCtrlAddress = do
      found' <- liftIO $ getLocalAddress rcAddrPrefs_
      maybe (throwError RCENoLocalAddress) pure $ L.nonEmpty found'
    mkClient :: IO RCHClient_
    mkClient = do
      startedPort <- newEmptyTMVarIO
      announcer <- newEmptyTMVarIO
      endSession <- newEmptyTMVarIO
      hostCAHash <- newEmptyTMVarIO
      pure RCHClient_ {startedPort, announcer, hostCAHash, endSession}
    runClient :: RCHClient_ -> RCStepTMVar (SessionCode, TLS, RCStepTMVar (RCHostSession, RCHostHello, RCHostPairing)) -> RCHostKeys -> ExceptT RCErrorType IO (Async ())
    runClient RCHClient_ {startedPort, announcer, hostCAHash, endSession} r hostKeys = do
      tlsCreds <- liftIO $ genTLSCredentials caKey caCert
      startTLSServer port_ startedPort tlsCreds (tlsHooks r knownHost hostCAHash) $ \tls ->
        void . runExceptT $ do
          r' <- newEmptyTMVarIO
          whenM (atomically $ tryPutTMVar r $ Right (tlsUniq tls, tls, r')) $
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
            atomically (tryReadTMVar announcer) >>= mapM_ uninterruptibleCancel
            -- can use `RCHostSession` until `endSession` is signalled
            logDebug "Holding session"
            atomically $ takeTMVar endSession
    tlsHooks :: TMVar a -> Maybe KnownHostPairing -> TMVar C.KeyHash -> TLS.ServerHooks
    tlsHooks r knownHost_ hostCAHash =
      def
        { TLS.onNewHandshake = \_ -> atomically $ isNothing <$> tryReadTMVar r,
          TLS.onClientCertificate = \(X509.CertificateChain chain) ->
            case chain of
              [_leaf, ca] -> do
                let kh = certFingerprint ca
                    accept = maybe True (\h -> hostFingerprint h == kh) knownHost_
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
      pure $ signInvitation (snd sessKeys) idPrivKey inv

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
cancelHostClient RCHostClient {action, client_ = RCHClient_ {announcer, endSession}} = do
  atomically $ putTMVar endSession ()
  atomically (tryTakeTMVar announcer) >>= mapM_ uninterruptibleCancel
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
          unless (hostFingerprint h == tlsHostFingerprint) . throwError $
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

type RCCtrlConnection = (RCCtrlClient, RCStepTMVar (SessionCode, TLS, RCStepTMVar (RCCtrlSession, RCCtrlPairing)))

-- app should determine whether it is a new or known pairing based on CA fingerprint in the invitation
connectRCCtrl :: TVar ChaChaDRG -> RCVerifiedInvitation -> Maybe RCCtrlPairing -> J.Value -> ExceptT RCErrorType IO RCCtrlConnection
connectRCCtrl drg (RCVerifiedInvitation inv@RCInvitation {ca, idkey}) pairing_ hostAppInfo = do
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
    runClient :: RCCClient_ -> RCStepTMVar (SessionCode, TLS, RCStepTMVar (RCCtrlSession, RCCtrlPairing)) -> ExceptT RCErrorType IO ()
    runClient RCCClient_ {confirmSession, endSession} r = do
      clientCredentials <-
        liftIO (genTLSCredentials caKey caCert) >>= \case
          TLS.Credentials (creds : _) -> pure $ Just creds
          _ -> throwError $ RCEInternal "genTLSCredentials must generate credentials"
      let clientConfig = defaultTransportClientConfig {clientCredentials}
      runTransportClient clientConfig Nothing host (show port) (Just ca) $ \tls@TLS {tlsBuffer, tlsContext} -> do
        -- pump socket to detect connection problems
        liftIO $ peekBuffered tlsBuffer 100000 (TLS.recvData tlsContext) >>= logDebug . tshow -- should normally be ("", Nothing) here
        logDebug "Got TLS connection"
        r' <- newEmptyTMVarIO
        whenM (atomically $ tryPutTMVar r $ Right (tlsUniq tls, tls, r')) $ do
          logDebug "Waiting for session confirmation"
          whenM (atomically $ readTMVar confirmSession) $ runSession tls r' `putRCError` r'
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
        let helloBody = RCHostHello {v = v', ca = certFingerprint caCert, app = hostAppInfo, kem = kemPubKey}
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

-- * Multicast discovery

announceRC :: TVar ChaChaDRG -> Int -> C.PrivateKeyEd25519 -> C.PublicKeyX25519 -> RCHostKeys -> RCInvitation -> ExceptT RCErrorType IO ()
announceRC drg maxCount idPrivKey knownDhPub RCHostKeys {sessKeys, dhKeys} inv = withSender $ \sender -> do
  replicateM_ maxCount $ do
    logDebug "Announcing..."
    nonce <- atomically $ C.pseudoRandomCbNonce drg
    encInvitation <- liftEitherWith undefined $ C.cbEncrypt sharedKey nonce sigInvitation encInvitationSize
    liftIO . UDP.send sender $ smpEncode RCEncInvitation {dhPubKey, nonce, encInvitation}
    threadDelay 1000000
  where
    sigInvitation = strEncode $ signInvitation sPrivKey idPrivKey inv
    (_sPub, sPrivKey) = sessKeys
    sharedKey = C.dh' knownDhPub dhPrivKey
    (dhPubKey, dhPrivKey) = dhKeys

discoverRCCtrl :: TMVar Int -> NonEmpty RCCtrlPairing -> ExceptT RCErrorType IO (RCCtrlPairing, RCVerifiedInvitation)
discoverRCCtrl subscribers pairings =
  timeoutThrow RCENotDiscovered 30000000 $ withListener subscribers $ \listener ->
    loop $ do
      (source, bytes) <- recvAnnounce listener
      encInvitation <- liftEitherWith (const RCEInvitation) $ smpDecode bytes
      r@(_, RCVerifiedInvitation RCInvitation {host}) <- findRCCtrlPairing pairings encInvitation
      case source of
        SockAddrInet _ ha | THIPv4 (hostAddressToTuple ha) == host -> pure ()
        _ -> throwError RCEInvitation
      pure r
  where
    loop :: ExceptT RCErrorType IO a -> ExceptT RCErrorType IO a
    loop action =
      liftIO (runExceptT action) >>= \case
        Left err -> logError (tshow err) >> loop action
        Right res -> pure res

findRCCtrlPairing :: NonEmpty RCCtrlPairing -> RCEncInvitation -> ExceptT RCErrorType IO (RCCtrlPairing, RCVerifiedInvitation)
findRCCtrlPairing pairings RCEncInvitation {dhPubKey, nonce, encInvitation} = do
  (pairing, signedInvStr) <- liftEither $ decrypt (L.toList pairings)
  signedInv <- liftEitherWith RCESyntax $ strDecode signedInvStr
  inv@(RCVerifiedInvitation RCInvitation {dh = invDh}) <- maybe (throwError RCEInvitation) pure $ verifySignedInvitation signedInv
  unless (invDh == dhPubKey) $ throwError RCEInvitation
  pure (pairing, inv)
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

-- * Controller handle operations

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

-- * Session encryption

rcEncryptBody :: TVar ChaChaDRG -> KEMHybridSecret -> LazyByteString -> ExceptT RCErrorType IO (C.CbNonce, LazyByteString)
rcEncryptBody drg hybridKey s = do
  nonce <- atomically $ C.pseudoRandomCbNonce drg
  let len = LB.length s
  ct <- liftEitherWith (const RCEEncrypt) $ LC.kcbEncryptTailTag hybridKey nonce s len (len + 8)
  pure (nonce, ct)

rcDecryptBody :: KEMHybridSecret -> C.CbNonce -> LazyByteString -> ExceptT RCErrorType IO LazyByteString
rcDecryptBody hybridKey nonce ct = do
  let len = LB.length ct - 16
  when (len < 0) $ throwError RCEDecrypt
  (ok, s) <- liftEitherWith (const RCEDecrypt) $ LC.kcbDecryptTailTag hybridKey nonce len ct
  unless ok $ throwError RCEDecrypt
  pure s
