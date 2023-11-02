{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.RemoteControl.Client where

import Control.Monad.Except (ExceptT)
import Data.List.NonEmpty (NonEmpty)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.SNTRUP761.Bindings
import Simplex.RemoteControl.Invitation (XRCPInvitation (..))
import Crypto.Random (ChaChaDRG)
import UnliftIO (TVar)
import Simplex.Messaging.Transport (TLS)
import Simplex.Messaging.Crypto.SNTRUP761 (KEMHybridSecret)
import UnliftIO.STM (TMVar)
import Data.ByteString (ByteString)
import Simplex.Messaging.Version (Version)
import Data.Text (Text)
import UnliftIO (newEmptyTMVarIO)

data XRCPError

newXRCPHostPairing :: ExceptT XRCPError IO XRCPHostPairing
newXRCPHostPairing = do
  caKey <- pure undefined
  caCert <- pure undefined
  idSigKey <- pure undefined
  pure XRCPHostPairing {caKey, caCert, idSigKey, knownHost = Nothing}

data XRCPHostClient = XRCPHostClient
  { async :: Async ()
  }

connectXRCPHost :: XRCPHostPairing -> ExceptT XRCPError IO (XRCPInvitation, XRCPHostClient, TMVar (XRCPHostSession, XRCPHostPairing))
connectXRCPHost host@XRCPHostPairing {caKey, caCert, idSigKey, knownHost} = do
  -- start TLS connection
  inv <- mkInvitation host
  r <- newEmptyTMVarIO
  -- wait for TLS connection, possibly start multicast if knownHost is not Nothing
  client <- pure undefined
  pure (inv, client, r)

mkInvitation :: XRCPHostPairing -> ExceptT XRCPError IO XRCPInvitation
mkInvitation = undefined

cancelClient :: XRCPHostClient -> IO ()
cancelClient = undefined

newXRCPCtrlPairing :: XRCPInvitation -> ExceptT XRCPError IO XRCPCtrlPairing
newXRCPCtrlPairing inv@XRCPInvitation {ca} = do
  caKey <- pure undefined
  caCert <- pure undefined
  idSigKey <- pure undefined
  prevCtrlKeys <- mkPrevCtrlKeys inv
  pure XRCPCtrlPairing
    { caKey,
      caCert,
      ctrlCAFingerprint = ca,
      prevCtrlKeys
    }

type ConfirmSession = Bool -> IO ()

-- The application should save updated XRCPHostPairing after user confirmation of the session
-- TMVar resolves when TLS is connected
connectXRCPCtrl :: NonEmpty XRCPCtrlPairing -> ExceptT XRCPError IO (TMVar (XRCPCtrlSession, XRCPCtrlPairing, ConfirmSession))
connectXRCPCtrl = undefined

-- | Long-term part of controller (desktop) connection to host (mobile)
data XRCPHostPairing = XRCPHostPairing
  { caKey :: C.APrivateSignKey,
    caCert :: C.SignedCertificate,
    idSigKey :: C.PrivateKeyEd25519,
    knownHost :: Maybe KnownHostPairing
  }

data KnownHostPairing = KnownHostPairing
  { hostCAFingerprint :: C.KeyHash, -- this is only changed in the first session, long-term identity of connected remote host
    prevHostKeys :: PrevHostSessionKeys
  }

data PrevHostSessionKeys = PrevHostSessionKeys
  { hostDHPublicKey :: C.PublicKeyX25519, -- sent by host in HELLO block. Matches one of the DH keys in XRCPCtrlPairing
    kemSharedKey :: KEMSharedKey
  }

-- | Long-term part of host (mobile) connection to controller (desktop)
data XRCPCtrlPairing = XRCPCtrlPairing
  { caKey :: C.APrivateSignKey,
    caCert :: C.SignedCertificate,
    ctrlCAFingerprint :: C.KeyHash, -- long-term identity of connected remote controller
    prevCtrlKeys :: PrevCtrlSessionKeys
  }

data PrevCtrlSessionKeys = PrevCtrlSessionKeys
  { dhPrivateKey :: C.PrivateKeyX25519,
    prevDHPrivateKey :: Maybe C.PrivateKeyX25519,
    kemSharedKey :: KEMSharedKey
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
    sessionKeys :: CtrlSessionKeys
  }

data CtrlSessionKeys = CtrlSessionKeys
  { key :: KEMHybridSecret,
    idPrivKey :: C.PublicKeyEd25519,
    sessPrivKey :: C.PublicKeyEd25519
  }

-- cryptography
prepareCtrlSession :: TVar ChaChaDRG -> XRCPCtrlPairing -> XRCPInvitation -> IO (CtrlSessionKeys, XRCPCtrlPairing)
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


-- ```abnf
-- helloBlock = unpaddedSize %s"HELLO " dhPubKey kemCiphertext length encrypted(length helloBlockJSON) pad
-- unpaddedSize = 2*2 OCTET
-- pad = <pad block size to 16384 bytes>
-- kemCiphertext = length base64url
-- ```

-- Controller decrypts (including the first session) and validates the received hello block:
-- - Chosen versions are supported (must be within offered ranges).
-- - CA fingerprint matches the one presented in TLS handshake and the previous sessions - in subsequent sessions TLS connection should be rejected if the fingerprint is different.

-- JTD schema for the encrypted part of hello block:

-- ```json
-- {
--   "definitions": {
--     "version": {
--       "type": "string",
--       "metadata": {
--         "format": "[0-9]+"
--       }
--     },
--     "base64url": {
--       "type": "string",
--       "metadata": {
--         "format": "base64url"
--       }
--     }
--   },
--   "properties": {
--     "v": {"ref": "version"},
--     "ca": {"ref": "base64url"},
--   },
--   "optionalProperties": {
--     "device": {"type": "string"},
--     "appVersion": {"ref": "version"}
--   },
--   "additionalProperties": true
-- }
-- ```