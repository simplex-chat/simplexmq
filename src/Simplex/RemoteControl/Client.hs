{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module Simplex.RemoteControl.Client where

import Control.Applicative ((<|>))
import Control.Concurrent.Async (Async)
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class
import Crypto.Random (ChaChaDRG)
import qualified Data.Aeson as J
import qualified Data.Aeson.TH as JQ
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LB
import Data.Default (def)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import Data.Time.Clock.System (getSystemTime)
import Data.Word (Word16)
import qualified Data.X509 as X509
import Data.X509.Validation (Fingerprint (..), getFingerprint)
import Network.Socket (PortNumber)
import qualified Network.TLS as TLS
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.SNTRUP761 (KEMHybridSecret, kcbDecrypt, kcbEncrypt, kemHybridSecret)
import Simplex.Messaging.Crypto.SNTRUP761.Bindings
import Simplex.Messaging.Encoding
import Simplex.Messaging.Parsers (defaultJSON)
import Simplex.Messaging.Transport (TLS, cGet)
import Simplex.Messaging.Transport.Client (TransportHost)
import Simplex.Messaging.Transport.Credentials (genCredentials, tlsCredentials)
import Simplex.Messaging.Util (eitherToMaybe, liftEitherWith, ($>>=))
import Simplex.Messaging.Version
import Simplex.RemoteControl.Discovery (startTLSServer)
import Simplex.RemoteControl.Invitation
import Simplex.RemoteControl.Types
import UnliftIO
import UnliftIO.STM

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

$(JQ.deriveJSON defaultJSON ''RCHelloBody)

newRCHostPairing :: IO RCHostPairing
newRCHostPairing = do
  ((_, caKey), caCert) <- genCredentials Nothing (-25, 24 * 999999) "ca"
  (_, idPrivKey) <- C.generateKeyPair'
  pure RCHostPairing {caKey, caCert, idPrivKey, knownHost = Nothing}

data RCHostClient = RCHostClient
  { tlsServer :: Async (),
    dropSession :: TMVar ()
  }

connectRCHost :: TVar ChaChaDRG -> RCHostPairing -> J.Value -> TransportHost -> ExceptT RCErrorType IO (RCInvitation, RCHostClient, TMVar (RCHostSession, RCHelloBody, RCHostPairing))
connectRCHost drg pairing@RCHostPairing {caKey, caCert, idPrivKey} ctrlAppInfo host = do
  r <- newEmptyTMVarIO
  startedPort <- newEmptyTMVarIO
  hpk <- newEmptyTMVarIO

  tlsCreds <- liftIO genTLSCredentials
  dropSession <- newEmptyTMVarIO
  tlsFinished <- newEmptyTMVarIO
  tlsFingerprint <- newEmptyTMVarIO
  tlsServer <- liftIO $ startTLSServer startedPort tlsCreds (tlsHooks tlsFingerprint) $ \tls -> do
    res <- handleAny (pure . Left . RCECtrlException . show) . runExceptT $ do
      hostPrivateKeys <- atomically $ takeTMVar hpk -- a roundabout way to get server's own assigned port. NB: take is used, and the keys are consumed by the first connection
      helloBlock <- liftIO $ cGet tls 16384
      encryptedHello <- liftEitherWith RCESyntax $ smpDecode helloBlock
      hostCA <- atomically $ takeTMVar tlsFingerprint
      (hostSessKeys, rcHelloBody, rcHostPairing) <- prepareHostSession hostCA pairing hostPrivateKeys encryptedHello
      atomically $ putTMVar r (RCHostSession {tls, sessionKeys = hostSessKeys}, rcHelloBody, rcHostPairing)
      -- can use `RCHostSession` until `dropSession` is signalled
      atomically $ takeTMVar dropSession
    atomically $ putTMVar tlsFinished res

  -- wait for the port and prepare session keys
  (inv, hostPrivateKeys) <- atomically (readTMVar startedPort) >>= maybe (throwError RCETLSStartFailed) mkHostSession
  -- put keys for the incoming connection
  atomically $ putTMVar hpk hostPrivateKeys
  -- return invitation immediately
  pure (inv, RCHostClient {tlsServer, dropSession}, r)
  where
    genTLSCredentials :: IO TLS.Credentials
    genTLSCredentials = do
      let caCreds = (C.signatureKeyPair caKey, caCert)
      leaf <- genCredentials (Just caCreds) (0, 24 * 999999) "localhost" -- session-signing cert
      pure . snd $ tlsCredentials (leaf :| [caCreds])
    tlsHooks :: TMVar C.KeyHash -> TLS.ServerHooks
    tlsHooks tlsClientCert =
      def
        { TLS.onUnverifiedClientCert = pure True,
          TLS.onClientCertificate = \(X509.CertificateChain chain) ->
            case chain of
              [_leaf, ca] -> do
                let Fingerprint fp = getFingerprint ca X509.HashSHA256
                atomically $ putTMVar tlsClientCert $ C.KeyHash fp
                pure TLS.CertificateUsageAccept
              _ ->
                pure $ TLS.CertificateUsageReject TLS.CertificateRejectUnknownCA
        }
    mkHostSession :: MonadIO m => PortNumber -> m (RCInvitation, RCHostPrivateKeys)
    mkHostSession portNum = liftIO $ do
      ts <- getSystemTime
      (skey, sessPrivKey) <- C.generateKeyPair'
      (kem, kemPrivKey) <- sntrup761Keypair drg
      (dh, dhPrivKey) <- C.generateKeyPair'
      let inv =
            RCInvitation
              { ca = certFingerprint caCert,
                host,
                port = fromIntegral portNum,
                v = supportedRCVRange,
                app = ctrlAppInfo,
                ts,
                skey,
                idkey = C.publicKey idPrivKey,
                kem,
                dh
              }
          keys = RCHostPrivateKeys {sessPrivKey, kemPrivKey, dhPrivKey}
      pure (inv, keys)

certFingerprint :: X509.SignedCertificate -> C.KeyHash
certFingerprint caCert = C.KeyHash fp
  where
    Fingerprint fp = getFingerprint caCert X509.HashSHA256

cancelHostClient :: RCHostClient -> IO ()
cancelHostClient = undefined

prepareHostSession :: C.KeyHash -> RCHostPairing -> RCHostPrivateKeys -> RCEncryptedHello -> ExceptT RCErrorType IO (HostSessKeys, RCHelloBody, RCHostPairing)
prepareHostSession
  tlsHostFingerprint
  pairing@RCHostPairing {idPrivKey, knownHost = knownHost_}
  RCHostPrivateKeys {sessPrivKey, kemPrivKey, dhPrivKey}
  RCEncryptedHello {dhPubKey, kemCiphertext, nonce, encryptedBody} = do
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
          unless (h.hostFingerprint == tlsHostFingerprint) $
            throwError $
              RCEInternal "TLS host CA is different from host pairing, should be caught in TLS handshake"
          unless (ca == tlsHostFingerprint) $ throwError RCEIdentity
          pure (h :: KnownHostPairing) {storedSessKeys}
        Nothing -> pure KnownHostPairing {hostFingerprint = ca, storedSessKeys}

data RCCtrlClient = RCCtrlClient
  { action :: Async ()
  }

connectRCCtrlURI :: TVar ChaChaDRG -> RCSignedInvitation -> Maybe RCCtrlPairing -> ExceptT RCErrorType IO (RCCtrlClient, TMVar (RCCtrlSession, RCCtrlPairing))
connectRCCtrlURI drg signedInv@RCSignedInvitation {invitation} pairing_ = do
  unless (verifySignedInviteURI signedInv) $ throwError RCECtrlAuth
  connectRCCtrl drg invitation pairing_

-- app should determine whether it is a new or known pairing based on CA fingerprint in the invitation
connectRCCtrl :: TVar ChaChaDRG -> RCInvitation -> Maybe RCCtrlPairing -> ExceptT RCErrorType IO (RCCtrlClient, TMVar (RCCtrlSession, RCCtrlPairing))
connectRCCtrl drg inv@RCInvitation {ca, idkey, kem} pairing_ = do
  (ct, pairing) <- maybe (liftIO newCtrlPairing) updateCtrlPairing pairing_
  connectRCCtrl_ drg pairing inv ct
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

connectRCCtrl_ :: TVar ChaChaDRG -> RCCtrlPairing -> RCInvitation -> KEMCiphertext -> ExceptT RCErrorType IO (RCCtrlClient, TMVar (RCCtrlSession, RCCtrlPairing))
connectRCCtrl_ _drg _pairing _inv _ct = do
  r <- newEmptyTMVarIO
  client <- do
    -- start client connection to TLS
    -- (CtrlSessKeys, RCEncryptedHello) <- prepareCtrlSession :: TVar ChaChaDRG -> RCCtrlPairing -> RCInvitation -> J.Value -> KEMCiphertext -> IO (CtrlSessKeys, RCEncryptedHello)
    -- putTMVar r
    pure undefined
  pure (client, r)

-- cryptography
prepareCtrlSession :: TVar ChaChaDRG -> RCCtrlPairing -> RCInvitation -> J.Value -> KEMCiphertext -> ExceptT RCErrorType IO (CtrlSessKeys, RCEncryptedHello)
prepareCtrlSession
  drg
  RCCtrlPairing {caCert, idPubKey, storedSessKeys = StoredCtrlSessKeys {dhPrivKey, kemSharedKey}}
  RCInvitation {v, skey, dh = dhPubKey}
  hostAppInfo
  kemCiphertext =
    case compatibleVersion v supportedRCVRange of
      Nothing -> throwError RCEVersion
      Just (Compatible v') -> do
        let Fingerprint fp = getFingerprint caCert X509.HashSHA256
            helloBody = RCHelloBody {v = v', ca = C.KeyHash fp, app = hostAppInfo}
            hybridKey = kemHybridSecret dhPubKey dhPrivKey kemSharedKey
        nonce <- liftIO . atomically $ C.pseudoRandomCbNonce drg
        encryptedBody <- liftEitherWith (const RCELargeMsg) $ kcbEncrypt hybridKey nonce (LB.toStrict $ J.encode helloBody) helloBlockSize
        let sessKeys = CtrlSessKeys {hybridKey, idPubKey, sessPubKey = skey}
            encHello = RCEncryptedHello {dhPubKey = C.publicKey dhPrivKey, kemCiphertext, nonce, encryptedBody}
        pure (sessKeys, encHello)

-- The application should save updated RCHostPairing after user confirmation of the session
-- TMVar resolves when TLS is connected
connectKnownRCCtrlMulticast :: TVar ChaChaDRG -> NonEmpty RCCtrlPairing -> ExceptT RCErrorType IO (RCCtrlClient, TMVar (RCCtrlSession, RCCtrlPairing))
connectKnownRCCtrlMulticast drg pairings = do
  -- start multicast
  -- receive packets
  let loop = undefined -- catch and log errors, fail on timeout
      receive = undefined
      parse = undefined
  (pairing, inv) <- loop $ receive >>= parse >>= findRCCtrlPairing pairings
  connectRCCtrl drg inv pairing

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
confirmCtrlSession = undefined

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

data RCHostPrivateKeys = RCHostPrivateKeys
  { sessPrivKey :: C.PrivateKeyEd25519,
    kemPrivKey :: KEMSecretKey,
    dhPrivKey :: C.PrivateKeyX25519
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

data RCEncryptedHello = RCEncryptedHello
  { dhPubKey :: C.PublicKeyX25519,
    kemCiphertext :: KEMCiphertext,
    nonce :: C.CbNonce,
    encryptedBody :: ByteString
  }

instance Encoding RCEncryptedHello where
  smpEncode RCEncryptedHello {} = error "TODO: RCEncryptedHello.smpEncode"
  smpP = error "TODO: RCEncryptedHello.smpP"
