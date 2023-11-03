{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.RemoteControl.Client where

import Control.Concurrent.Async (Async)
import Control.Monad.Except (ExceptT)
import Control.Monad.IO.Class
import Crypto.Random (ChaChaDRG)
import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Time.Clock.System (getSystemTime)
import Data.Word (Word16)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.SNTRUP761 (KEMHybridSecret)
import Simplex.Messaging.Crypto.SNTRUP761.Bindings
import Simplex.Messaging.Transport (TLS)
import Simplex.Messaging.Transport.Client (TransportHost)
import Simplex.Messaging.Version (Version, VersionRange, mkVersionRange)
import Simplex.RemoteControl.Invitation (XRCPInvitation (..))
import UnliftIO (TVar, newEmptyTMVarIO)
import UnliftIO.STM (TMVar)

currentXRCPVersion :: Version
currentXRCPVersion = 1

supportedXRCPVRange :: VersionRange
supportedXRCPVRange = mkVersionRange 1 currentXRCPVersion

data XRCPAppInfo = XRCPAppInfo
  { app :: Text,
    appv :: VersionRange,
    device :: Text
  }

data XRCPError

newXRCPHostPairing :: ExceptT XRCPError IO XRCPHostPairing
newXRCPHostPairing = do
  caKey <- pure undefined
  caCert <- pure undefined
  idPrivKey <- pure undefined
  pure XRCPHostPairing {caKey, caCert, idPrivKey, knownHost = Nothing}

data XRCPHostClient = XRCPHostClient
  { async :: Async ()
  }

connectXRCPHost :: TVar ChaChaDRG -> XRCPHostPairing -> XRCPAppInfo -> ExceptT XRCPError IO (XRCPInvitation, XRCPHostClient, TMVar (XRCPHostSession, XRCPHostPairing))
connectXRCPHost drg XRCPHostPairing {caKey, caCert, idPrivKey, knownHost} appInfo = do
  -- start TLS connection
  (host, port) <- pure undefined
  (inv, keys) <- liftIO $ mkHostSession host port
  r <- newEmptyTMVarIO
  -- wait for TLS connection, possibly start multicast if knownHost is not Nothing
  client <- pure undefined
  pure (inv, client, r)
  where
    mkHostSession :: TransportHost -> Word16 -> IO (XRCPInvitation, XRCPHostPrivateKeys)
    mkHostSession host port = do
      let XRCPAppInfo {app, appv, device} = appInfo
      ts <- getSystemTime
      (skey, sessPrivKey) <- C.generateKeyPair'
      (kem, kemPrivKey) <- sntrup761Keypair drg
      (dh, dhPrivKey) <- C.generateKeyPair'
      let inv =
            XRCPInvitation
              { ca = undefined, -- fingerprint caCert
                host,
                port,
                v = supportedXRCPVRange,
                app,
                appv,
                device,
                ts,
                skey,
                idkey = C.publicKey idPrivKey,
                kem,
                dh
              }
          keys = XRCPHostPrivateKeys {sessPrivKey, kemPrivKey, dhPrivKey}
      pure (inv, keys)

cancelHostClient :: XRCPHostClient -> IO ()
cancelHostClient = undefined

data XRCPCtrlClient = XRCPCtrlClient
  { async :: Async ()
  }

-- app should determine whether it is a new or known pairing based on CA fingerprint in the invitation
connectXRCPCtrl :: XRCPInvitation -> Maybe XRCPCtrlPairing -> ExceptT XRCPError IO (XRCPCtrlClient, TMVar (XRCPCtrlSession, XRCPCtrlPairing))
connectXRCPCtrl inv pairing_ = do
  (ct, sess, pairing) <- mkCtrlPairing inv pairing_
  -- start client connection to TLS
  r <- newEmptyTMVarIO
  client <- pure undefined
  pure (client, r)

mkCtrlPairing :: XRCPInvitation -> Maybe XRCPCtrlPairing -> ExceptT XRCPError IO (KEMCiphertext, XRCPCtrlSession, XRCPCtrlPairing)
mkCtrlPairing inv@XRCPInvitation {ca, idkey} pairing_ = do
  (ct, pairing) <- maybe newCtrlPairing updateCtrlPairing pairing_
  session <- pure undefined
  pure (ct, session, pairing)
  where
    newCtrlPairing :: ExceptT XRCPError IO (KEMCiphertext, XRCPCtrlPairing)
    newCtrlPairing = do
      caKey <- pure undefined
      caCert <- pure undefined
      let pairing =
            XRCPCtrlPairing
              { caKey,
                caCert,
                ctrlFingerprint = ca,
                idPubKey = idkey,
                storedSessKeys = undefined
              }
          ct = undefined
      pure (ct, pairing)
    updateCtrlPairing :: XRCPCtrlPairing -> ExceptT XRCPError IO (KEMCiphertext, XRCPCtrlPairing)
    updateCtrlPairing XRCPCtrlPairing {ctrlFingerprint, idPubKey}
      | ca == ctrlFingerprint && idPubKey == idkey = undefined -- ok
      | otherwise = undefined -- error

-- The application should save updated XRCPHostPairing after user confirmation of the session
-- TMVar resolves when TLS is connected
connectKnownXRCPCtrl :: NonEmpty XRCPCtrlPairing -> ExceptT XRCPError IO (XRCPCtrlClient, TMVar (XRCPCtrlSession, XRCPCtrlPairing))
connectKnownXRCPCtrl = undefined

confirmCtrlSession :: XRCPCtrlClient -> Bool -> IO ()
confirmCtrlSession = undefined

-- | Long-term part of controller (desktop) connection to host (mobile)
data XRCPHostPairing = XRCPHostPairing
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
  { hostDHPublicKey :: C.PublicKeyX25519, -- sent by host in HELLO block. Matches one of the DH keys in XRCPCtrlPairing
    kemSharedKey :: KEMSharedKey
  }

-- | Long-term part of host (mobile) connection to controller (desktop)
data XRCPCtrlPairing = XRCPCtrlPairing
  { caKey :: C.APrivateSignKey,
    caCert :: C.SignedCertificate,
    ctrlFingerprint :: C.KeyHash, -- long-term identity of connected remote controller
    idPubKey :: C.PublicKeyEd25519,
    storedSessKeys :: StoredCtrlSessionKeys
  }

data StoredCtrlSessionKeys = StoredCtrlSessionKeys
  { dhPrivateKey :: C.PrivateKeyX25519,
    prevDHPrivateKey :: Maybe C.PrivateKeyX25519,
    kemSharedKey :: KEMSharedKey
  }

data XRCPHostPrivateKeys = XRCPHostPrivateKeys
  { sessPrivKey :: C.PrivateKeyEd25519,
    kemPrivKey :: KEMSecretKey,
    dhPrivKey :: C.PrivateKeyX25519
  }

-- Connected session with Host
data XRCPHostSession = XRCPHostSession
  { tls :: TLS,
    sessionKeys :: HostSessionKeys
  }

data HostSessionKeys = HostSessionKeys
  { key :: KEMHybridSecret,
    idPrivKey :: C.PrivateKeyEd25519,
    sessPrivKey :: C.PrivateKeyEd25519
  }

-- cryptography
prepareHostSession :: TVar ChaChaDRG -> XRCPHostPairing -> XRCPEncryptedHello -> IO (HostSessionKeys, XRCPHelloBody, XRCPHostPairing)
prepareHostSession = undefined

-- Host: XRCPCtrlPairing + XRCPInvitation => (XRCPCtrlSession, XRCPCtrlPairing)

data XRCPCtrlSession = XRCPCtrlSession
  { tls :: TLS,
    sessionKeys :: CtrlSessKeys
  }

data CtrlSessKeys = CtrlSessKeys
  { key :: KEMHybridSecret,
    idPrivKey :: C.PublicKeyEd25519,
    sessPrivKey :: C.PublicKeyEd25519
  }

-- cryptography
prepareCtrlSession :: TVar ChaChaDRG -> XRCPCtrlPairing -> XRCPInvitation -> IO (CtrlSessKeys, XRCPCtrlPairing)
prepareCtrlSession = undefined

data XRCPEncryptedHello = XRCPEncryptedHello
  { dhPubKey :: C.PublicKeyX25519,
    kemCiphertext :: KEMCiphertext,
    encryptedBody :: ByteString
  }

data XRCPHelloBody = XRCPHelloBody
  { v :: Version,
    ca :: C.KeyHash,
    device :: Text,
    appVersion :: Version
  }
