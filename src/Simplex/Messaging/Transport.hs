{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
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
    smpServerHandshake,
    smpClientHandshake,
    tPutBlock,
    tGetBlock,
    serializeTransportError,
    transportErrorP,

    -- * Trim trailing CR
    trimCR,
  )
where

import Control.Applicative ((<|>))
import Control.Monad.Except
import Control.Monad.Trans.Except (throwE)
import Data.Aeson (ToJSON)
import qualified Data.Aeson as J
import Data.Attoparsec.ByteString.Char8 (Parser)
import Data.Bifunctor (first)
import Data.Bitraversable (bimapM)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL
import Data.Default (def)
import Data.Functor (($>))
import GHC.Generics (Generic)
import GHC.IO.Handle.Internals (ioe_EOF)
import Generic.Random (genericArbitraryU)
import Network.Socket
import qualified Network.TLS as T
import qualified Network.TLS.Extra as TE
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Parsers (dropPrefix, parse, parseRead1, sumTypeJSON)
import Simplex.Messaging.Util (bshow, catchAll, catchAll_)
import Simplex.Messaging.Version
import Test.QuickCheck (Arbitrary (..))
import UnliftIO.Exception (Exception)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

-- * Transport parameters

smpBlockSize :: Int
smpBlockSize = 16384

supportedSMPServerVRange :: VersionRange
supportedSMPServerVRange = mkVersionRange 1 3

simplexMQVersion :: String
simplexMQVersion = "3.0.0-rc.0"

-- * Transport connection class

class Transport c where
  transport :: ATransport
  transport = ATransport (TProxy @c)

  transportName :: TProxy c -> String

  transportPeer :: c -> TransportPeer

  -- | Upgrade server TLS context to connection (used in the server)
  getServerConnection :: T.Context -> IO c

  -- | Upgrade client TLS context to connection (used in the client)
  getClientConnection :: T.Context -> IO c

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
    buffer :: TVar ByteString,
    getLock :: TMVar ()
  }

connectTLS :: T.TLSParams p => p -> Socket -> IO T.Context
connectTLS params sock =
  E.bracketOnError (T.contextNew sock params) closeTLS $ \ctx -> do
    T.handshake ctx
      `catchAll` \e -> putStrLn ("exception: " <> show e) >> E.throwIO e
    pure ctx

