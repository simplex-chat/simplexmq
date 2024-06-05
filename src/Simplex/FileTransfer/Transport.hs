{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.FileTransfer.Transport
  ( supportedFileServerVRange,
    authCmdsXFTPVersion,
    xftpClientHandshakeStub,
    XFTPClientHandshake (..),
    -- xftpClientHandshake,
    XFTPServerHandshake (..),
    -- xftpServerHandshake,
    THandleXFTP,
    THandleParamsXFTP,
    VersionXFTP,
    VersionRangeXFTP,
    XFTPVersion,
    pattern VersionXFTP,
    XFTPErrorType (..),
    XFTPRcvChunkSpec (..),
    ReceiveFileError (..),
    receiveFile,
    sendEncFile,
    receiveEncFile,
    receiveSbFile,
  )
where

import Control.Applicative ((<|>))
import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import qualified Data.Aeson.TH as J
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (bimap, first)
import qualified Data.ByteArray as BA
import Data.ByteString.Builder (Builder, byteString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Functor (($>))
import Data.Word (Word16, Word32)
import qualified Data.X509 as X
import Network.HTTP2.Client (HTTP2Error)
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers
import Simplex.Messaging.Protocol (CommandError)
import Simplex.Messaging.Transport (SessionId, THandle (..), THandleParams (..), TransportError (..), TransportPeer (..))
import Simplex.Messaging.Transport.HTTP2.File
import Simplex.Messaging.Util (bshow, tshow)
import Simplex.Messaging.Version
import Simplex.Messaging.Version.Internal
import System.IO (Handle, IOMode (..), withFile)

data XFTPRcvChunkSpec = XFTPRcvChunkSpec
  { filePath :: FilePath,
    chunkSize :: Word32,
    chunkDigest :: ByteString
  }
  deriving (Show)

data XFTPVersion

instance VersionScope XFTPVersion

type VersionXFTP = Version XFTPVersion

type VersionRangeXFTP = VersionRange XFTPVersion

pattern VersionXFTP :: Word16 -> VersionXFTP
pattern VersionXFTP v = Version v

type THandleXFTP c p = THandle XFTPVersion c p
type THandleParamsXFTP p = THandleParams XFTPVersion p

initialXFTPVersion :: VersionXFTP
initialXFTPVersion = VersionXFTP 1

authCmdsXFTPVersion :: VersionXFTP
authCmdsXFTPVersion = VersionXFTP 2

currentXFTPVersion :: VersionXFTP
currentXFTPVersion = VersionXFTP 2

supportedFileServerVRange :: VersionRangeXFTP
supportedFileServerVRange = mkVersionRange initialXFTPVersion currentXFTPVersion

-- XFTP protocol does not use this handshake method
xftpClientHandshakeStub :: c -> Maybe C.KeyPairX25519 -> C.KeyHash -> VersionRangeXFTP -> ExceptT TransportError IO (THandle XFTPVersion c 'TClient)
xftpClientHandshakeStub _c _ks _keyHash _xftpVRange = throwE TEVersion

data XFTPServerHandshake = XFTPServerHandshake
  { xftpVersionRange :: VersionRangeXFTP,
    sessionId :: SessionId,
    -- | pub key to agree shared secrets for command authorization and entity ID encryption.
    authPubKey :: (X.CertificateChain, X.SignedExact X.PubKey)
  }

data XFTPClientHandshake = XFTPClientHandshake
  { -- | agreed XFTP server protocol version
    xftpVersion :: VersionXFTP,
    -- | server identity - CA certificate fingerprint
    keyHash :: C.KeyHash
  }

instance Encoding XFTPClientHandshake where
  smpEncode XFTPClientHandshake {xftpVersion, keyHash} =
    smpEncode (xftpVersion, keyHash)
  smpP = do
    (xftpVersion, keyHash) <- smpP
    Tail _compat <- smpP
    pure XFTPClientHandshake {xftpVersion, keyHash}

instance Encoding XFTPServerHandshake where
  smpEncode XFTPServerHandshake {xftpVersionRange, sessionId, authPubKey} =
    smpEncode (xftpVersionRange, sessionId, auth)
    where
      auth = bimap C.encodeCertChain C.SignedObject authPubKey
  smpP = do
    (xftpVersionRange, sessionId) <- smpP
    cert <- C.certChainP
    C.SignedObject key <- smpP
    Tail _compat <- smpP
    pure XFTPServerHandshake {xftpVersionRange, sessionId, authPubKey = (cert, key)}

sendEncFile :: Handle -> (Builder -> IO ()) -> LC.SbState -> Word32 -> IO ()
sendEncFile h send = go
  where
    go sbState 0 = do
      let authTag = BA.convert (LC.sbAuth sbState)
      send $ byteString authTag
    go sbState sz =
      getFileChunk h sz >>= \ch -> do
        let (encCh, sbState') = LC.sbEncryptChunk sbState ch
        send (byteString encCh) `E.catch` \(e :: E.SomeException) -> print e >> E.throwIO e
        go sbState' $ sz - fromIntegral (B.length ch)

receiveFile :: (Int -> IO ByteString) -> XFTPRcvChunkSpec -> ExceptT XFTPErrorType IO ()
receiveFile getBody chunk = ExceptT $ runExceptT (receiveFile_ receive chunk) `E.catches` handlers
  where
    receive h sz = hReceiveFile getBody h sz >>= \sz' -> pure $ if sz' == 0 then Right () else Left SIZE
    handlers =
      [ E.Handler $ \(e :: HTTP2Error) -> logWarn (err e) $> Left TIMEOUT,
        E.Handler $ \(e :: E.SomeException) -> logError (err e) $> Left FILE_IO
      ]
    err e = "receiveFile error: " <> tshow e

receiveEncFile :: (Int -> IO ByteString) -> LC.SbState -> XFTPRcvChunkSpec -> ExceptT XFTPErrorType IO ()
receiveEncFile getBody = receiveFile_ . receive
  where
    receive sbState h sz = first err <$> receiveSbFile getBody h sbState sz
    err RFESize = SIZE
    err RFECrypto = CRYPTO

data ReceiveFileError = RFESize | RFECrypto

receiveSbFile :: (Int -> IO ByteString) -> Handle -> LC.SbState -> Word32 -> IO (Either ReceiveFileError ())
receiveSbFile getBody h = receive
  where
    receive sbState sz = do
      ch <- getBody fileBlockSize
      let chSize = fromIntegral $ B.length ch
      if
        | chSize > sz + authSz -> pure $ Left RFESize
        | chSize > 0 -> do
            let (ch', rest) = B.splitAt (fromIntegral sz) ch
                (decCh, sbState') = LC.sbDecryptChunk sbState ch'
                sz' = sz - fromIntegral (B.length ch')
            B.hPut h decCh
            if sz' > 0
              then receive sbState' sz'
              else do
                let tag' = B.take C.authTagSize rest
                    tagSz = B.length tag'
                    tag = LC.sbAuth sbState'
                tag'' <- if tagSz == C.authTagSize then pure tag' else (tag' <>) <$> getBody (C.authTagSize - tagSz)
                pure $ if BA.constEq tag'' tag then Right () else Left RFECrypto
        | otherwise -> pure $ Left RFESize
    authSz = fromIntegral C.authTagSize

receiveFile_ :: (Handle -> Word32 -> IO (Either XFTPErrorType ())) -> XFTPRcvChunkSpec -> ExceptT XFTPErrorType IO ()
receiveFile_ receive XFTPRcvChunkSpec {filePath, chunkSize, chunkDigest} = do
  ExceptT $ withFile filePath WriteMode (`receive` chunkSize)
  digest' <- liftIO $ LC.sha256Hash <$> LB.readFile filePath
  when (digest' /= chunkDigest) $ throwE DIGEST

data XFTPErrorType
  = -- | incorrect block format, encoding or signature size
    BLOCK
  | -- | incorrect SMP session ID (TLS Finished message / tls-unique binding RFC5929)
    SESSION
  | -- | incorrect handshake command
    HANDSHAKE
  | -- | SMP command is unknown or has invalid syntax
    CMD {cmdErr :: CommandError}
  | -- | command authorization error - bad signature or non-existing SMP queue
    AUTH
  | -- | incorrent file size
    SIZE
  | -- | storage quota exceeded
    QUOTA
  | -- | incorrent file digest
    DIGEST
  | -- | file encryption/decryption failed
    CRYPTO
  | -- | no expected file body in request/response or no file on the server
    NO_FILE
  | -- | unexpected file body
    HAS_FILE
  | -- | file IO error
    FILE_IO
  | -- | file sending or receiving timeout
    TIMEOUT
  | -- | bad redirect data
    REDIRECT {redirectError :: String}
  | -- | cannot proceed with download from not approved relays without proxy
    NOT_APPROVED
  | -- | internal server error
    INTERNAL
  | -- | used internally, never returned by the server (to be removed)
    DUPLICATE_ -- not part of SMP protocol, used internally
  deriving (Eq, Read, Show)

instance StrEncoding XFTPErrorType where
  strEncode = \case
    CMD e -> "CMD " <> bshow e
    REDIRECT e -> "REDIRECT " <> bshow e
    e -> bshow e
  strP =
    "CMD " *> (CMD <$> parseRead1)
      <|> "REDIRECT " *> (REDIRECT <$> parseRead A.takeByteString)
      <|> parseRead1

instance Encoding XFTPErrorType where
  smpEncode = \case
    BLOCK -> "BLOCK"
    SESSION -> "SESSION"
    HANDSHAKE -> "HANDSHAKE"
    CMD err -> "CMD " <> smpEncode err
    AUTH -> "AUTH"
    SIZE -> "SIZE"
    QUOTA -> "QUOTA"
    DIGEST -> "DIGEST"
    CRYPTO -> "CRYPTO"
    NO_FILE -> "NO_FILE"
    HAS_FILE -> "HAS_FILE"
    FILE_IO -> "FILE_IO"
    TIMEOUT -> "TIMEOUT"
    REDIRECT err -> "REDIRECT " <> smpEncode err
    NOT_APPROVED -> "NOT_APPROVED"
    INTERNAL -> "INTERNAL"
    DUPLICATE_ -> "DUPLICATE_"

  smpP =
    A.takeTill (== ' ') >>= \case
      "BLOCK" -> pure BLOCK
      "SESSION" -> pure SESSION
      "HANDSHAKE" -> pure HANDSHAKE
      "CMD" -> CMD <$> _smpP
      "AUTH" -> pure AUTH
      "SIZE" -> pure SIZE
      "QUOTA" -> pure QUOTA
      "DIGEST" -> pure DIGEST
      "CRYPTO" -> pure CRYPTO
      "NO_FILE" -> pure NO_FILE
      "HAS_FILE" -> pure HAS_FILE
      "FILE_IO" -> pure FILE_IO
      "TIMEOUT" -> pure TIMEOUT
      "REDIRECT" -> REDIRECT <$> _smpP
      "NOT_APPROVED" -> pure NOT_APPROVED
      "INTERNAL" -> pure INTERNAL
      "DUPLICATE_" -> pure DUPLICATE_
      _ -> fail "bad error type"

$(J.deriveJSON (sumTypeJSON id) ''XFTPErrorType)
