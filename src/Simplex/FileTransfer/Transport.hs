{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.FileTransfer.Transport where

import Control.Monad.Except
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Transport
import Simplex.Messaging.Version

fileBlockSize :: Int
fileBlockSize = 512

supportedFileServerVRange :: VersionRange
supportedFileServerVRange = mkVersionRange 1 1

data FileServerHandshake = FileServerHandshake
  { fileVersionRange :: VersionRange,
    sessionId :: SessionId
  }

data FileClientHandshake = FileClientHandshake
  { -- | agreed SMP notifications server protocol version
    fileVersion :: Version,
    -- | server identity - CA certificate fingerprint
    keyHash :: C.KeyHash
  }

instance Encoding FileServerHandshake where
  smpEncode FileServerHandshake {fileVersionRange, sessionId} =
    smpEncode (fileVersionRange, sessionId)
  smpP = do
    (fileVersionRange, sessionId) <- smpP
    pure FileServerHandshake {fileVersionRange, sessionId}

instance Encoding FileClientHandshake where
  smpEncode FileClientHandshake {fileVersion, keyHash} = smpEncode (fileVersion, keyHash)
  smpP = do
    (fileVersion, keyHash) <- smpP
    pure FileClientHandshake {fileVersion, keyHash}

-- | Notifcations server transport handshake.
fileServerHandshake :: forall c. Transport c => c -> C.KeyHash -> VersionRange -> ExceptT TransportError IO (THandle c)
fileServerHandshake c kh fileVRange = do
  let th@THandle {sessionId} = fileTHandle c
  sendHandshake th $ FileServerHandshake {sessionId, fileVersionRange = fileVRange}
  getHandshake th >>= \case
    FileClientHandshake {fileVersion, keyHash}
      | keyHash /= kh ->
        throwError $ TEHandshake IDENTITY
      | fileVersion `isCompatible` fileVRange -> do
        pure (th :: THandle c) {thVersion = fileVersion}
      | otherwise -> throwError $ TEHandshake VERSION

-- | Notifcations server client transport handshake.
fileClientHandshake :: forall c. Transport c => c -> C.KeyHash -> VersionRange -> ExceptT TransportError IO (THandle c)
fileClientHandshake c keyHash fileVRange = do
  let th@THandle {sessionId} = fileTHandle c
  FileServerHandshake {sessionId = sessId, fileVersionRange} <- getHandshake th
  if sessionId /= sessId
    then throwError TEBadSession
    else case fileVersionRange `compatibleVersion` fileVRange of
      Just (Compatible fileVersion) -> do
        sendHandshake th $ FileClientHandshake {fileVersion, keyHash}
        pure (th :: THandle c) {thVersion = fileVersion}
      Nothing -> throwError $ TEHandshake VERSION

fileTHandle :: Transport c => c -> THandle c
fileTHandle c = THandle {connection = c, sessionId = tlsUnique c, blockSize = fileBlockSize, thVersion = 0, batch = False}
