{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : Simplex.Messaging.Transport
-- Copyright   : (c) simplex.chat
-- License     : AGPL-3
--
-- Maintainer  : chat@simplex.chat
-- Stability   : experimental
-- Portability : non-portable
--
-- This module defines basic TCP server and client and SMP protocol encrypted transport over TCP.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#appendix-a
module Simplex.Messaging.Transport
  ( -- * SMP transport parameters
    SMPVersion,
    VersionSMP,
    VersionRangeSMP,
    THandleSMP,
    supportedSMPHandshakes,
    supportedClientSMPRelayVRange,
    supportedServerSMPRelayVRange,
    supportedProxyClientSMPRelayVRange,
    proxiedSMPRelayVRange,
    minClientSMPRelayVersion,
    minServerSMPRelayVersion,
    legacyServerSMPRelayVRange,
    currentClientSMPRelayVersion,
    legacyServerSMPRelayVersion,
    currentServerSMPRelayVersion,
    authCmdsSMPVersion,
    sendingProxySMPVersion,
    sndAuthKeySMPVersion,
    deletedEventSMPVersion,
    encryptedBlockSMPVersion,
    blockedEntitySMPVersion,
    shortLinksSMPVersion,
    simplexMQVersion,
    smpBlockSize,
    TransportConfig (..),

    -- * Transport connection class
    Transport (..),
    TProxy (..),
    ATransport (..),
    TransportPeer (..),
    getServerVerifyKey,

    -- * TLS Transport
    TLS (..),
    SessionId,
    ALPN,
    connectTLS,
    closeTLS,
    defaultSupportedParams,
    defaultSupportedParamsHTTPS,
    withTlsUnique,

    -- * SMP transport
    THandle (..),
    THandleParams (..),
    THandleAuth (..),
    TSbChainKeys (..),
    TransportError (..),
    HandshakeError (..),
    smpServerHandshake,
    smpClientHandshake,
    tPutBlock,
    tGetBlock,
    sendHandshake,
    getHandshake,
    smpTHParamsSetVersion,
  )
where

import Control.Applicative (optional)
import Control.Concurrent.STM
import Control.Monad (forM, when, (<$!>))
import Control.Monad.Except
import Control.Monad.IO.Class
import Control.Monad.Trans.Except (throwE)
import qualified Data.Aeson.TH as J
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (bimap, first)
import Data.Bitraversable (bimapM)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Default (def)
import Data.Functor (($>))
import Data.Tuple (swap)
import Data.Typeable (Typeable)
import Data.Version (showVersion)
import Data.Word (Word16)
import qualified Data.X509 as X
import qualified Data.X509.Validation as XV
import GHC.IO.Handle.Internals (ioe_EOF)
import Network.Socket
import qualified Network.TLS as T
import qualified Network.TLS.Extra as TE
import qualified Paths_simplexmq as SMQ
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Parsers (dropPrefix, parseRead1, sumTypeJSON)
import Simplex.Messaging.Transport.Buffer
import Simplex.Messaging.Util (bshow, catchAll, catchAll_, liftEitherWith)
import Simplex.Messaging.Version
import Simplex.Messaging.Version.Internal
import System.IO.Error (isEOFError)
import UnliftIO.Exception (Exception)
import qualified UnliftIO.Exception as E

-- * Transport parameters

smpBlockSize :: Int
smpBlockSize = 16384

-- SMP protocol version history:
-- 1 - binary protocol encoding (1/1/2022)
-- 2 - message flags (used to control notifications, 6/6/2022)
-- 3 - encrypt message timestamp and flags together with the body when delivered to the recipient (7/5/2022)
-- 4 - support command batching (7/17/2022)
-- 5 - basic auth for SMP servers (11/12/2022)
-- 6 - allow creating queues without subscribing (9/10/2023)
-- 7 - support authenticated encryption to verify senders' commands, imply but do NOT send session ID in signed part (4/30/2024)
-- 8 - SMP proxy for sender commands (6/03/2024)
-- 9 - faster handshake: SKEY command for sender to secure queue (6/30/2024)
-- 10 - DELD event to subscriber when queue is deleted via another connnection (9/11/2024)
-- 11 - additional encryption of transport blocks with forward secrecy (10/06/2024)
-- 12 - BLOCKED error for blocked queues (1/11/2025)
-- 14 - proxyServer handshake property to disable transport encryption between server and proxy (1/19/2025)
-- 15 - short links, with associated data passed in NEW of LSET command (3/30/2025)

data SMPVersion

instance VersionScope SMPVersion

type VersionSMP = Version SMPVersion

type VersionRangeSMP = VersionRange SMPVersion

pattern VersionSMP :: Word16 -> VersionSMP
pattern VersionSMP v = Version v

_subModeSMPVersion :: VersionSMP
_subModeSMPVersion = VersionSMP 6

authCmdsSMPVersion :: VersionSMP
authCmdsSMPVersion = VersionSMP 7

sendingProxySMPVersion :: VersionSMP
sendingProxySMPVersion = VersionSMP 8

sndAuthKeySMPVersion :: VersionSMP
sndAuthKeySMPVersion = VersionSMP 9

deletedEventSMPVersion :: VersionSMP
deletedEventSMPVersion = VersionSMP 10

encryptedBlockSMPVersion :: VersionSMP
encryptedBlockSMPVersion = VersionSMP 11

blockedEntitySMPVersion :: VersionSMP
blockedEntitySMPVersion = VersionSMP 12

proxyServerHandshakeSMPVersion :: VersionSMP
proxyServerHandshakeSMPVersion = VersionSMP 14

shortLinksSMPVersion :: VersionSMP
shortLinksSMPVersion = VersionSMP 15

minClientSMPRelayVersion :: VersionSMP
minClientSMPRelayVersion = VersionSMP 6

minServerSMPRelayVersion :: VersionSMP
minServerSMPRelayVersion = VersionSMP 6

currentClientSMPRelayVersion :: VersionSMP
currentClientSMPRelayVersion = VersionSMP 15

legacyServerSMPRelayVersion :: VersionSMP
legacyServerSMPRelayVersion = VersionSMP 6

currentServerSMPRelayVersion :: VersionSMP
currentServerSMPRelayVersion = VersionSMP 15

-- Max SMP protocol version to be used in e2e encrypted
-- connection between client and server, as defined by SMP proxy.
-- SMP proxy sets it to lower than its current version
-- to prevent client version fingerprinting by the
-- destination relays when clients upgrade at different times.
proxiedSMPRelayVersion :: VersionSMP
proxiedSMPRelayVersion = VersionSMP 15

-- minimal supported protocol version is 6
-- TODO remove code that supports sending commands without batching
supportedClientSMPRelayVRange :: VersionRangeSMP
supportedClientSMPRelayVRange = mkVersionRange minClientSMPRelayVersion currentClientSMPRelayVersion

legacyServerSMPRelayVRange :: VersionRangeSMP
legacyServerSMPRelayVRange = mkVersionRange minServerSMPRelayVersion legacyServerSMPRelayVersion

supportedServerSMPRelayVRange :: VersionRangeSMP
supportedServerSMPRelayVRange = mkVersionRange minServerSMPRelayVersion currentServerSMPRelayVersion

supportedProxyClientSMPRelayVRange :: VersionRangeSMP
supportedProxyClientSMPRelayVRange = mkVersionRange minServerSMPRelayVersion currentServerSMPRelayVersion

proxiedSMPRelayVRange :: VersionRangeSMP
proxiedSMPRelayVRange = mkVersionRange sendingProxySMPVersion proxiedSMPRelayVersion

supportedSMPHandshakes :: [ALPN]
supportedSMPHandshakes = ["smp/1"]

simplexMQVersion :: String
simplexMQVersion = showVersion SMQ.version

-- * Transport connection class

data TransportConfig = TransportConfig
  { logTLSErrors :: Bool,
    transportTimeout :: Maybe Int
  }

class Typeable c => Transport c where
  transport :: ATransport
  transport = ATransport (TProxy @c)

  transportName :: TProxy c -> String

  transportPeer :: c -> TransportPeer

  transportConfig :: c -> TransportConfig

  -- | Upgrade server TLS context to connection (used in the server)
  getServerConnection :: TransportConfig -> X.CertificateChain -> T.Context -> IO c

  -- | Upgrade client TLS context to connection (used in the client)
  getClientConnection :: TransportConfig -> X.CertificateChain -> T.Context -> IO c

  getServerCerts :: c -> X.CertificateChain

  -- | tls-unique channel binding per RFC5929
  tlsUnique :: c -> SessionId

  -- | ALPN value negotiated for the session
  getSessionALPN :: c -> Maybe ALPN

  -- | Close connection
  closeConnection :: c -> IO ()

  -- | Read fixed number of bytes from connection
  cGet :: c -> Int -> IO ByteString

  -- | Write bytes to connection
  cPut :: c -> ByteString -> IO ()

  -- | Receive ByteString from connection, allowing LF or CRLF termination.
  getLn :: c -> IO ByteString

  -- | Send ByteString to connection terminating it with CRLF.
  putLn :: c -> ByteString -> IO ()
  putLn c = cPut c . (<> "\r\n")

data TransportPeer = TClient | TServer
  deriving (Eq, Show)

data TProxy c = TProxy

data ATransport = forall c. Transport c => ATransport (TProxy c)

getServerVerifyKey :: Transport c => c -> Either String C.APublicVerifyKey
getServerVerifyKey c =
  case getServerCerts c of
    X.CertificateChain (server : _ca) -> C.x509ToPublic (X.certPubKey . X.signedObject $ X.getSigned server, []) >>= C.pubKey
    _ -> Left "no certificate chain"

-- * TLS Transport

data TLS = TLS
  { tlsContext :: T.Context,
    tlsPeer :: TransportPeer,
    tlsUniq :: ByteString,
    tlsBuffer :: TBuffer,
    tlsALPN :: Maybe ALPN,
    tlsServerCerts :: X.CertificateChain,
    tlsTransportConfig :: TransportConfig
  }

type ALPN = ByteString

connectTLS :: T.TLSParams p => Maybe HostName -> TransportConfig -> p -> Socket -> IO T.Context
connectTLS host_ TransportConfig {logTLSErrors} params sock =
  E.bracketOnError (T.contextNew sock params) closeTLS $ \ctx ->
    logHandshakeErrors (T.handshake ctx) $> ctx
  where
    logHandshakeErrors = if logTLSErrors then (`catchAll` logThrow) else id
    logThrow e = putStrLn ("TLS error" <> host <> ": " <> show e) >> E.throwIO e
    host = maybe "" (\h -> " (" <> h <> ")") host_

getTLS :: TransportPeer -> TransportConfig -> X.CertificateChain -> T.Context -> IO TLS
getTLS tlsPeer cfg tlsServerCerts cxt = withTlsUnique tlsPeer cxt newTLS
  where
    newTLS tlsUniq = do
      tlsBuffer <- newTBuffer
      tlsALPN <- T.getNegotiatedProtocol cxt
      pure TLS {tlsContext = cxt, tlsALPN, tlsTransportConfig = cfg, tlsServerCerts, tlsPeer, tlsUniq, tlsBuffer}

withTlsUnique :: TransportPeer -> T.Context -> (ByteString -> IO c) -> IO c
withTlsUnique peer cxt f =
  cxtFinished peer cxt
    >>= maybe (closeTLS cxt >> ioe_EOF) f
  where
    cxtFinished TServer = T.getPeerFinished
    cxtFinished TClient = T.getFinished

closeTLS :: T.Context -> IO ()
closeTLS ctx =
  T.bye ctx -- sometimes socket was closed before 'TLS.bye' so we catch the 'Broken pipe' error here
    `E.finally` T.contextClose ctx
    `catchAll_` pure ()

defaultSupportedParams :: T.Supported
defaultSupportedParams =
  def
    { T.supportedVersions = [T.TLS13, T.TLS12],
      T.supportedCiphers =
        [ TE.cipher_TLS13_CHACHA20POLY1305_SHA256, -- for TLS13
          TE.cipher_ECDHE_ECDSA_CHACHA20POLY1305_SHA256 -- for TLS12
        ],
      T.supportedHashSignatures = [(T.HashIntrinsic, T.SignatureEd448), (T.HashIntrinsic, T.SignatureEd25519)],
      T.supportedGroups = [T.X448, T.X25519],
      T.supportedSecureRenegotiation = False
    }

-- | A selection of extra parameters to accomodate browser chains
defaultSupportedParamsHTTPS :: T.Supported
defaultSupportedParamsHTTPS =
  defaultSupportedParams
    { T.supportedCiphers = TE.ciphersuite_strong,
      T.supportedGroups = [T.X25519, T.X448, T.FFDHE4096, T.FFDHE6144, T.FFDHE8192, T.P521],
      T.supportedHashSignatures =
        [ (T.HashIntrinsic, T.SignatureEd448),
          (T.HashIntrinsic, T.SignatureEd25519),
          (T.HashSHA256, T.SignatureECDSA),
          (T.HashSHA384, T.SignatureECDSA),
          (T.HashSHA512, T.SignatureECDSA),
          (T.HashIntrinsic, T.SignatureRSApssRSAeSHA512),
          (T.HashIntrinsic, T.SignatureRSApssRSAeSHA384),
          (T.HashIntrinsic, T.SignatureRSApssRSAeSHA256),
          (T.HashSHA512, T.SignatureRSA),
          (T.HashSHA384, T.SignatureRSA),
          (T.HashSHA256, T.SignatureRSA)
        ]
    }

instance Transport TLS where
  transportName _ = "TLS"
  transportPeer = tlsPeer
  transportConfig = tlsTransportConfig
  getServerConnection = getTLS TServer
  getClientConnection = getTLS TClient
  getServerCerts = tlsServerCerts
  getSessionALPN = tlsALPN
  tlsUnique = tlsUniq
  closeConnection tls = closeTLS $ tlsContext tls

  -- https://hackage.haskell.org/package/tls-1.6.0/docs/Network-TLS.html#v:recvData
  -- this function may return less than requested number of bytes
  cGet :: TLS -> Int -> IO ByteString
  cGet TLS {tlsContext, tlsBuffer, tlsTransportConfig = TransportConfig {transportTimeout = t_}} n =
    getBuffered tlsBuffer n t_ (T.recvData tlsContext)

  cPut :: TLS -> ByteString -> IO ()
  cPut TLS {tlsContext, tlsTransportConfig = TransportConfig {transportTimeout = t_}} =
    withTimedErr t_ . T.sendData tlsContext . LB.fromStrict

  getLn :: TLS -> IO ByteString
  getLn TLS {tlsContext, tlsBuffer} = do
    getLnBuffered tlsBuffer (T.recvData tlsContext) `E.catches` [E.Handler handleTlsEOF, E.Handler handleEOF]
    where
      handleTlsEOF = \case
        T.PostHandshake T.Error_EOF -> E.throwIO TEBadBlock
        e -> E.throwIO e
      handleEOF e = if isEOFError e then E.throwIO TEBadBlock else E.throwIO e

-- * SMP transport

-- | The handle for SMP encrypted transport connection over Transport.
data THandle v c p = THandle
  { connection :: c,
    params :: THandleParams v p
  }

type THandleSMP c p = THandle SMPVersion c p

data THandleParams v p = THandleParams
  { sessionId :: SessionId,
    blockSize :: Int,
    -- | server protocol version range
    thServerVRange :: VersionRange v,
    -- | agreed server protocol version
    thVersion :: Version v,
    -- | peer public key for command authorization and shared secrets for entity ID encryption
    thAuth :: Maybe (THandleAuth p),
    -- | do NOT send session ID in transmission, but include it into signed message
    -- based on protocol version
    implySessId :: Bool,
    -- | keys for additional transport encryption
    encryptBlock :: Maybe TSbChainKeys,
    -- | send multiple transmissions in a single block
    -- based on protocol version
    batch :: Bool
  }

data THandleAuth (p :: TransportPeer) where
  THAuthClient ::
    { serverPeerPubKey :: C.PublicKeyX25519, -- used by the client to combine with client's private per-queue key
      serverCertKey :: (X.CertificateChain, X.SignedExact X.PubKey), -- the key here is serverPeerPubKey signed with server certificate
      sessSecret :: Maybe C.DhSecretX25519 -- session secret (will be used in SMP proxy only)
    } ->
    THandleAuth 'TClient
  THAuthServer ::
    { serverPrivKey :: C.PrivateKeyX25519, -- used by the server to combine with client's public per-queue key
      sessSecret' :: Maybe C.DhSecretX25519 -- session secret (will be used in SMP proxy only)
    } ->
    THandleAuth 'TServer

data TSbChainKeys = TSbChainKeys
  { sndKey :: TVar C.SbChainKey,
    rcvKey :: TVar C.SbChainKey
  }

-- | TLS-unique channel binding
type SessionId = ByteString

data ServerHandshake = ServerHandshake
  { smpVersionRange :: VersionRangeSMP,
    sessionId :: SessionId,
    -- pub key to agree shared secrets for command authorization and entity ID encryption.
    -- todo C.PublicKeyX25519
    authPubKey :: Maybe (X.CertificateChain, X.SignedExact X.PubKey)
  }

data ClientHandshake = ClientHandshake
  { -- | agreed SMP server protocol version
    smpVersion :: VersionSMP,
    -- | server identity - CA certificate fingerprint
    keyHash :: C.KeyHash,
    -- | pub key to agree shared secret for entity ID encryption, shared secret for command authorization is agreed using per-queue keys.
    authPubKey :: Maybe C.PublicKeyX25519,
    -- | Whether connecting client is a proxy server (send from SMP v12).
    -- This property, if True, disables additional transport encrytion inside TLS.
    -- (Proxy server connection already has additional encryption, so this layer is not needed there).
    proxyServer :: Bool
  }

instance Encoding ClientHandshake where
  smpEncode ClientHandshake {smpVersion = v, keyHash, authPubKey, proxyServer} =
    smpEncode (v, keyHash)
      <> encodeAuthEncryptCmds v authPubKey
      <> ifHasProxy v (smpEncode proxyServer) ""
  smpP = do
    (v, keyHash) <- smpP
    -- TODO drop SMP v6: remove special parser and make key non-optional
    authPubKey <- authEncryptCmdsP v smpP
    proxyServer <- ifHasProxy v smpP (pure False)
    pure ClientHandshake {smpVersion = v, keyHash, authPubKey, proxyServer}

ifHasProxy :: VersionSMP -> a -> a -> a
ifHasProxy v a b = if v >= proxyServerHandshakeSMPVersion then a else b

instance Encoding ServerHandshake where
  smpEncode ServerHandshake {smpVersionRange, sessionId, authPubKey} =
    smpEncode (smpVersionRange, sessionId) <> auth
    where
      auth =
        encodeAuthEncryptCmds (maxVersion smpVersionRange) $
          bimap C.encodeCertChain C.SignedObject <$> authPubKey
  smpP = do
    (smpVersionRange, sessionId) <- smpP
    -- TODO drop SMP v6: remove special parser and make key non-optional
    authPubKey <- authEncryptCmdsP (maxVersion smpVersionRange) authP
    pure ServerHandshake {smpVersionRange, sessionId, authPubKey}
    where
      authP = do
        cert <- C.certChainP
        C.SignedObject key <- smpP
        pure (cert, key)

encodeAuthEncryptCmds :: Encoding a => VersionSMP -> Maybe a -> ByteString
encodeAuthEncryptCmds v k
  | v >= authCmdsSMPVersion = maybe "" smpEncode k
  | otherwise = ""

authEncryptCmdsP :: VersionSMP -> Parser a -> Parser (Maybe a)
authEncryptCmdsP v p = if v >= authCmdsSMPVersion then optional p else pure Nothing

-- | Error of SMP encrypted transport over TCP.
data TransportError
  = -- | error parsing transport block
    TEBadBlock
  | -- | incompatible client or server version
    TEVersion
  | -- | message does not fit in transport block
    TELargeMsg
  | -- | incorrect session ID
    TEBadSession
  | -- | absent server key for v7 entity
    -- This error happens when the server did not provide a DH key to authorize commands for the queue that should be authorized with a DH key.
    TENoServerAuth
  | -- | transport handshake error
    TEHandshake {handshakeErr :: HandshakeError}
  deriving (Eq, Read, Show, Exception)

-- | Transport handshake error.
data HandshakeError
  = -- | parsing error
    PARSE
  | -- | incorrect server identity
    IDENTITY
  | -- | v7 authentication failed
    BAD_AUTH
  deriving (Eq, Read, Show, Exception)

instance Encoding TransportError where
  smpP =
    A.takeTill (== ' ') >>= \case
      "BLOCK" -> pure TEBadBlock
      "VERSION" -> pure TEVersion
      "LARGE_MSG" -> pure TELargeMsg
      "SESSION" -> pure TEBadSession
      "NO_AUTH" -> pure TENoServerAuth
      "HANDSHAKE" -> TEHandshake <$> (A.space *> parseRead1)
      _ -> fail "bad TransportError"
  smpEncode = \case
    TEBadBlock -> "BLOCK"
    TEVersion -> "VERSION"
    TELargeMsg -> "LARGE_MSG"
    TEBadSession -> "SESSION"
    TENoServerAuth -> "NO_AUTH"
    TEHandshake e -> "HANDSHAKE " <> bshow e

-- | Pad and send block to SMP transport.
tPutBlock :: Transport c => THandle v c p -> ByteString -> IO (Either TransportError ())
tPutBlock THandle {connection = c, params = THandleParams {blockSize, encryptBlock}} block = do
  block_ <- case encryptBlock of
    Just TSbChainKeys {sndKey} -> do
      (sk, nonce) <- atomically $ stateTVar sndKey C.sbcHkdf
      pure $ C.sbEncrypt sk nonce block (blockSize - 16)
    Nothing -> pure $ C.pad block blockSize
  bimapM (const $ pure TELargeMsg) (cPut c) block_

-- | Receive block from SMP transport.
tGetBlock :: Transport c => THandle v c p -> IO (Either TransportError ByteString)
tGetBlock THandle {connection = c, params = THandleParams {blockSize, encryptBlock}} = do
  msg <- cGet c blockSize
  if B.length msg == blockSize
    then
      first (const TELargeMsg) <$>
        case encryptBlock of
          Just TSbChainKeys {rcvKey} -> do
            (sk, nonce) <- atomically $ stateTVar rcvKey C.sbcHkdf
            pure $ C.sbDecrypt sk nonce msg
          Nothing -> pure $ C.unPad msg
    else ioe_EOF

-- | Server SMP transport handshake.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#appendix-a
smpServerHandshake :: forall c. Transport c => C.APrivateSignKey -> c -> C.KeyPairX25519 -> C.KeyHash -> VersionRangeSMP -> ExceptT TransportError IO (THandleSMP c 'TServer)
smpServerHandshake serverSignKey c (k, pk) kh smpVRange = do
  let th@THandle {params = THandleParams {sessionId}} = smpTHandle c
      sk = C.signX509 serverSignKey $ C.publicToX509 k
      certChain = getServerCerts c
      smpVersionRange = maybe legacyServerSMPRelayVRange (const smpVRange) $ getSessionALPN c
  sendHandshake th $ ServerHandshake {sessionId, smpVersionRange, authPubKey = Just (certChain, sk)}
  getHandshake th >>= \case
    ClientHandshake {smpVersion = v, keyHash, authPubKey = k', proxyServer}
      | keyHash /= kh ->
          throwE $ TEHandshake IDENTITY
      | otherwise ->
          case compatibleVRange' smpVersionRange v of
            Just (Compatible vr) -> liftIO $ smpTHandleServer th v vr pk k' proxyServer
            Nothing -> throwE TEVersion

-- | Client SMP transport handshake.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#appendix-a
smpClientHandshake :: forall c. Transport c => c -> Maybe C.KeyPairX25519 -> C.KeyHash -> VersionRangeSMP -> Bool -> ExceptT TransportError IO (THandleSMP c 'TClient)
smpClientHandshake c ks_ keyHash@(C.KeyHash kh) vRange proxyServer = do
  let th@THandle {params = THandleParams {sessionId}} = smpTHandle c
  ServerHandshake {sessionId = sessId, smpVersionRange, authPubKey} <- getHandshake th
  when (sessionId /= sessId) $ throwE TEBadSession
  -- Below logic downgrades version range in case the "client" is SMP proxy server and it is
  -- connected to the destination server of the version 11 or older.
  -- It disables transport encryption between SMP proxy and destination relay.
  --
  -- Prior to version v6.3 the version between proxy and destination was capped at 8,
  -- by mistake, which also disables transport encryption and the latest features.
  --
  -- Transport encryption between proxy and destination breaks clients with version 10 or earlier,
  -- because of a larger message size (see maxMessageLength).
  --
  -- To summarize:
  -- - proxy and relay version 12: the agreed version is 12, transport encryption disabled (see blockEncryption with proxyServer == True).
  -- - proxy is v 12, relay is 11: the agreed version is 10, because of this logic, transport encryption is disabled.
  let smpVRange =
        if proxyServer && maxVersion smpVersionRange < proxyServerHandshakeSMPVersion
          then vRange {maxVersion = max (minVersion vRange) deletedEventSMPVersion}
          else vRange
  case smpVersionRange `compatibleVRange` smpVRange of
    Just (Compatible vr) -> do
      ck_ <- forM authPubKey $ \certKey@(X.CertificateChain cert, exact) ->
        liftEitherWith (const $ TEHandshake BAD_AUTH) $ do
          case cert of
            [_leaf, ca] | XV.Fingerprint kh == XV.getFingerprint ca X.HashSHA256 -> pure ()
            _ -> throwError "bad certificate"
          serverKey <- getServerVerifyKey c
          pubKey <- C.verifyX509 serverKey exact
          (,certKey) <$> (C.x509ToPublic (pubKey, []) >>= C.pubKey)
      let v = maxVersion vr
      sendHandshake th $ ClientHandshake {smpVersion = v, keyHash, authPubKey = fst <$> ks_, proxyServer}
      liftIO $ smpTHandleClient th v vr (snd <$> ks_) ck_ proxyServer
    Nothing -> throwE TEVersion

smpTHandleServer :: forall c. THandleSMP c 'TServer -> VersionSMP -> VersionRangeSMP -> C.PrivateKeyX25519 -> Maybe C.PublicKeyX25519 -> Bool -> IO (THandleSMP c 'TServer)
smpTHandleServer th v vr pk k_ proxyServer = do
  let thAuth = Just THAuthServer {serverPrivKey = pk, sessSecret' = (`C.dh'` pk) <$!> k_}
  be <- blockEncryption th v proxyServer thAuth
  pure $ smpTHandle_ th v vr thAuth $ uncurry TSbChainKeys <$> be

smpTHandleClient :: forall c. THandleSMP c 'TClient -> VersionSMP -> VersionRangeSMP -> Maybe C.PrivateKeyX25519 -> Maybe (C.PublicKeyX25519, (X.CertificateChain, X.SignedExact X.PubKey)) -> Bool -> IO (THandleSMP c 'TClient)
smpTHandleClient th v vr pk_ ck_ proxyServer = do
  let thAuth = (\(k, ck) -> THAuthClient {serverPeerPubKey = k, serverCertKey = forceCertChain ck, sessSecret = C.dh' k <$!> pk_}) <$!> ck_
  be <- blockEncryption th v proxyServer thAuth
  -- swap is needed to use client's sndKey as server's rcvKey and vice versa
  pure $ smpTHandle_ th v vr thAuth $ uncurry TSbChainKeys . swap <$> be

blockEncryption :: THandleSMP c p -> VersionSMP -> Bool -> Maybe (THandleAuth p) -> IO (Maybe (TVar C.SbChainKey, TVar C.SbChainKey))
blockEncryption THandle {params = THandleParams {sessionId}} v proxyServer = \case
  Just thAuth | not proxyServer && v >= encryptedBlockSMPVersion -> case thAuth of
    THAuthClient {sessSecret} -> be sessSecret
    THAuthServer {sessSecret'} -> be sessSecret'
  _ -> pure Nothing
  where
    be :: Maybe C.DhSecretX25519 -> IO (Maybe (TVar C.SbChainKey, TVar C.SbChainKey))
    be = mapM $ \(C.DhSecretX25519 secret) -> bimapM newTVarIO newTVarIO $ C.sbcInit sessionId secret

smpTHandle_ :: forall c p. THandleSMP c p -> VersionSMP -> VersionRangeSMP -> Maybe (THandleAuth p) -> Maybe TSbChainKeys -> THandleSMP c p
smpTHandle_ th@THandle {params} v vr thAuth encryptBlock =
  -- TODO drop SMP v6: make thAuth non-optional
  let params' = params {thVersion = v, thServerVRange = vr, thAuth, implySessId = v >= authCmdsSMPVersion, encryptBlock}
   in (th :: THandleSMP c p) {params = params'}

{-# INLINE forceCertChain #-}
forceCertChain :: (X.CertificateChain, X.SignedExact T.PubKey) -> (X.CertificateChain, X.SignedExact T.PubKey)
forceCertChain cert@(X.CertificateChain cc, signedKey) = length (show cc) `seq` show signedKey `seq` cert

-- This function is only used with v >= 8, so currently it's a simple record update.
-- It may require some parameters update in the future, to be consistent with smpTHandle_.
smpTHParamsSetVersion :: VersionSMP -> THandleParams SMPVersion p -> THandleParams SMPVersion p
smpTHParamsSetVersion v params = params {thVersion = v}
{-# INLINE smpTHParamsSetVersion #-}

sendHandshake :: (Transport c, Encoding smp) => THandle v c p -> smp -> ExceptT TransportError IO ()
sendHandshake th = ExceptT . tPutBlock th . smpEncode

-- ignores tail bytes to allow future extensions
getHandshake :: (Transport c, Encoding smp) => THandle v c p -> ExceptT TransportError IO smp
getHandshake th = ExceptT $ (first (\_ -> TEHandshake PARSE) . A.parseOnly smpP =<<) <$> tGetBlock th

smpTHandle :: Transport c => c -> THandleSMP c p
smpTHandle c = THandle {connection = c, params}
  where
    v = VersionSMP 0
    params =
      THandleParams
        { sessionId = tlsUnique c,
          blockSize = smpBlockSize,
          thServerVRange = versionToRange v,
          thVersion = v,
          thAuth = Nothing,
          implySessId = False,
          encryptBlock = Nothing,
          batch = True
        }

$(J.deriveJSON (sumTypeJSON id) ''HandshakeError)

$(J.deriveJSON (sumTypeJSON $ dropPrefix "TE") ''TransportError)
