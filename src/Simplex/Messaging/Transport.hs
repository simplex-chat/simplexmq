{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

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
    supportedClientSMPRelayVRange,
    supportedServerSMPRelayVRange,
    currentClientSMPRelayVersion,
    currentServerSMPRelayVersion,
    batchCmdsSMPVersion,
    basicAuthSMPVersion,
    subModeSMPVersion,
    authCmdsSMPVersion,
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
    supportedParameters,
    withTlsUnique,

    -- * SMP transport
    THandle (..),
    THandleParams (..),
    THandleAuth (..),
    TransportError (..),
    HandshakeError (..),
    smpServerHandshake,
    smpClientHandshake,
    tPutBlock,
    tGetBlock,
    serializeTransportError,
    transportErrorP,
    sendHandshake,
    getHandshake,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (forM)
import Control.Monad.Except
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
import UnliftIO.Exception (Exception)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

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
-- 7 - support authenticated encryption to verify senders' commands, imply but do NOT send session ID in signed part (2/3/2024)

data SMPVersion

instance VersionScope SMPVersion

type VersionSMP = Version SMPVersion

type VersionRangeSMP = VersionRange SMPVersion

pattern VersionSMP :: Word16 -> VersionSMP
pattern VersionSMP v = Version v

batchCmdsSMPVersion :: VersionSMP
batchCmdsSMPVersion = VersionSMP 4

basicAuthSMPVersion :: VersionSMP
basicAuthSMPVersion = VersionSMP 5

subModeSMPVersion :: VersionSMP
subModeSMPVersion = VersionSMP 6

authCmdsSMPVersion :: VersionSMP
authCmdsSMPVersion = VersionSMP 7

currentClientSMPRelayVersion :: VersionSMP
currentClientSMPRelayVersion = VersionSMP 6

currentServerSMPRelayVersion :: VersionSMP
currentServerSMPRelayVersion = VersionSMP 6

-- minimal supported protocol version is 4
-- TODO remove code that supports sending commands without batching
supportedClientSMPRelayVRange :: VersionRangeSMP
supportedClientSMPRelayVRange = mkVersionRange batchCmdsSMPVersion currentClientSMPRelayVersion

supportedServerSMPRelayVRange :: VersionRangeSMP
supportedServerSMPRelayVRange = mkVersionRange batchCmdsSMPVersion currentServerSMPRelayVersion

simplexMQVersion :: String
simplexMQVersion = showVersion SMQ.version

-- * Transport connection class

data TransportConfig = TransportConfig
  { logTLSErrors :: Bool,
    transportTimeout :: Maybe Int
  }

class Transport c where
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
      tlsBuffer <- atomically newTBuffer
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

supportedParameters :: T.Supported
supportedParameters =
  def
    { T.supportedVersions = [T.TLS13, T.TLS12],
      T.supportedCiphers =
        [ TE.cipher_TLS13_CHACHA20POLY1305_SHA256, -- for TLS13
          TE.cipher_ECDHE_ECDSA_CHACHA20POLY1305_SHA256 -- for TLS12
        ],
      T.supportedHashSignatures = [(T.HashIntrinsic, T.SignatureEd448), (T.HashIntrinsic, T.SignatureEd25519)],
      T.supportedSecureRenegotiation = False,
      T.supportedGroups = [T.X448, T.X25519]
    }

instance Transport TLS where
  transportName _ = "TLS"
  transportPeer = tlsPeer
  transportConfig = tlsTransportConfig
  getServerConnection = getTLS TServer
  getClientConnection = getTLS TClient
  getServerCerts = tlsServerCerts
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
    getLnBuffered tlsBuffer (T.recvData tlsContext) `E.catch` handleEOF
    where
      handleEOF = \case
        T.Error_EOF -> E.throwIO TEBadBlock
        e -> E.throwIO e

-- * SMP transport

-- | The handle for SMP encrypted transport connection over Transport.
data THandle v c = THandle
  { connection :: c,
    params :: THandleParams v
  }

type THandleSMP c = THandle SMPVersion c

data THandleParams v = THandleParams
  { sessionId :: SessionId,
    blockSize :: Int,
    -- | agreed server protocol version
    thVersion :: Version v,
    -- | peer public key for command authorization and shared secrets for entity ID encryption
    thAuth :: Maybe THandleAuth,
    -- | do NOT send session ID in transmission, but include it into signed message
    -- based on protocol version
    implySessId :: Bool,
    -- | send multiple transmissions in a single block
    -- based on protocol version
    batch :: Bool
  }

data THandleAuth = THandleAuth
  { peerPubKey :: C.PublicKeyX25519, -- used only in the client to combine with per-queue key
    privKey :: C.PrivateKeyX25519 -- used to combine with peer's per-queue key (currently only in the server)
  }

-- | TLS-unique channel binding
type SessionId = ByteString

data ServerHandshake = ServerHandshake
  { smpVersionRange :: VersionRangeSMP,
    sessionId :: SessionId,
    -- pub key to agree shared secrets for command authorization and entity ID encryption.
    authPubKey :: Maybe (X.CertificateChain, X.SignedExact X.PubKey)
  }

data ClientHandshake = ClientHandshake
  { -- | agreed SMP server protocol version
    smpVersion :: VersionSMP,
    -- | server identity - CA certificate fingerprint
    keyHash :: C.KeyHash,
    -- pub key to agree shared secret for entity ID encryption, shared secret for command authorization is agreed using per-queue keys.
    authPubKey :: Maybe C.PublicKeyX25519
  }

instance Encoding ClientHandshake where
  smpEncode ClientHandshake {smpVersion, keyHash, authPubKey} =
    smpEncode (smpVersion, keyHash) <> encodeAuthEncryptCmds smpVersion authPubKey
  smpP = do
    (smpVersion, keyHash) <- smpP
    -- TODO drop SMP v6: remove special parser and make key non-optional
    authPubKey <- authEncryptCmdsP smpVersion smpP
    pure ClientHandshake {smpVersion, keyHash, authPubKey}

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
authEncryptCmdsP v p = if v >= authCmdsSMPVersion then Just <$> p else pure Nothing

-- | Error of SMP encrypted transport over TCP.
data TransportError
  = -- | error parsing transport block
    TEBadBlock
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
  | -- | incompatible peer version
    VERSION
  | -- | incorrect server identity
    IDENTITY
  | -- | v7 authentication failed
    BAD_AUTH
  deriving (Eq, Read, Show, Exception)

-- | SMP encrypted transport error parser.
transportErrorP :: Parser TransportError
transportErrorP =
  "BLOCK" $> TEBadBlock
    <|> "LARGE_MSG" $> TELargeMsg
    <|> "SESSION" $> TEBadSession
    <|> "NO_AUTH" $> TENoServerAuth
    <|> "HANDSHAKE " *> (TEHandshake <$> parseRead1)

-- | Serialize SMP encrypted transport error.
serializeTransportError :: TransportError -> ByteString
serializeTransportError = \case
  TEBadBlock -> "BLOCK"
  TELargeMsg -> "LARGE_MSG"
  TEBadSession -> "SESSION"
  TENoServerAuth -> "NO_AUTH"
  TEHandshake e -> "HANDSHAKE " <> bshow e

-- | Pad and send block to SMP transport.
tPutBlock :: Transport c => THandle v c -> ByteString -> IO (Either TransportError ())
tPutBlock THandle {connection = c, params = THandleParams {blockSize}} block =
  bimapM (const $ pure TELargeMsg) (cPut c) $
    C.pad block blockSize

-- | Receive block from SMP transport.
tGetBlock :: Transport c => THandle v c -> IO (Either TransportError ByteString)
tGetBlock THandle {connection = c, params = THandleParams {blockSize}} = do
  msg <- cGet c blockSize
  if B.length msg == blockSize
    then pure . first (const TELargeMsg) $ C.unPad msg
    else ioe_EOF

-- | Server SMP transport handshake.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#appendix-a
smpServerHandshake :: forall c. Transport c => C.APrivateSignKey -> c -> C.KeyPairX25519 -> C.KeyHash -> VersionRangeSMP -> ExceptT TransportError IO (THandleSMP c)
smpServerHandshake serverSignKey c (k, pk) kh smpVRange = do
  let th@THandle {params = THandleParams {sessionId}} = smpTHandle c
      sk = C.signX509 serverSignKey $ C.publicToX509 k
      certChain = getServerCerts c
  sendHandshake th $ ServerHandshake {sessionId, smpVersionRange = smpVRange, authPubKey = Just (certChain, sk)}
  getHandshake th >>= \case
    ClientHandshake {smpVersion = v, keyHash, authPubKey = k'}
      | keyHash /= kh ->
          throwE $ TEHandshake IDENTITY
      | v `isCompatible` smpVRange ->
          pure $ smpThHandle th v pk k'
      | otherwise -> throwE $ TEHandshake VERSION

-- | Client SMP transport handshake.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#appendix-a
smpClientHandshake :: forall c. Transport c => c -> C.KeyPairX25519 -> C.KeyHash -> VersionRangeSMP -> ExceptT TransportError IO (THandleSMP c)
smpClientHandshake c (k, pk) keyHash@(C.KeyHash kh) smpVRange = do
  let th@THandle {params = THandleParams {sessionId}} = smpTHandle c
  ServerHandshake {sessionId = sessId, smpVersionRange, authPubKey} <- getHandshake th
  if sessionId /= sessId
    then throwE TEBadSession
    else case smpVersionRange `compatibleVersion` smpVRange of
      Just (Compatible v) -> do
        sk_ <- forM authPubKey $ \(X.CertificateChain cert, exact) ->
          liftEitherWith (const $ TEHandshake BAD_AUTH) $ do
            case cert of
              [_leaf, ca] | XV.Fingerprint kh == XV.getFingerprint ca X.HashSHA256 -> pure ()
              _ -> throwError "bad certificate"
            serverKey <- getServerVerifyKey c
            pubKey <- C.verifyX509 serverKey exact
            C.x509ToPublic (pubKey, []) >>= C.pubKey
        sendHandshake th $ ClientHandshake {smpVersion = v, keyHash, authPubKey = Just k}
        pure $ smpThHandle th v pk sk_
      Nothing -> throwE $ TEHandshake VERSION

smpThHandle :: forall c. THandleSMP c -> VersionSMP -> C.PrivateKeyX25519 -> Maybe C.PublicKeyX25519 -> THandleSMP c
smpThHandle th@THandle {params} v privKey k_ =
  -- TODO drop SMP v6: make thAuth non-optional
  let thAuth = (\k -> THandleAuth {peerPubKey = k, privKey}) <$> k_
      params' = params {thVersion = v, thAuth, implySessId = v >= authCmdsSMPVersion}
   in (th :: THandleSMP c) {params = params'}

sendHandshake :: (Transport c, Encoding smp) => THandle v c -> smp -> ExceptT TransportError IO ()
sendHandshake th = ExceptT . tPutBlock th . smpEncode

-- ignores tail bytes to allow future extensions
getHandshake :: (Transport c, Encoding smp) => THandle v c -> ExceptT TransportError IO smp
getHandshake th = ExceptT $ (first (\_ -> TEHandshake PARSE) . A.parseOnly smpP =<<) <$> tGetBlock th

smpTHandle :: Transport c => c -> THandleSMP c
smpTHandle c = THandle {connection = c, params}
  where
    params = THandleParams {sessionId = tlsUnique c, blockSize = smpBlockSize, thVersion = VersionSMP 0, thAuth = Nothing, implySessId = False, batch = True}

$(J.deriveJSON (sumTypeJSON id) ''HandshakeError)

$(J.deriveJSON (sumTypeJSON $ dropPrefix "TE") ''TransportError)
