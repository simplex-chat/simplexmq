{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Notifications.Transport where

import Control.Monad (forM)
import Control.Monad.Except
import Control.Monad.Trans.Except
import Data.Attoparsec.ByteString.Char8 (Parser)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Word (Word16)
import qualified Data.X509 as X
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Transport
import Simplex.Messaging.Util (liftEitherWith)
import Simplex.Messaging.Version
import Simplex.Messaging.Version.Internal

ntfBlockSize :: Int
ntfBlockSize = 512

data NTFVersion

instance VersionScope NTFVersion

type VersionNTF = Version NTFVersion

type VersionRangeNTF = VersionRange NTFVersion

pattern VersionNTF :: Word16 -> VersionNTF
pattern VersionNTF v = Version v

initialNTFVersion :: VersionNTF
initialNTFVersion = VersionNTF 1

authBatchCmdsNTFVersion :: VersionNTF
authBatchCmdsNTFVersion = VersionNTF 2

currentClientNTFVersion :: VersionNTF
currentClientNTFVersion = VersionNTF 2

currentServerNTFVersion :: VersionNTF
currentServerNTFVersion = VersionNTF 2

supportedClientNTFVRange :: VersionRangeNTF
supportedClientNTFVRange = mkVersionRange initialNTFVersion currentClientNTFVersion

legacyServerNTFVRange :: VersionRangeNTF
legacyServerNTFVRange = mkVersionRange initialNTFVersion initialNTFVersion

supportedServerNTFVRange :: VersionRangeNTF
supportedServerNTFVRange = mkVersionRange initialNTFVersion currentServerNTFVersion

supportedNTFHandshakes :: [ALPN]
supportedNTFHandshakes = ["ntf/1"]

type THandleNTF c p = THandle NTFVersion c p

data NtfServerHandshake = NtfServerHandshake
  { ntfVersionRange :: VersionRangeNTF,
    sessionId :: SessionId,
    -- pub key to agree shared secrets for command authorization and entity ID encryption.
    authPubKey :: Maybe (X.SignedExact X.PubKey)
  }

data NtfClientHandshake = NtfClientHandshake
  { -- | agreed SMP notifications server protocol version
    ntfVersion :: VersionNTF,
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

encodeAuthEncryptCmds :: Encoding a => VersionNTF -> Maybe a -> ByteString
encodeAuthEncryptCmds v k
  | v >= authBatchCmdsNTFVersion = maybe "" smpEncode k
  | otherwise = ""

authEncryptCmdsP :: VersionNTF -> Parser a -> Parser (Maybe a)
authEncryptCmdsP v p = if v >= authBatchCmdsNTFVersion then Just <$> p else pure Nothing

instance Encoding NtfClientHandshake where
  smpEncode NtfClientHandshake {ntfVersion, keyHash} =
    smpEncode (ntfVersion, keyHash)
  smpP = do
    (ntfVersion, keyHash) <- smpP
    pure NtfClientHandshake {ntfVersion, keyHash}

-- | Notifcations server transport handshake.
ntfServerHandshake :: forall c. Transport c => C.APrivateSignKey -> c -> C.KeyPairX25519 -> C.KeyHash -> VersionRangeNTF -> ExceptT TransportError IO (THandleNTF c 'TServer)
ntfServerHandshake serverSignKey c (k, pk) kh ntfVRange = do
  let th@THandle {params = THandleParams {sessionId}} = ntfTHandle c
  let sk = C.signX509 serverSignKey $ C.publicToX509 k
  let ntfVersionRange = maybe legacyServerNTFVRange (const ntfVRange) $ getSessionALPN c
  sendHandshake th $ NtfServerHandshake {sessionId, ntfVersionRange, authPubKey = Just sk}
  getHandshake th >>= \case
    NtfClientHandshake {ntfVersion = v, keyHash}
      | keyHash /= kh ->
          throwE $ TEHandshake IDENTITY
      | otherwise ->
          case compatibleVRange' ntfVersionRange v of
            Just (Compatible vr) -> pure $ ntfThHandleServer th v vr pk
            Nothing -> throwE TEVersion

-- | Notifcations server client transport handshake.
ntfClientHandshake :: forall c. Transport c => c -> C.KeyHash -> VersionRangeNTF -> ExceptT TransportError IO (THandleNTF c 'TClient)
ntfClientHandshake c keyHash ntfVRange = do
  let th@THandle {params = THandleParams {sessionId}} = ntfTHandle c
  NtfServerHandshake {sessionId = sessId, ntfVersionRange, authPubKey = sk'} <- getHandshake th
  if sessionId /= sessId
    then throwE TEBadSession
    else case ntfVersionRange `compatibleVRange` ntfVRange of
      Just (Compatible vr) -> do
        ck_ <- forM sk' $ \signedKey -> liftEitherWith (const $ TEHandshake BAD_AUTH) $ do
          serverKey <- getServerVerifyKey c
          pubKey <- C.verifyX509 serverKey signedKey
          (,(getServerCerts c, signedKey)) <$> (C.x509ToPublic (pubKey, []) >>= C.pubKey)
        let v = maxVersion vr
        sendHandshake th $ NtfClientHandshake {ntfVersion = v, keyHash}
        pure $ ntfThHandleClient th v vr ck_
      Nothing -> throwE TEVersion

ntfThHandleServer :: forall c. THandleNTF c 'TServer -> VersionNTF -> VersionRangeNTF -> C.PrivateKeyX25519 -> THandleNTF c 'TServer
ntfThHandleServer th v vr pk =
  let thAuth = THAuthServer {serverPrivKey = pk, sessSecret' = Nothing}
   in ntfThHandle_ th v vr (Just thAuth)

ntfThHandleClient :: forall c. THandleNTF c 'TClient -> VersionNTF -> VersionRangeNTF -> Maybe (C.PublicKeyX25519, (X.CertificateChain, X.SignedExact X.PubKey)) -> THandleNTF c 'TClient
ntfThHandleClient th v vr ck_ =
  let thAuth = (\(k, ck) -> THAuthClient {serverPeerPubKey = k, serverCertKey = ck, sessSecret = Nothing}) <$> ck_
   in ntfThHandle_ th v vr thAuth

ntfThHandle_ :: forall c p. THandleNTF c p -> VersionNTF -> VersionRangeNTF -> Maybe (THandleAuth p) -> THandleNTF c p
ntfThHandle_ th@THandle {params} v vr thAuth =
  -- TODO drop SMP v6: make thAuth non-optional
  let v3 = v >= authBatchCmdsNTFVersion
      params' = params {thVersion = v, thServerVRange = vr, thAuth, implySessId = v3, batch = v3}
   in (th :: THandleNTF c p) {params = params'}

ntfTHandle :: Transport c => c -> THandleNTF c p
ntfTHandle c = THandle {connection = c, params}
  where
    v = VersionNTF 0
    params =
      THandleParams
        { sessionId = tlsUnique c,
          blockSize = ntfBlockSize,
          thVersion = v,
          thServerVRange = versionToRange v,
          thAuth = Nothing,
          implySessId = False,
          batch = False
        }
