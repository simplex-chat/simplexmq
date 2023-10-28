{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
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
    supportedSMPServerVRange,
    simplexMQVersion,
    smpBlockSize,
    TransportConfig (..),

    -- * Transport connection class
    Transport (..),
    TProxy (..),
    ATransport (..),
    TransportPeer (..),

    -- * TLS Transport
    TLS (..),
    SessionId,
    connectTLS,
    closeTLS,
    supportedParameters,
    withTlsUnique,

    -- * SMP transport
    THandle (..),
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
import Control.Monad.Except
import Control.Monad.Trans.Except (throwE)
import qualified Data.Aeson.TH as J
import Data.Attoparsec.ByteString.Char8 (Parser)
import Data.Bifunctor (first)
import Data.Bitraversable (bimapM)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL
import Data.Default (def)
import Data.Functor (($>))
import Data.Version (showVersion)
import GHC.IO.Handle.Internals (ioe_EOF)
import Network.Socket
import qualified Network.TLS as T
import qualified Network.TLS.Extra as TE
import qualified Paths_simplexmq as SMQ
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Parsers (dropPrefix, parse, parseRead1, sumTypeJSON)
import Simplex.Messaging.Transport.Buffer
import Simplex.Messaging.Util (bshow, catchAll, catchAll_)
import Simplex.Messaging.Version
import UnliftIO.Exception (Exception)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

-- * Transport parameters

smpBlockSize :: Int
smpBlockSize = 16384

supportedSMPServerVRange :: VersionRange
supportedSMPServerVRange = mkVersionRange 1 6

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
  getServerConnection :: TransportConfig -> T.Context -> IO c

  -- | Upgrade client TLS context to connection (used in the client)
  getClientConnection :: TransportConfig -> T.Context -> IO c

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

-- * TLS Transport

data TLS = TLS
  { tlsContext :: T.Context,
    tlsPeer :: TransportPeer,
    tlsUniq :: ByteString,
    tlsBuffer :: TBuffer,
    tlsTransportConfig :: TransportConfig
  }

connectTLS :: T.TLSParams p => Maybe HostName -> TransportConfig -> p -> Socket -> IO T.Context
connectTLS host_ TransportConfig {logTLSErrors} params sock =
  E.bracketOnError (T.contextNew sock params) closeTLS $ \ctx ->
    logHandshakeErrors (T.handshake ctx) $> ctx
  where
    logHandshakeErrors = if logTLSErrors then (`catchAll` logThrow) else id
    logThrow e = putStrLn ("TLS error" <> host <> ": " <> show e) >> E.throwIO e
    host = maybe "" (\h -> " (" <> h <> ")") host_

getTLS :: TransportPeer -> TransportConfig -> T.Context -> IO TLS
getTLS tlsPeer cfg cxt = withTlsUnique tlsPeer cxt newTLS
  where
    newTLS tlsUniq = do
      tlsBuffer <- atomically newTBuffer
      pure TLS {tlsContext = cxt, tlsTransportConfig = cfg, tlsPeer, tlsUniq, tlsBuffer}

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
  tlsUnique = tlsUniq
  closeConnection tls = closeTLS $ tlsContext tls

  -- https://hackage.haskell.org/package/tls-1.6.0/docs/Network-TLS.html#v:recvData
  -- this function may return less than requested number of bytes
  cGet :: TLS -> Int -> IO ByteString
  cGet TLS {tlsContext, tlsBuffer, tlsTransportConfig = TransportConfig {transportTimeout = t_}} n =
    getBuffered tlsBuffer n t_ (T.recvData tlsContext)

  cPut :: TLS -> ByteString -> IO ()
  cPut TLS {tlsContext, tlsTransportConfig = TransportConfig {transportTimeout = t_}} s =
    withTimedErr t_ . T.sendData tlsContext $ BL.fromStrict s

  getLn :: TLS -> IO ByteString
  getLn TLS {tlsContext, tlsBuffer} = do
    getLnBuffered tlsBuffer (T.recvData tlsContext) `E.catch` handleEOF
    where
      handleEOF = \case
        T.Error_EOF -> E.throwIO TEBadBlock
        e -> E.throwIO e

-- * SMP transport

-- | The handle for SMP encrypted transport connection over Transport .
data THandle c = THandle
  { connection :: c,
    sessionId :: SessionId,
    blockSize :: Int,
    -- | agreed server protocol version
    thVersion :: Version,
    -- | send multiple transmissions in a single block
    -- based on protocol and protocol version
    batch :: Bool
  }

-- | TLS-unique channel binding
type SessionId = ByteString

data ServerHandshake = ServerHandshake
  { smpVersionRange :: VersionRange,
    sessionId :: SessionId
  }

data ClientHandshake = ClientHandshake
  { -- | agreed SMP server protocol version
    smpVersion :: Version,
    -- | server identity - CA certificate fingerprint
    keyHash :: C.KeyHash
  }

instance Encoding ClientHandshake where
  smpEncode ClientHandshake {smpVersion, keyHash} = smpEncode (smpVersion, keyHash)
  smpP = do
    (smpVersion, keyHash) <- smpP
    pure ClientHandshake {smpVersion, keyHash}

instance Encoding ServerHandshake where
  smpEncode ServerHandshake {smpVersionRange, sessionId} =
    smpEncode (smpVersionRange, sessionId)
  smpP = do
    (smpVersionRange, sessionId) <- smpP
    pure ServerHandshake {smpVersionRange, sessionId}

-- | Error of SMP encrypted transport over TCP.
data TransportError
  = -- | error parsing transport block
    TEBadBlock
  | -- | message does not fit in transport block
    TELargeMsg
  | -- | incorrect session ID
    TEBadSession
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
  deriving (Eq, Read, Show, Exception)

-- | SMP encrypted transport error parser.
transportErrorP :: Parser TransportError
transportErrorP =
  "BLOCK" $> TEBadBlock
    <|> "LARGE_MSG" $> TELargeMsg
    <|> "SESSION" $> TEBadSession
    <|> "HANDSHAKE " *> (TEHandshake <$> parseRead1)

-- | Serialize SMP encrypted transport error.
serializeTransportError :: TransportError -> ByteString
serializeTransportError = \case
  TEBadBlock -> "BLOCK"
  TELargeMsg -> "LARGE_MSG"
  TEBadSession -> "SESSION"
  TEHandshake e -> "HANDSHAKE " <> bshow e

-- | Pad and send block to SMP transport.
tPutBlock :: Transport c => THandle c -> ByteString -> IO (Either TransportError ())
tPutBlock THandle {connection = c, blockSize} block =
  bimapM (const $ pure TELargeMsg) (cPut c) $
    C.pad block blockSize

-- | Receive block from SMP transport.
tGetBlock :: Transport c => THandle c -> IO (Either TransportError ByteString)
tGetBlock THandle {connection = c, blockSize} = do
  msg <- cGet c blockSize
  if B.length msg == blockSize
    then pure . first (const TELargeMsg) $ C.unPad msg
    else ioe_EOF

-- | Server SMP transport handshake.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#appendix-a
smpServerHandshake :: forall c. Transport c => c -> C.KeyHash -> VersionRange -> ExceptT TransportError IO (THandle c)
smpServerHandshake c kh smpVRange = do
  let th@THandle {sessionId} = smpTHandle c
  sendHandshake th $ ServerHandshake {sessionId, smpVersionRange = smpVRange}
  getHandshake th >>= \case
    ClientHandshake {smpVersion, keyHash}
      | keyHash /= kh ->
          throwE $ TEHandshake IDENTITY
      | smpVersion `isCompatible` smpVRange -> do
          pure $ smpThHandle th smpVersion
      | otherwise -> throwE $ TEHandshake VERSION

-- | Client SMP transport handshake.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#appendix-a
smpClientHandshake :: forall c. Transport c => c -> C.KeyHash -> VersionRange -> ExceptT TransportError IO (THandle c)
smpClientHandshake c keyHash smpVRange = do
  let th@THandle {sessionId} = smpTHandle c
  ServerHandshake {sessionId = sessId, smpVersionRange} <- getHandshake th
  if sessionId /= sessId
    then throwE TEBadSession
    else case smpVersionRange `compatibleVersion` smpVRange of
      Just (Compatible smpVersion) -> do
        sendHandshake th $ ClientHandshake {smpVersion, keyHash}
        pure $ smpThHandle th smpVersion
      Nothing -> throwE $ TEHandshake VERSION

smpThHandle :: forall c. THandle c -> Version -> THandle c
smpThHandle th v = (th :: THandle c) {thVersion = v, batch = v >= 4}

sendHandshake :: (Transport c, Encoding smp) => THandle c -> smp -> ExceptT TransportError IO ()
sendHandshake th = ExceptT . tPutBlock th . smpEncode

getHandshake :: (Transport c, Encoding smp) => THandle c -> ExceptT TransportError IO smp
getHandshake th = ExceptT $ (parse smpP (TEHandshake PARSE) =<<) <$> tGetBlock th

smpTHandle :: Transport c => c -> THandle c
smpTHandle c = THandle {connection = c, sessionId = tlsUnique c, blockSize = smpBlockSize, thVersion = 0, batch = False}

$(J.deriveJSON (sumTypeJSON id) ''HandshakeError)

$(J.deriveJSON (sumTypeJSON $ dropPrefix "TE") ''TransportError)
