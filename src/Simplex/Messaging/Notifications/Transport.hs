{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Notifications.Transport where

import Control.Monad.Except
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Transport
import Simplex.Messaging.Version

ntfBlockSize :: Int
ntfBlockSize = 512

supportedNTFServerVRange :: VersionRange
supportedNTFServerVRange = mkVersionRange 1 1

data NtfServerHandshake = NtfServerHandshake
  { ntfVersionRange :: VersionRange,
    sessionId :: SessionId
  }

data NtfClientHandshake = NtfClientHandshake
  { -- | agreed SMP notifications server protocol version
    ntfVersion :: Version,
    -- | server identity - CA certificate fingerprint
    keyHash :: C.KeyHash
  }

instance Encoding NtfServerHandshake where
  smpEncode NtfServerHandshake {ntfVersionRange, sessionId} =
    smpEncode (ntfVersionRange, sessionId)
  smpP = do
    (ntfVersionRange, sessionId) <- smpP
    pure NtfServerHandshake {ntfVersionRange, sessionId}

instance Encoding NtfClientHandshake where
  smpEncode NtfClientHandshake {ntfVersion, keyHash} = smpEncode (ntfVersion, keyHash)
  smpP = do
    (ntfVersion, keyHash) <- smpP
    pure NtfClientHandshake {ntfVersion, keyHash}

-- | Notifcations server transport handshake.
ntfServerHandshake :: forall c. Transport c => c -> C.KeyHash -> VersionRange -> ExceptT TransportError IO (THandle c)
ntfServerHandshake c kh ntfVRange = do
  let th@THandle {sessionId} = ntfTHandle c
  sendHandshake th $ NtfServerHandshake {sessionId, ntfVersionRange = ntfVRange}
  getHandshake th >>= \case
    NtfClientHandshake {ntfVersion, keyHash}
      | keyHash /= kh ->
          throwError $ TEHandshake IDENTITY
      | ntfVersion `isCompatible` ntfVRange ->
          pure (th :: THandle c) {thVersion = ntfVersion}
      | otherwise -> throwError $ TEHandshake VERSION

-- | Notifcations server client transport handshake.
ntfClientHandshake :: forall c. Transport c => c -> C.KeyHash -> VersionRange -> ExceptT TransportError IO (THandle c)
ntfClientHandshake c keyHash ntfVRange = do
  let th@THandle {sessionId} = ntfTHandle c
  NtfServerHandshake {sessionId = sessId, ntfVersionRange} <- getHandshake th
  if sessionId /= sessId
    then throwError TEBadSession
    else case ntfVersionRange `compatibleVersion` ntfVRange of
      Just (Compatible ntfVersion) -> do
        sendHandshake th $ NtfClientHandshake {ntfVersion, keyHash}
        pure (th :: THandle c) {thVersion = ntfVersion}
      Nothing -> throwError $ TEHandshake VERSION

ntfTHandle :: Transport c => c -> THandle c
ntfTHandle c = THandle {connection = c, sessionId = tlsUnique c, blockSize = ntfBlockSize, thVersion = 0, batch = False}
