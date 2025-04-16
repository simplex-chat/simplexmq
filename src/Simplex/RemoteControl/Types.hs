{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.RemoteControl.Types where

import qualified Data.Aeson as J
import qualified Data.Aeson.TH as JQ
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Word (Word16)
import qualified Data.X509 as X
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.SNTRUP761.Bindings
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (defaultJSON, dropPrefix, sumTypeJSON)
import Simplex.Messaging.Transport (TLS, TSbChainKeys)
import Simplex.Messaging.Transport.Client (TransportHost)
import Simplex.Messaging.Util (safeDecodeUtf8)
import Simplex.Messaging.Version (VersionRange, VersionScope, mkVersionRange)
import Simplex.Messaging.Version.Internal
import UnliftIO

data RCErrorType
  = RCEInternal {internalErr :: String}
  | RCEIdentity
  | RCENoLocalAddress
  | RCENewController
  | RCENotDiscovered
  | RCETLSStartFailed
  | RCEException {exception :: String}
  | RCECtrlAuth
  | RCECtrlNotFound
  | RCECtrlError {ctrlErr :: String}
  | RCEInvitation
  | RCEVersion
  | RCEEncrypt
  | RCEDecrypt
  | RCEBlockSize
  | RCESyntax {syntaxErr :: String}
  deriving (Eq, Show, Exception)

instance StrEncoding RCErrorType where
  strEncode = \case
    RCEInternal err -> "INTERNAL" <> text err
    RCEIdentity -> "IDENTITY"
    RCENoLocalAddress -> "NO_LOCAL_ADDR"
    RCENewController -> "NEW_CONTROLLER"
    RCENotDiscovered -> "NOT_DISCOVERED"
    RCETLSStartFailed -> "CTRL_TLS_START"
    RCEException err -> "EXCEPTION" <> text err
    RCECtrlAuth -> "CTRL_AUTH"
    RCECtrlNotFound -> "CTRL_NOT_FOUND"
    RCECtrlError err -> "CTRL_ERROR" <> text err
    RCEInvitation -> "INVITATION"
    RCEVersion -> "VERSION"
    RCEEncrypt -> "ENCRYPT"
    RCEDecrypt -> "DECRYPT"
    RCEBlockSize -> "BLOCK_SIZE"
    RCESyntax err -> "SYNTAX" <> text err
    where
      text = (" " <>) . encodeUtf8 . T.pack
  strP =
    A.takeTill (== ' ') >>= \case
      "INTERNAL" -> RCEInternal <$> textP
      "IDENTITY" -> pure RCEIdentity
      "NO_LOCAL_ADDR" -> pure RCENoLocalAddress
      "NEW_CONTROLLER" -> pure RCENewController
      "NOT_DISCOVERED" -> pure RCENotDiscovered
      "CTRL_TLS_START" -> pure RCETLSStartFailed
      "EXCEPTION" -> RCEException <$> textP
      "CTRL_AUTH" -> pure RCECtrlAuth
      "CTRL_NOT_FOUND" -> pure RCECtrlNotFound
      "CTRL_ERROR" -> RCECtrlError <$> textP
      "INVITATION" -> pure RCEInvitation
      "VERSION" -> pure RCEVersion
      "ENCRYPT" -> pure RCEEncrypt
      "DECRYPT" -> pure RCEDecrypt
      "BLOCK_SIZE" -> pure RCEBlockSize
      "SYNTAX" -> RCESyntax <$> textP
      _ -> fail "bad RCErrorType"
    where
      textP = T.unpack . safeDecodeUtf8 <$> (A.space *> A.takeByteString)

-- * Discovery

data RCPVersion

instance VersionScope RCPVersion

type VersionRCP = Version RCPVersion

type VersionRangeRCP = VersionRange RCPVersion

pattern VersionRCP :: Word16 -> VersionRCP
pattern VersionRCP v = Version v

currentRCPVersion :: VersionRCP
currentRCPVersion = VersionRCP 1

supportedRCPVRange :: VersionRangeRCP
supportedRCPVRange = mkVersionRange (VersionRCP 1) currentRCPVersion

data IpProbe = IpProbe
  { versionRange :: VersionRangeRCP,
    randomNonce :: ByteString
  }
  deriving (Show)

instance Encoding IpProbe where
  smpEncode IpProbe {versionRange, randomNonce} = smpEncode (versionRange, 'I', randomNonce)
  smpP = IpProbe <$> (smpP <* "I") *> smpP

-- * Session

data RCHostHello = RCHostHello
  { v :: VersionRCP,
    ca :: C.KeyHash,
    app :: J.Value,
    kem :: KEMPublicKey
  }
  deriving (Show)

$(JQ.deriveJSON defaultJSON ''RCHostHello)

data RCCtrlHello = RCCtrlHello {}
  deriving (Show)

$(JQ.deriveJSON defaultJSON {J.nullaryToObject = True} ''RCCtrlHello)

-- | Long-term part of controller (desktop) connection to host (mobile)
data RCHostPairing = RCHostPairing
  { caKey :: C.APrivateSignKey,
    caCert :: X.SignedCertificate,
    idPrivKey :: C.PrivateKeyEd25519,
    knownHost :: Maybe KnownHostPairing
  }

data KnownHostPairing = KnownHostPairing
  { hostFingerprint :: C.KeyHash, -- this is only changed in the first session, long-term identity of connected remote host
    hostDhPubKey :: C.PublicKeyX25519
  }

data RCCtrlAddress = RCCtrlAddress
  { address :: TransportHost, -- allows any interface when found exactly
    interface :: Text
  }
  deriving (Show, Eq)

-- | Long-term part of host (mobile) connection to controller (desktop)
data RCCtrlPairing = RCCtrlPairing
  { caKey :: C.APrivateSignKey,
    caCert :: X.SignedCertificate,
    ctrlFingerprint :: C.KeyHash, -- long-term identity of connected remote controller
    idPubKey :: C.PublicKeyEd25519,
    dhPrivKey :: C.PrivateKeyX25519,
    prevDhPrivKey :: Maybe C.PrivateKeyX25519
  }

data RCHostKeys = RCHostKeys
  { sessKeys :: C.KeyPair 'C.Ed25519,
    dhKeys :: C.KeyPair 'C.X25519
  }

-- Connected session with Host
data RCHostSession = RCHostSession
  { tls :: TLS,
    sessionKeys :: HostSessKeys
  }

data HostSessKeys = HostSessKeys
  { chainKeys :: TSbChainKeys,
    idPrivKey :: C.PrivateKeyEd25519,
    sessPrivKey :: C.PrivateKeyEd25519
  }

-- Host: RCCtrlPairing + RCInvitation => (RCCtrlSession, RCCtrlPairing)

data RCCtrlSession = RCCtrlSession
  { tls :: TLS,
    sessionKeys :: CtrlSessKeys
  }

data CtrlSessKeys = CtrlSessKeys
  { chainKeys :: TSbChainKeys,
    idPubKey :: C.PublicKeyEd25519,
    sessPubKey :: C.PublicKeyEd25519
  }

data RCHostEncHello = RCHostEncHello
  { dhPubKey :: C.PublicKeyX25519,
    nonce :: C.CbNonce,
    encBody :: ByteString
  }
  deriving (Show)

instance Encoding RCHostEncHello where
  smpEncode RCHostEncHello {dhPubKey, nonce, encBody} =
    "HELLO " <> smpEncode (dhPubKey, nonce, Tail encBody)
  smpP = do
    (dhPubKey, nonce, Tail encBody) <- "HELLO " *> smpP
    pure RCHostEncHello {dhPubKey, nonce, encBody}

data RCCtrlEncHello
  = RCCtrlEncHello {kem :: KEMCiphertext, encBody :: ByteString}
  | RCCtrlEncError {nonce :: C.CbNonce, encMessage :: ByteString}
  deriving (Show)

instance Encoding RCCtrlEncHello where
  smpEncode = \case
    RCCtrlEncHello {kem, encBody} -> "HELLO " <> smpEncode (kem, Tail encBody)
    RCCtrlEncError {nonce, encMessage} -> "ERROR " <> smpEncode (nonce, Tail encMessage)
  smpP =
    A.takeTill (== ' ') >>= \case
      "HELLO" -> do
        (kem, Tail encBody) <- _smpP
        pure RCCtrlEncHello {kem, encBody}
      "ERROR" -> do
        (nonce, Tail encMessage) <- _smpP
        pure RCCtrlEncError {nonce, encMessage}
      _ -> fail "bad RCCtrlEncHello"

-- * Utils

-- | tlsunique channel binding
type SessionCode = ByteString

type RCStepTMVar a = TMVar (Either RCErrorType a)

$(JQ.deriveJSON (sumTypeJSON $ dropPrefix "RCE") ''RCErrorType)

$(JQ.deriveJSON defaultJSON ''RCCtrlAddress)
