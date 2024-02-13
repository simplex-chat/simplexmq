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

authEncryptCmdsNTFVersion :: Version
authEncryptCmdsNTFVersion = 2

currentClientNTFVersion :: Version
currentClientNTFVersion = 1

currentServerNTFVersion :: Version
currentServerNTFVersion = 1

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
    keyHash :: C.KeyHash
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
  | v >= authEncryptCmdsNTFVersion = maybe "" smpEncode k
  | otherwise = ""

authEncryptCmdsP :: Version -> Parser a -> Parser (Maybe a)
authEncryptCmdsP v p = if v >= authEncryptCmdsNTFVersion then Just <$> p else pure Nothing

instance Encoding NtfClientHandshake where
  smpEncode NtfClientHandshake {ntfVersion, keyHash} =
    smpEncode (ntfVersion, keyHash)
  smpP = do
    (ntfVersion, keyHash) <- smpP
    pure NtfClientHandshake {ntfVersion, keyHash}

ntfAuthPubKeyP :: Version -> Parser (Maybe C.PublicKeyX25519)
ntfAuthPubKeyP v = if v >= authEncryptCmdsNTFVersion then Just <$> smpP else pure Nothing

encodeNtfAuthPubKey :: Version -> Maybe C.PublicKeyX25519 -> ByteString
encodeNtfAuthPubKey v k
  | v >= authEncryptCmdsNTFVersion = maybe "" smpEncode k
  | otherwise = ""

-- | Notifcations server transport handshake.
ntfServerHandshake :: forall c. Transport c => C.APrivateSignKey -> c -> C.KeyPairX25519 -> C.KeyHash -> VersionRange -> ExceptT TransportError IO (THandle c 'TServer)
ntfServerHandshake serverSignKey c (k, pk) kh ntfVRange = do
  let th@THandle {params = THandleParams {sessionId}} = ntfTHandle c
  let sk = C.signX509 serverSignKey $ C.publicToX509 k
  sendHandshake th $ NtfServerHandshake {sessionId, ntfVersionRange = ntfVRange, authPubKey = Just sk}
  getHandshake th >>= \case
    NtfClientHandshake {ntfVersion = v, keyHash}
      | keyHash /= kh ->
          throwError $ TEHandshake IDENTITY
      | v `isCompatible` ntfVRange ->
          pure $ ntfThHandle th v (Just $ THServerAuth pk)
      | otherwise -> throwError $ TEHandshake VERSION

-- | Notifcations server client transport handshake.
ntfClientHandshake :: forall c. Transport c => c -> C.KeyHash -> VersionRange -> ExceptT TransportError IO (THandle c 'TClient)
ntfClientHandshake c keyHash ntfVRange = do
  let th@THandle {params = THandleParams {sessionId}} = ntfTHandle c
  NtfServerHandshake {sessionId = sessId, ntfVersionRange, authPubKey = sk'} <- getHandshake th
  if sessionId /= sessId
    then throwError TEBadSession
    else case ntfVersionRange `compatibleVersion` ntfVRange of
      Just (Compatible v) -> do
        k_ <- forM sk' $ \exact -> liftEitherWith (const $ TEHandshake BAD_AUTH) $ do
          serverKey <- getServerVerifyKey c
          pubKey <- C.verifyX509 serverKey exact
          C.x509ToPublic (pubKey, []) >>= C.pubKey
        sendHandshake th $ NtfClientHandshake {ntfVersion = v, keyHash}
        pure $ ntfThHandle th v (THClientAuth <$> k_)
      Nothing -> throwError $ TEHandshake VERSION

ntfThHandle :: forall c p. THandle c p -> Version -> Maybe (THandleAuth p) -> THandle c p
ntfThHandle th@THandle {params} v thAuth_ =
  -- TODO drop SMP v6: make thAuth non-optional
  let encrypt = v >= authEncryptCmdsNTFVersion
      thAuth = if encrypt then thAuth_ else Nothing
      params' = params {thVersion = v, thAuth, encrypt = v >= authEncryptCmdsNTFVersion}
   in (th :: THandle c p) {params = params'}

ntfTHandle :: Transport c => c -> THandle c p
ntfTHandle c = THandle {connection = c, params}
  where
    params = THandleParams {sessionId = tlsUnique c, blockSize = ntfBlockSize, thVersion = 0, thAuth = Nothing, encrypt = False, batch = False}
