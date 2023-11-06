{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module Simplex.RemoteControl.Client
  ( RCHostPairing (..),
    RCHostClient (action),
    RCHostSession (..),
    RCHelloBody (..),
    HostSessKeys (..),
    newRCHostPairing,
    connectRCHost,
    cancelHostClient,
    RCCtrlPairing (..),
    RCCtrlClient (action),
    RCCtrlSession (..),
    CtrlSessKeys (..),
    connectRCCtrlURI,
    connectKnownRCCtrlMulticast,
    confirmCtrlSession,
    cancelCtrlClient,
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
import Data.Time.Clock.System (getSystemTime)
import qualified Data.X509 as X509
import Data.X509.Validation (Fingerprint (..), getFingerprint)
import Network.Socket (PortNumber)
import qualified Network.TLS as TLS
import Simplex.Messaging.Agent.Client ()
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.SNTRUP761 (KEMHybridSecret, kcbDecrypt, kcbEncrypt, kemHybridSecret)
import Simplex.Messaging.Crypto.SNTRUP761.Bindings
import Simplex.Messaging.Encoding
import Simplex.Messaging.Parsers (defaultJSON)
import Simplex.Messaging.Transport (TLS (tlsUniq), cGet, cPut)
import Simplex.Messaging.Transport.Client (TransportClientConfig (..), TransportHost, defaultTransportClientConfig, runTransportClient)
import Simplex.Messaging.Transport.Credentials (genCredentials, tlsCredentials)
import Simplex.Messaging.Util (eitherToMaybe, ifM, liftEitherWith, tshow)
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

data RCHelloBody = RCHelloBody
  { v :: Version,
    ca :: C.KeyHash,
    app :: J.Value
  }
  deriving (Show)

$(JQ.deriveJSON defaultJSON ''RCHelloBody)

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

connectRCHost :: TVar ChaChaDRG -> RCHostPairing -> J.Value -> ExceptT RCErrorType IO (RCSignedInvitation, RCHostClient, TMVar (ByteString, TMVar (RCHostSession, RCHelloBody, RCHostPairing)))
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
    runClient :: RCHClient_ -> TMVar (ByteString, TMVar (RCHostSession, RCHelloBody, RCHostPairing)) -> RCHostKeys -> IO (Async ())
    runClient RCHClient_ {startedPort, hostCAHash, endSession, tlsEnded} r hostKeys = do
      tlsCreds <- genTLSCredentials caKey caCert
      startTLSServer startedPort tlsCreds (tlsHooks r knownHost hostCAHash) $ \tls -> do
        res <- handleAny (pure . Left . RCEException . show) . runExceptT $ do
          logDebug "Incoming TLS connection"
          r' <- newEmptyTMVarIO
          atomically $ putTMVar r (tlsUniq tls, r')
          -- TODO lock session
          encryptedHello <- receiveRCPacket tls
          logDebug "Received encrypted HELLO"
          -- TODO send OK response
          hostCA <- atomically $ takeTMVar hostCAHash
          logDebug "TLS fingerprint ready"
          (sessionKeys, helloBody, pairing') <- prepareHostSession hostCA pairing hostKeys encryptedHello
          logDebug "Prepared host session"
          -- TODO: Send OK
          atomically $ putTMVar r' (RCHostSession {tls, sessionKeys}, helloBody, pairing')
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
      kemKeys <- sntrup761Keypair drg
      dhKeys <- C.generateKeyPair'
      pure RCHostKeys {sessKeys, kemKeys, dhKeys}
    mkInvitation :: RCHostKeys -> TransportHost -> PortNumber -> IO RCSignedInvitation
    mkInvitation RCHostKeys {sessKeys, kemKeys, dhKeys} host portNum = do
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
                kem = fst kemKeys,
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

prepareHostSession :: C.KeyHash -> RCHostPairing -> RCHostKeys -> RCHostHello -> ExceptT RCErrorType IO (HostSessKeys, RCHelloBody, RCHostPairing)
prepareHostSession
  tlsHostFingerprint
  pairing@RCHostPairing {idPrivKey, knownHost = knownHost_}
  RCHostKeys {sessKeys = (_, sessPrivKey), kemKeys = (_, kemPrivKey), dhKeys = (_, dhPrivKey)}
  RCHostHello {dhPubKey, kemCiphertext, nonce, encryptedBody} = do
    kemSharedKey <- liftIO $ sntrup761Dec kemCiphertext kemPrivKey
    let key = kemHybridSecret dhPubKey dhPrivKey kemSharedKey
    helloBody <- liftEitherWith (const RCEDecrypt) $ kcbDecrypt key nonce encryptedBody
    hello@RCHelloBody {v, ca} <- liftEitherWith RCESyntax $ J.eitherDecodeStrict helloBody
    unless (isCompatible v supportedRCVRange) $ throwError RCEVersion
    let keys = HostSessKeys {key, idPrivKey, sessPrivKey}
        storedSessKeys = StoredHostSessKeys {hostDHPublicKey = dhPubKey, kemSharedKey}
    knownHost' <- updateKnownHost ca storedSessKeys
    pure (keys, hello, pairing {knownHost = Just knownHost'})
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

connectRCCtrlURI :: TVar ChaChaDRG -> RCSignedInvitation -> Maybe RCCtrlPairing -> J.Value -> ExceptT RCErrorType IO (RCCtrlClient, TMVar (RCCtrlSession, RCCtrlPairing))
connectRCCtrlURI drg signedInv@RCSignedInvitation {invitation} pairing_ hostAppInfo = do
  unless (verifySignedInviteURI signedInv) $ throwError RCECtrlAuth
  connectRCCtrl drg invitation pairing_ hostAppInfo

-- app should determine whether it is a new or known pairing based on CA fingerprint in the invitation
connectRCCtrl :: TVar ChaChaDRG -> RCInvitation -> Maybe RCCtrlPairing -> J.Value -> ExceptT RCErrorType IO (RCCtrlClient, TMVar (RCCtrlSession, RCCtrlPairing))
connectRCCtrl drg inv@RCInvitation {ca, idkey, kem} pairing_ hostAppInfo = do
  (ct, pairing') <- maybe (liftIO newCtrlPairing) updateCtrlPairing pairing_
  connectRCCtrl_ drg pairing' inv ct hostAppInfo
  where
    newCtrlPairing :: IO (KEMCiphertext, RCCtrlPairing)
    newCtrlPairing = do
      ((_, caKey), caCert) <- genCredentials Nothing (0, 24 * 999999) "ca"
      (ct, storedSessKeys) <- generateCtrlSessKeys drg kem
      let pairing = RCCtrlPairing {caKey, caCert, ctrlFingerprint = ca, idPubKey = idkey, storedSessKeys, prevStoredSessKeys = Nothing}
      pure (ct, pairing)
    updateCtrlPairing :: RCCtrlPairing -> ExceptT RCErrorType IO (KEMCiphertext, RCCtrlPairing)
    updateCtrlPairing pairing@RCCtrlPairing {ctrlFingerprint, idPubKey, storedSessKeys = prevSSK} = do
      unless (ca == ctrlFingerprint && idPubKey == idkey) $ throwError RCEIdentity
      (ct, storedSessKeys) <- liftIO $ generateCtrlSessKeys drg kem
      let pairing' = pairing {storedSessKeys, prevStoredSessKeys = Just prevSSK}
      pure (ct, pairing')

generateCtrlSessKeys :: TVar ChaChaDRG -> KEMPublicKey -> IO (KEMCiphertext, StoredCtrlSessKeys)
generateCtrlSessKeys drg kemPublicKey = do
  (_, dhPrivKey) <- C.generateKeyPair'
  (ct, kemSharedKey) <- sntrup761Enc drg kemPublicKey
  pure (ct, StoredCtrlSessKeys {dhPrivKey, kemSharedKey})

connectRCCtrl_ :: TVar ChaChaDRG -> RCCtrlPairing -> RCInvitation -> KEMCiphertext -> J.Value -> ExceptT RCErrorType IO (RCCtrlClient, TMVar (RCCtrlSession, RCCtrlPairing))
connectRCCtrl_ drg pairing'@RCCtrlPairing {caKey, caCert} inv@RCInvitation {ca, host, port} ct hostAppInfo = do
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
    runClient :: RCCClient_ -> TMVar (RCCtrlSession, RCCtrlPairing) -> ExceptT RCErrorType IO ()
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
          (ctrlSessKeys, encryptedHello) <- prepareCtrlSession drg pairing' inv hostAppInfo ct
          logDebug "Waiting for session confirmation"
          atomically $ putTMVar r (RCCtrlSession {tls, sessionKeys = ctrlSessKeys}, pairing')
          ifM
            (atomically $ readTMVar confirmSession)
            (runSession tls encryptedHello)
            (logDebug "Session rejected")
        atomically $ putTMVar tlsEnded res
      where
        runSession tls encryptedHello = do
          sendRCPacket tls encryptedHello
          logDebug "Sent encrypted HELLO"
          -- TODO receive OK response
          logDebug "Session started"
          -- release second putTMVar in confirmCtrlSession
          void . atomically $ takeTMVar confirmSession
          atomically $ takeTMVar endSession
          logDebug "Session ended"

sendRCPacket :: Encoding a => TLS -> a -> ExceptT RCErrorType IO ()
sendRCPacket tls pkt = do
  logDebug "Encoding XRCP block for TLS"
  b <- liftEitherWith (const RCEBlockSize) $ C.pad (smpEncode pkt) xrcpBlockSize
  logDebug $ "Sending XRCP block to TLS, " <> tshow (B.length b) <> " bytes"
  liftIO $ cPut tls b

receiveRCPacket :: Encoding a => TLS -> ExceptT RCErrorType IO a
receiveRCPacket tls = do
  logDebug "Getting XRCP block from TLS"
  b <- liftIO $ cGet tls xrcpBlockSize
  logDebug $ "Got XRCP block from TLS, " <> tshow (B.length b) <> " bytes"
  when (B.length b /= xrcpBlockSize) $ throwError RCEBlockSize
  b' <- liftEitherWith (const RCEBlockSize) $ C.unPad b
  liftEitherWith RCESyntax $ smpDecode b'

prepareCtrlSession :: TVar ChaChaDRG -> RCCtrlPairing -> RCInvitation -> J.Value -> KEMCiphertext -> ExceptT RCErrorType IO (CtrlSessKeys, RCHostHello)
prepareCtrlSession
  drg
  RCCtrlPairing {caCert, idPubKey, storedSessKeys = StoredCtrlSessKeys {dhPrivKey, kemSharedKey}}
  RCInvitation {v, skey, dh = dhPubKey}
  hostAppInfo
  kemCiphertext = do
    logDebug "Preparing session"
    case compatibleVersion v supportedRCVRange of
      Nothing -> throwError RCEVersion
      Just (Compatible v') -> do
        let Fingerprint fp = getFingerprint caCert X509.HashSHA256
            helloBody = RCHelloBody {v = v', ca = C.KeyHash fp, app = hostAppInfo}
            hybridKey = kemHybridSecret dhPubKey dhPrivKey kemSharedKey
        nonce <- liftIO . atomically $ C.pseudoRandomCbNonce drg
        encryptedBody <- liftEitherWith (const RCEBlockSize) $ kcbEncrypt hybridKey nonce (LB.toStrict $ J.encode helloBody) helloBlockSize
        let sessKeys = CtrlSessKeys {hybridKey, idPubKey, sessPubKey = skey}
            encHello = RCHostHello {dhPubKey = C.publicKey dhPrivKey, kemCiphertext, nonce, encryptedBody}
        pure (sessKeys, encHello)

-- The application should save updated RCHostPairing after user confirmation of the session
-- TMVar resolves when TLS is connected
connectKnownRCCtrlMulticast :: TVar ChaChaDRG -> TVar Int -> NonEmpty RCCtrlPairing -> J.Value -> ExceptT RCErrorType IO (RCCtrlClient, TMVar (RCCtrlSession, RCCtrlPairing))
connectKnownRCCtrlMulticast drg _subscribers pairings hostAppInfo = do
  -- start multicast
  -- receive packets
  let loop = undefined -- catch and log errors, fail on timeout
      receive = undefined
      parse = undefined
  (pairing, inv) <- loop $ receive >>= parse >>= findRCCtrlPairing pairings
  connectRCCtrl drg inv pairing hostAppInfo

findRCCtrlPairing :: NonEmpty RCCtrlPairing -> RCEncryptedInvitation -> ExceptT RCErrorType IO (RCCtrlPairing, RCInvitation)
findRCCtrlPairing pairings RCEncryptedInvitation {dhPubKey, nonce, encryptedInvitation} = do
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
      let key = kemHybridSecret dhPubKey dhPrivKey kemSharedKey
       in eitherToMaybe $ kcbDecrypt key nonce encryptedInvitation

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

-- | Long-term part of controller (desktop) connection to host (mobile)
data RCHostPairing = RCHostPairing
  { caKey :: C.APrivateSignKey,
    caCert :: C.SignedCertificate,
    idPrivKey :: C.PrivateKeyEd25519,
    knownHost :: Maybe KnownHostPairing
  }

data KnownHostPairing = KnownHostPairing
  { hostFingerprint :: C.KeyHash, -- this is only changed in the first session, long-term identity of connected remote host
    storedSessKeys :: StoredHostSessKeys
  }

data StoredHostSessKeys = StoredHostSessKeys
  { hostDHPublicKey :: C.PublicKeyX25519, -- sent by host in HELLO block. Matches one of the DH keys in RCCtrlPairing
    kemSharedKey :: KEMSharedKey
  }

-- | Long-term part of host (mobile) connection to controller (desktop)
data RCCtrlPairing = RCCtrlPairing
  { caKey :: C.APrivateSignKey,
    caCert :: C.SignedCertificate,
    ctrlFingerprint :: C.KeyHash, -- long-term identity of connected remote controller
    idPubKey :: C.PublicKeyEd25519,
    storedSessKeys :: StoredCtrlSessKeys,
    prevStoredSessKeys :: Maybe StoredCtrlSessKeys
  }

data StoredCtrlSessKeys = StoredCtrlSessKeys
  { dhPrivKey :: C.PrivateKeyX25519,
    kemSharedKey :: KEMSharedKey
  }

data RCHostKeys = RCHostKeys
  { sessKeys :: C.KeyPair 'C.Ed25519,
    kemKeys :: KEMKeyPair,
    dhKeys :: C.KeyPair 'C.X25519
  }

-- Connected session with Host
data RCHostSession = RCHostSession
  { tls :: TLS,
    sessionKeys :: HostSessKeys
  }

data HostSessKeys = HostSessKeys
  { key :: KEMHybridSecret,
    idPrivKey :: C.PrivateKeyEd25519,
    sessPrivKey :: C.PrivateKeyEd25519
  }

-- Host: RCCtrlPairing + RCInvitation => (RCCtrlSession, RCCtrlPairing)

data RCCtrlSession = RCCtrlSession
  { tls :: TLS,
    sessionKeys :: CtrlSessKeys
  }

data CtrlSessKeys = CtrlSessKeys
  { hybridKey :: KEMHybridSecret,
    idPubKey :: C.PublicKeyEd25519,
    sessPubKey :: C.PublicKeyEd25519
  }

data RCHostHello = RCHostHello
  { dhPubKey :: C.PublicKeyX25519,
    kemCiphertext :: KEMCiphertext,
    nonce :: C.CbNonce,
    encryptedBody :: ByteString
  }
  deriving (Show)

instance Encoding RCHostHello where
  smpEncode RCHostHello {dhPubKey, kemCiphertext, nonce, encryptedBody} =
    "HELLO " <> smpEncode (dhPubKey, kemCiphertext, nonce, Tail encryptedBody)
  smpP = do
    (dhPubKey, kemCiphertext, nonce, Tail encryptedBody) <- "HELLO " *> smpP
    pure RCHostHello {dhPubKey, kemCiphertext, nonce, encryptedBody}
