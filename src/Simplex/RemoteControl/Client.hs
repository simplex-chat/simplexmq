{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module Simplex.RemoteControl.Client where

import Control.Concurrent.Async (Async)
import Control.Monad
import Control.Monad.Except (ExceptT, throwError)
import Control.Monad.IO.Class
import Crypto.Random (ChaChaDRG)
import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Time.Clock.System (getSystemTime)
import Data.Word (Word16)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.SNTRUP761 (KEMHybridSecret, kcbDecrypt, kemHybridSecret)
import Simplex.Messaging.Crypto.SNTRUP761.Bindings
import Simplex.Messaging.Transport (TLS)
import Simplex.Messaging.Transport.Client (TransportHost)
import Simplex.Messaging.Transport.Credentials (genCredentials)
import Simplex.Messaging.Version (Version, VersionRange, mkVersionRange)
import Simplex.RemoteControl.Invitation (RCInvitation (..))
import UnliftIO (TVar, newEmptyTMVarIO)
import UnliftIO.STM (TMVar)

currentRCVersion :: Version
currentRCVersion = 1

supportedRCVRange :: VersionRange
supportedRCVRange = mkVersionRange 1 currentRCVersion

data RCErrorType = RCEInternal String | RCEBadHelloFingerprint

newRCHostPairing :: IO RCHostPairing
newRCHostPairing = do
  ((_, caKey), caCert) <- genCredentials Nothing (-25, 24 * 999999) "ca"
  (_, idPrivKey) <- C.generateKeyPair'
  pure RCHostPairing {caKey, caCert, idPrivKey, knownHost = Nothing}

data RCHostClient = RCHostClient
  { async :: Async ()
  }

connectRCHost :: TVar ChaChaDRG -> RCHostPairing -> J.Value -> ExceptT RCErrorType IO (RCInvitation, RCHostClient, TMVar (RCHostSession, RCHelloBody, RCHostPairing))
connectRCHost drg RCHostPairing {caKey, caCert, idPrivKey, knownHost} appInfo = do
  -- start TLS connection
  (host, port) <- pure undefined
  (inv, keys) <- liftIO $ mkHostSession host port
  r <- newEmptyTMVarIO
  -- wait for TLS connection, possibly start multicast if knownHost is not Nothing
  client <- do
    -- get hello block 16384
    -- (HostSessKeys, RCHelloBody, RCHostPairing) <- prepareHostSession :: C.KeyHash -> RCHostPairing -> RCHostPrivateKeys -> RCEncryptedHello -> ExceptT RCErrorType IO (HostSessKeys, RCHelloBody, RCHostPairing)
    -- putTMVar r
    pure undefined
  pure (inv, client, r)
  where
    mkHostSession :: TransportHost -> Word16 -> IO (RCInvitation, RCHostPrivateKeys)
    mkHostSession host port = do
      ts <- getSystemTime
      (skey, sessPrivKey) <- C.generateKeyPair'
      (kem, kemPrivKey) <- sntrup761Keypair drg
      (dh, dhPrivKey) <- C.generateKeyPair'
      let inv =
            RCInvitation
              { ca = undefined, -- fingerprint caCert
                host,
                port,
                v = supportedRCVRange,
                app = appInfo,
                ts,
                skey,
                idkey = C.publicKey idPrivKey,
                kem,
                dh
              }
          keys = RCHostPrivateKeys {sessPrivKey, kemPrivKey, dhPrivKey}
      pure (inv, keys)

cancelHostClient :: RCHostClient -> IO ()
cancelHostClient = undefined

prepareHostSession :: C.KeyHash -> RCHostPairing -> RCHostPrivateKeys -> RCEncryptedHello -> ExceptT RCErrorType IO (HostSessKeys, RCHelloBody, RCHostPairing)
prepareHostSession
  tlsHostFingerprint
  pairing@RCHostPairing {idPrivKey, knownHost = knownHost_}
  RCHostPrivateKeys {sessPrivKey, kemPrivKey, dhPrivKey}
  RCEncryptedHello {dhPubKey, kemCiphertext, nonce, encryptedBody} = do
    kemSharedKey <- liftIO $ sntrup761Dec kemCiphertext kemPrivKey
    let key = kemHybridSecret (C.dh' dhPubKey dhPrivKey) kemSharedKey
    hello@RCHelloBody {ca} <- liftEitherWith rcError $ parseAll rcHelloP =<< kcbDecrypt key nonce encryptedBody
    -- TODO: validate that version in range
    let keys = HostSessKeys {key, idPrivKey, sessPrivKey}
        storedSessKeys = StoredHostSessionKeys {hostDHPublicKey = dhPubKey, kemSharedKey}
    knownHost' <- updateKnownHost ca storedSessKeys
    pure (keys, hello, pairing {knownHost = Just knownHost'})
    where
      updateKnownHost :: C.KeyHash -> StoredHostSessionKeys -> ExceptT RCErrorType IO KnownHostPairing
      updateKnownHost ca storedSessKeys = case knownHost_ of
        Just h -> do
          unless (h.hostFingerprint == tlsHostFingerprint) $
            throwError $
              RCEInternal "TLS host CA is different from host pairing, should be caught in TLS handshake"
          unless (ca == tlsHostFingerprint) $ throwError RCEBadHelloFingerprint
          pure (h :: KnownHostPairing) {storedSessKeys}
        Nothing -> pure KnownHostPairing {hostFingerprint = ca, storedSessKeys}

data RCCtrlClient = RCCtrlClient
  { async :: Async ()
  }

-- app should determine whether it is a new or known pairing based on CA fingerprint in the invitation
connectNewRCCtrl :: TVar ChaChaDRG -> RCInvitation -> ExceptT RCErrorType IO (RCCtrlClient, TMVar (RCCtrlSession, RCCtrlPairing))
connectNewRCCtrl drg inv@RCInvitation {ca, idkey, kem} = do
  (ct, pairing) <- newCtrlPairing
  connectRCCtrl_ pairing inv ct
  where
    newCtrlPairing :: ExceptT RCErrorType IO (KEMCiphertext, RCCtrlPairing)
    newCtrlPairing = do
      ((_, caKey), caCert) <- liftIO $ genCredentials Nothing (-25, 24 * 999999) "ca"
      (_, dhPrivateKey) <- liftIO C.generateKeyPair'
      (ct, kemSharedKey) <- liftIO $ sntrup761Enc drg kem
      let pairing =
            RCCtrlPairing
              { caKey,
                caCert,
                ctrlFingerprint = ca,
                idPubKey = idkey,
                storedSessKeys = StoredCtrlSessionKeys {dhPrivateKey, kemSharedKey},
                prevStoredSessKeys = Nothing
              }
      pure (ct, pairing)

connectKnownRCCtrl :: RCCtrlPairing -> RCInvitation -> ExceptT RCErrorType IO (RCCtrlClient, TMVar (RCCtrlSession, RCCtrlPairing))
connectKnownRCCtrl RCCtrlPairing {ctrlFingerprint, idPubKey} inv@RCInvitation {ca} = do
  (ct, pairing) <- updateCtrlPairing
  connectRCCtrl_ pairing inv ct
  where
    updateCtrlPairing :: ExceptT RCErrorType IO (KEMCiphertext, RCCtrlPairing)
    updateCtrlPairing
      | ca == ctrlFingerprint && idPubKey == idkey = undefined -- ok
      | otherwise = undefined -- error

connectRCCtrl_ :: RCCtrlPairing -> RCInvitation -> KEMCiphertext -> ExceptT RCErrorType IO (RCCtrlClient, TMVar (RCCtrlSession, RCCtrlPairing))
connectRCCtrl_ pairing inv ct = do
  r <- newEmptyTMVarIO
  client <- do
    -- start client connection to TLS
    -- (CtrlSessKeys, RCEncryptedHello, RCCtrlPairing) <- prepareCtrlSession :: RCCtrlPairing -> RCInvitation -> IO (CtrlSessKeys, RCEncryptedHello, RCCtrlPairing)
    -- putTMVar r
    pure undefined
  pure (client, r)

-- cryptography
prepareCtrlSession :: TVar ChaChaDRG -> RCInvitation -> J.Value -> KEMCiphertext -> IO (CtrlSessKeys, RCEncryptedHello, RCCtrlPairing)
prepareCtrlSession
  drg
  RCCtrlPairing {caKey, caCert, ctrlFingerprint, idPubKey, storedSessKeys = StoredCtrlSessionKeys {dhPrivateKey, kemSharedKey}}
  RCInvitation {
    ca, -- :: C.KeyHash,
    skey, -- :: C.PublicKeyEd25519,
    idkey, -- :: C.PublicKeyEd25519,
    kem, -- :: KEMPublicKey,
    dh
   }
   hostAppInfo
   kemCiphertext = do
    let v = compatibleVersion
    let key = kemHybridSecret (C.dh' dhPrivateKey dh) kemSharedKey
    -- session, fingerprint
    -- import Data.X509.Validation (Fingerprint (..), getFingerprint)
    let Fingerprint rootFP = getFingerprint root X509.HashSHA256
    let hello = RCHelloBody {v, ca = ?, app = hostAppInfo}
    nonce <- C.pseudoRandomCbNonce drg
    encryptedBody <- kcbEncrypt key nonce (smpEncode hello)
    let sessKeys =
          CtrlSessKeys
            { key,
              idPubKey,
              sessPubKey = skey
            }
        hello =
          RCEncryptedHello
            { dhPubKey = C.publicKey dhPrivateKey,
              kemCiphertext,
              nonce :: C.CbNonce, -- TODO make random
              encryptedBody :: ByteString
            }
        pairing' =
          RCCtrlPairing
            { caKey :: C.APrivateSignKey,
              caCert :: C.SignedCertificate,
              ctrlFingerprint :: C.KeyHash, -- long-term identity of connected remote controller
              idPubKey :: C.PublicKeyEd25519,
              storedSessKeys :: StoredCtrlSessionKeys,
              prevStoredSessKeys :: Maybe StoredCtrlSessionKeys
            }
    pure (sessKeys, hello, pairing')

-- The application should save updated RCHostPairing after user confirmation of the session
-- TMVar resolves when TLS is connected
connectKnownRCCtrlMulticast :: NonEmpty RCCtrlPairing -> ExceptT RCErrorType IO (RCCtrlClient, TMVar (RCCtrlSession, RCCtrlPairing))
connectKnownRCCtrlMulticast = do
  undefined

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
    storedSessKeys :: StoredHostSessionKeys
  }

data StoredHostSessionKeys = StoredHostSessionKeys
  { hostDHPublicKey :: C.PublicKeyX25519, -- sent by host in HELLO block. Matches one of the DH keys in RCCtrlPairing
    kemSharedKey :: KEMSharedKey
  }

-- | Long-term part of host (mobile) connection to controller (desktop)
data RCCtrlPairing = RCCtrlPairing
  { caKey :: C.APrivateSignKey,
    caCert :: C.SignedCertificate,
    ctrlFingerprint :: C.KeyHash, -- long-term identity of connected remote controller
    idPubKey :: C.PublicKeyEd25519,
    storedSessKeys :: StoredCtrlSessionKeys,
    prevStoredSessKeys :: Maybe StoredCtrlSessionKeys
  }

data StoredCtrlSessionKeys = StoredCtrlSessionKeys
  { dhPrivateKey :: C.PrivateKeyX25519,
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
  { key :: KEMHybridSecret,
    idPubKey :: C.PublicKeyEd25519,
    sessPubKey :: C.PublicKeyEd25519
  }

data RCEncryptedHello = RCEncryptedHello
  { dhPubKey :: C.PublicKeyX25519,
    kemCiphertext :: KEMCiphertext,
    nonce :: C.CbNonce,
    encryptedBody :: ByteString
  }

data RCHelloBody = RCHelloBody
  { v :: Version,
    ca :: C.KeyHash,
    app :: J.Value
  }
