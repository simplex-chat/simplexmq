{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Notifications.Transport
  ( NTFVersion,
    VersionRangeNTF,
    pattern VersionNTF,
    THandleNTF,
    supportedClientNTFVRange,
    supportedServerNTFVRange,
    alpnSupportedNTFHandshakes,
    ntfServerHandshake,
    ntfClientHandshake,
  ) where

import Control.Monad.Except
import Control.Monad.Trans.Except
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
initialNTFVersion = VersionNTF 3

_invalidReasonNTFVersion :: VersionNTF
_invalidReasonNTFVersion = VersionNTF 3

currentClientNTFVersion :: VersionNTF
currentClientNTFVersion = VersionNTF 3

currentServerNTFVersion :: VersionNTF
currentServerNTFVersion = VersionNTF 3

supportedClientNTFVRange :: VersionRangeNTF
supportedClientNTFVRange = mkVersionRange initialNTFVersion currentClientNTFVersion

supportedServerNTFVRange :: VersionRangeNTF
supportedServerNTFVRange = mkVersionRange initialNTFVersion currentServerNTFVersion

alpnSupportedNTFHandshakes :: [ALPN]
alpnSupportedNTFHandshakes = ["ntf/1"]

type THandleNTF c p = THandle NTFVersion c p

data NtfServerHandshake = NtfServerHandshake
  { ntfVersionRange :: VersionRangeNTF,
    sessionId :: SessionId,
    -- pub key to agree shared secrets for command authorization and entity ID encryption.
    authPubKey :: X.SignedExact X.PubKey
  }

data NtfClientHandshake = NtfClientHandshake
  { -- | agreed SMP notifications server protocol version
    ntfVersion :: VersionNTF,
    -- | server identity - CA certificate fingerprint
    keyHash :: C.KeyHash
  }

instance Encoding NtfServerHandshake where
  smpEncode NtfServerHandshake {ntfVersionRange, sessionId, authPubKey} =
    smpEncode (ntfVersionRange, sessionId, C.SignedObject authPubKey)

  smpP = do
    (ntfVersionRange, sessionId) <- smpP
    authPubKey <- C.getSignedExact <$> smpP
    pure NtfServerHandshake {ntfVersionRange, sessionId, authPubKey}

instance Encoding NtfClientHandshake where
  smpEncode NtfClientHandshake {ntfVersion, keyHash} =
    smpEncode (ntfVersion, keyHash)
  smpP = do
    (ntfVersion, keyHash) <- smpP
    pure NtfClientHandshake {ntfVersion, keyHash}

-- | Notifcations server transport handshake.
ntfServerHandshake :: forall c. Transport c => C.APrivateSignKey -> c 'TServer -> C.KeyPairX25519 -> C.KeyHash -> VersionRangeNTF -> ExceptT TransportError IO (THandleNTF c 'TServer)
ntfServerHandshake serverSignKey c (k, pk) kh ntfVersionRange = do
  let th@THandle {params = THandleParams {sessionId}} = ntfTHandle c
      authPubKey = C.signX509 serverSignKey $ C.publicToX509 k
  sendHandshake th $ NtfServerHandshake {sessionId, ntfVersionRange, authPubKey}
  getHandshake th >>= \case
    NtfClientHandshake {ntfVersion = v, keyHash}
      | keyHash /= kh ->
          throwE $ TEHandshake IDENTITY
      | otherwise ->
          case compatibleVRange' ntfVersionRange v of
            Just (Compatible vr) -> pure $ ntfThHandleServer th v vr pk
            Nothing -> throwE TEVersion

-- | Notifcations server client transport handshake.
ntfClientHandshake :: forall c. Transport c => c 'TClient -> C.KeyHash -> VersionRangeNTF -> Bool -> Maybe (ServiceCredentials, C.KeyPairEd25519) -> ExceptT TransportError IO (THandleNTF c 'TClient)
ntfClientHandshake c keyHash ntfVRange _proxyServer _serviceKeys = do
  let th@THandle {params = THandleParams {sessionId}} = ntfTHandle c
  NtfServerHandshake {sessionId = sessId, ntfVersionRange, authPubKey} <- getHandshake th
  if sessionId /= sessId
    then throwE TEBadSession
    else case ntfVersionRange `compatibleVRange` ntfVRange of
      Just (Compatible vr) -> do
        ck <- liftEitherWith (const $ TEHandshake BAD_AUTH) $ do
          serverKey <- getServerVerifyKey c
          pubKey <- C.verifyX509 serverKey authPubKey
          (,CertChainPubKey (getPeerCertChain c) authPubKey) <$> C.x509ToPublic' pubKey
        let v = maxVersion vr
        sendHandshake th $ NtfClientHandshake {ntfVersion = v, keyHash}
        pure $ ntfThHandleClient th v vr ck
      Nothing -> throwE TEVersion

ntfThHandleServer :: forall c. THandleNTF c 'TServer -> VersionNTF -> VersionRangeNTF -> C.PrivateKeyX25519 -> THandleNTF c 'TServer
ntfThHandleServer th v vr pk =
  let thAuth = THAuthServer {serverPrivKey = pk, peerClientService = Nothing, sessSecret' = Nothing}
   in ntfThHandle_ th v vr (Just thAuth)

ntfThHandleClient :: forall c. THandleNTF c 'TClient -> VersionNTF -> VersionRangeNTF -> (C.PublicKeyX25519, CertChainPubKey) -> THandleNTF c 'TClient
ntfThHandleClient th v vr ck_ =
  let thAuth = Just $ clientTHParams ck_
      clientTHParams (k, ck) = THAuthClient {peerServerPubKey = k, peerServerCertKey = ck, clientService = Nothing, sessSecret = Nothing}
   in ntfThHandle_ th v vr thAuth

ntfThHandle_ :: forall c p. THandleNTF c p -> VersionNTF -> VersionRangeNTF -> Maybe (THandleAuth p) -> THandleNTF c p
ntfThHandle_ th@THandle {params} v vr thAuth =
  -- TODO drop SMP v6: make thAuth non-optional
  let params' = params {thVersion = v, thServerVRange = vr, thAuth, batch = True}
   in (th :: THandleNTF c p) {params = params'}

ntfTHandle :: Transport c => c p -> THandleNTF c p
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
          encryptBlock = Nothing,
          batch = True,
          serviceAuth = False
        }
