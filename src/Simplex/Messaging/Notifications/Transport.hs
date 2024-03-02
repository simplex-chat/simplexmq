{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Notifications.Transport where

import Control.Monad (forM)
import Control.Monad.Except
import Data.Attoparsec.ByteString.Char8 (Parser)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.X509 as X
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Transport
import Simplex.Messaging.Version
import Simplex.Messaging.Util (liftEitherWith)

ntfBlockSize :: Int
ntfBlockSize = 512

authBatchCmdsNTFVersion :: Version
authBatchCmdsNTFVersion = 2

currentClientNTFVersion :: Version
currentClientNTFVersion = 1

currentServerNTFVersion :: Version
currentServerNTFVersion = 2

supportedClientNTFVRange :: VersionRange
supportedClientNTFVRange = mkVersionRange 1 currentClientNTFVersion

supportedServerNTFVRange :: VersionRange
supportedServerNTFVRange = mkVersionRange 1 currentServerNTFVersion

data NtfServerHandshake = NtfServerHandshake
  { ntfVersionRange :: VersionRange,
    sessionId :: SessionId,
    -- pub key to agree shared secrets for command authorization and entity ID encryption.
    authPubKey :: Maybe (X.SignedExact X.PubKey)
  }

data NtfClientHandshake = NtfClientHandshake
  { -- | agreed SMP notifications server protocol version
    ntfVersion :: Version,
    -- | server identity - CA certificate fingerprint
    keyHash :: C.KeyHash,
    -- pub key to agree shared secret for entity ID encryption, shared secret for command authorization is agreed using per-queue keys.
    authPubKey :: Maybe C.PublicKeyX25519
  }

instance Encoding NtfServerHandshake where
  smpEncode NtfServerHandshake {ntfVersionRange, sessionId, authPubKey} =
    B.concat
      [ smpEncode (ntfVersionRange, sessionId),
        encodeAuthEncryptCmds (maxVersion ntfVersionRange) $ C.SignedObject <$> authPubKey
      ]

  smpP = do
    (ntfVersionRange, sessionId) <- smpP
    -- TODO drop SMP v6: remove special parser and make key non-optional
    authPubKey <- authEncryptCmdsP (maxVersion ntfVersionRange) $ C.getSignedExact <$> smpP
    pure NtfServerHandshake {ntfVersionRange, sessionId, authPubKey}

encodeAuthEncryptCmds :: Encoding a => Version -> Maybe a -> ByteString
encodeAuthEncryptCmds v k
  | v >= authBatchCmdsNTFVersion = maybe "" smpEncode k
  | otherwise = ""

authEncryptCmdsP :: Version -> Parser a -> Parser (Maybe a)
authEncryptCmdsP v p = if v >= authBatchCmdsNTFVersion then Just <$> p else pure Nothing

instance Encoding NtfClientHandshake where
  smpEncode NtfClientHandshake {ntfVersion, keyHash, authPubKey} =
    smpEncode (ntfVersion, keyHash) <> encodeNtfAuthPubKey ntfVersion authPubKey
  smpP = do
    (ntfVersion, keyHash) <- smpP
    -- TODO drop SMP v6: remove special parser and make key non-optional
    authPubKey <- ntfAuthPubKeyP ntfVersion
    pure NtfClientHandshake {ntfVersion, keyHash, authPubKey}

ntfAuthPubKeyP :: Version -> Parser (Maybe C.PublicKeyX25519)
ntfAuthPubKeyP v = if v >= authBatchCmdsNTFVersion then Just <$> smpP else pure Nothing

encodeNtfAuthPubKey :: Version -> Maybe C.PublicKeyX25519 -> ByteString
encodeNtfAuthPubKey v k
  | v >= authBatchCmdsNTFVersion = maybe "" smpEncode k
  | otherwise = ""

-- | Notifcations server transport handshake.
ntfServerHandshake :: forall c. Transport c => C.APrivateSignKey -> c -> C.KeyPairX25519 -> C.KeyHash -> VersionRange -> ExceptT TransportError IO (THandle c)
ntfServerHandshake serverSignKey c (k, pk) kh ntfVRange = do
  let th@THandle {params = THandleParams {sessionId}} = ntfTHandle c
  let sk = C.signX509 serverSignKey $ C.publicToX509 k
  sendHandshake th $ NtfServerHandshake {sessionId, ntfVersionRange = ntfVRange, authPubKey = Just sk}
  getHandshake th >>= \case
    NtfClientHandshake {ntfVersion = v, keyHash, authPubKey = k'}
      | keyHash /= kh ->
          throwError $ TEHandshake IDENTITY
      | v `isCompatible` ntfVRange ->
          pure $ ntfThHandle th v pk k'
      | otherwise -> throwError $ TEHandshake VERSION

-- | Notifcations server client transport handshake.
ntfClientHandshake :: forall c. Transport c => c -> C.KeyPairX25519 -> C.KeyHash -> VersionRange -> ExceptT TransportError IO (THandle c)
ntfClientHandshake c (k, pk) keyHash ntfVRange = do
  let th@THandle {params = THandleParams {sessionId}} = ntfTHandle c
  NtfServerHandshake {sessionId = sessId, ntfVersionRange, authPubKey = sk'} <- getHandshake th
  if sessionId /= sessId
    then throwError TEBadSession
    else case ntfVersionRange `compatibleVersion` ntfVRange of
      Just (Compatible v) -> do
        sk_ <- forM sk' $ \exact -> liftEitherWith (const $ TEHandshake BAD_AUTH) $ do
          serverKey <- getServerVerifyKey c
          pubKey <- C.verifyX509 serverKey exact
          C.x509ToPublic (pubKey, []) >>= C.pubKey
        sendHandshake th $ NtfClientHandshake {ntfVersion = v, keyHash, authPubKey = Just k}
        pure $ ntfThHandle th v pk sk_
      Nothing -> throwError $ TEHandshake VERSION

ntfThHandle :: forall c. THandle c -> Version -> C.PrivateKeyX25519 -> Maybe C.PublicKeyX25519 -> THandle c
ntfThHandle th@THandle {params} v privKey k_ =
  -- TODO drop SMP v6: make thAuth non-optional
  let thAuth = (\k -> THandleAuth {peerPubKey = k, privKey}) <$> k_
      v3 = v >= authBatchCmdsNTFVersion
      params' = params {thVersion = v, thAuth, implySessId = v3, batch = v3}
   in (th :: THandle c) {params = params'}

ntfTHandle :: Transport c => c -> THandle c
ntfTHandle c = THandle {connection = c, params}
  where
    params = THandleParams {sessionId = tlsUnique c, blockSize = ntfBlockSize, thVersion = 0, thAuth = Nothing, implySessId = False, batch = False}