getTLS :: TransportPeer -> T.Context -> IO TLS
getTLS tlsPeer cxt = withTlsUnique tlsPeer cxt newTLS
  where
    newTLS tlsUniq = do
      buffer <- newTVarIO ""
      getLock <- newTMVarIO ()
      pure TLS {tlsContext = cxt, tlsPeer, tlsUniq, buffer, getLock}

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
  getServerConnection = getTLS TServer
  getClientConnection = getTLS TClient
  tlsUnique = tlsUniq
  closeConnection tls = closeTLS $ tlsContext tls

  cGet :: TLS -> Int -> IO ByteString
  cGet TLS {tlsContext, buffer, getLock} n =
    E.bracket_
      (atomically $ takeTMVar getLock)
      (atomically $ putTMVar getLock ())
      $ do
        b <- readChunks =<< readTVarIO buffer
        let (s, b') = B.splitAt n b
        atomically $ writeTVar buffer b'
        pure s
    where
      readChunks :: ByteString -> IO ByteString
      readChunks b
        | B.length b >= n = pure b
        | otherwise =
          T.recvData tlsContext >>= \case
            -- https://hackage.haskell.org/package/tls-1.6.0/docs/Network-TLS.html#v:recvData
            "" -> ioe_EOF
            s -> readChunks $ b <> s

  cPut :: TLS -> ByteString -> IO ()
  cPut tls = T.sendData (tlsContext tls) . BL.fromStrict

  getLn :: TLS -> IO ByteString
  getLn TLS {tlsContext, buffer, getLock} = do
    E.bracket_
      (atomically $ takeTMVar getLock)
      (atomically $ putTMVar getLock ())
      $ do
        b <- readChunks =<< readTVarIO buffer
        let (s, b') = B.break (== '\n') b
        atomically $ writeTVar buffer (B.drop 1 b') -- drop '\n' we made a break at
        pure $ trimCR s
    where
      readChunks :: ByteString -> IO ByteString
      readChunks b
        | B.elem '\n' b = pure b
        | otherwise = readChunks . (b <>) =<< T.recvData tlsContext `E.catch` handleEOF
      handleEOF = \case
        T.Error_EOF -> E.throwIO TEBadBlock
        e -> E.throwIO e

-- | Trim trailing CR from ByteString.
trimCR :: ByteString -> ByteString
trimCR "" = ""
trimCR s = if B.last s == '\r' then B.init s else s

-- * SMP transport

-- | The handle for SMP encrypted transport connection over Transport .
data THandle c = THandle
  { connection :: c,
    sessionId :: SessionId,
    blockSize :: Int,
    -- | agreed server protocol version
    thVersion :: Version
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
  deriving (Eq, Generic, Read, Show, Exception)

instance ToJSON TransportError where
  toJSON = J.genericToJSON . sumTypeJSON $ dropPrefix "TE"
  toEncoding = J.genericToEncoding . sumTypeJSON $ dropPrefix "TE"

-- | Transport handshake error.
data HandshakeError
  = -- | parsing error
    PARSE
  | -- | incompatible peer version
    VERSION
  | -- | incorrect server identity
    IDENTITY
  deriving (Eq, Generic, Read, Show, Exception)

instance ToJSON HandshakeError where
  toJSON = J.genericToJSON $ sumTypeJSON id
  toEncoding = J.genericToEncoding $ sumTypeJSON id

instance Arbitrary TransportError where arbitrary = genericArbitraryU

instance Arbitrary HandshakeError where arbitrary = genericArbitraryU

-- | SMP encrypted transport error parser.
transportErrorP :: Parser TransportError
transportErrorP =
  "BLOCK" $> TEBadBlock
    <|> "LARGE_MSG" $> TELargeMsg
    <|> "SESSION" $> TEBadSession
    <|> TEHandshake <$> parseRead1

-- | Serialize SMP encrypted transport error.
serializeTransportError :: TransportError -> ByteString
serializeTransportError = \case
  TEBadBlock -> "BLOCK"
  TELargeMsg -> "LARGE_MSG"
  TEBadSession -> "SESSION"
  TEHandshake e -> bshow e

-- | Pad and send block to SMP transport.
tPutBlock :: Transport c => THandle c -> ByteString -> IO (Either TransportError ())
tPutBlock THandle {connection = c, blockSize} block =
  bimapM (const $ pure TELargeMsg) (cPut c) $
    C.pad block blockSize

-- | Receive block from SMP transport.
tGetBlock :: Transport c => THandle c -> IO (Either TransportError ByteString)
tGetBlock THandle {connection = c, blockSize} =
  cGet c blockSize >>= \case
    "" -> ioe_EOF
    msg -> pure . first (const TELargeMsg) $ C.unPad msg

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
        pure (th :: THandle c) {thVersion = smpVersion}
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
        pure (th :: THandle c) {thVersion = smpVersion}
      Nothing -> throwE $ TEHandshake VERSION

sendHandshake :: (Transport c, Encoding smp) => THandle c -> smp -> ExceptT TransportError IO ()
sendHandshake th = ExceptT . tPutBlock th . smpEncode

getHandshake :: (Transport c, Encoding smp) => THandle c -> ExceptT TransportError IO smp
getHandshake th = ExceptT $ (parse smpP (TEHandshake PARSE) =<<) <$> tGetBlock th

smpTHandle :: Transport c => c -> THandle c
smpTHandle c = THandle {connection = c, sessionId = tlsUnique c, blockSize = smpBlockSize, thVersion = 0}
