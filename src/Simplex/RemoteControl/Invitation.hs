{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.RemoteControl.Invitation where

import Control.Monad (unless)
import qualified Data.Aeson as J
import Data.Aeson.TH (deriveJSON)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Time.Clock.System (SystemTime)
import Data.Word (Word16, Word32)
import Network.HTTP.Types (parseSimpleQuery)
import Network.HTTP.Types.URI (SimpleQuery, renderSimpleQuery, urlDecode)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.SNTRUP761.Bindings (KEMPublicKey)
import Simplex.Messaging.Encoding (Encoding (..))
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (defaultJSON)
import Simplex.Messaging.Transport.Client (TransportHost)
import Simplex.Messaging.Version (VersionRange, mkVersionRange)
import Simplex.RemoteControl.Types

data RCInvitation = RCInvitation
  { -- | CA TLS certificate fingerprint of the controller.
    --
    -- This is part of long term identity of the controller established during the first session, and repeated in the subsequent session announcements.
    ca :: C.KeyHash,
    host :: TransportHost,
    port :: Word16,
    -- | Supported version range for remote control protocol
    v :: VersionRange,
    -- | Application information
    app :: J.Value,
    -- | Session start time in seconds since epoch
    ts :: SystemTime,
    -- | Session Ed25519 public key used to verify the announcement and commands
    --
    -- This mitigates the compromise of the long term signature key, as the controller will have to sign each command with this key first.
    skey :: C.PublicKeyEd25519,
    -- | Long-term Ed25519 public key used to verify the announcement and commands.
    --
    -- Is apart of the long term controller identity.
    idkey :: C.PublicKeyEd25519,
    -- | SNTRUP761 encapsulation key
    kem :: KEMPublicKey,
    -- | Session X25519 DH key
    dh :: C.PublicKeyX25519
  }

instance StrEncoding RCInvitation where
  strEncode RCInvitation {ca, host, port, v, app, ts, skey, idkey, kem, dh} =
    mconcat
      [ "RC://",
        strEncode ca,
        "@",
        strEncode host,
        ":",
        strEncode port,
        "#/?",
        renderSimpleQuery False query
      ]
    where
      query =
        [ ("ca", strEncode ca),
          ("host", strEncode host),
          ("port", strEncode port),
          ("v", strEncode v),
          ("app", LB.toStrict $ J.encode app),
          ("ts", strEncode ts),
          ("skey", strEncode skey),
          ("idkey", strEncode idkey),
          ("kem", strEncode kem),
          ("dh", strEncode dh)
        ]

  strP = do
    _ <- A.string "RC://"
    ca <- strP
    _ <- A.char '@'
    host <- A.takeWhile (/= ':') >>= either fail pure . strDecode . urlDecode True
    _ <- A.char ':'
    port <- strP
    _ <- A.string "#/?"

    q <- parseSimpleQuery <$> A.takeWhile (/= ' ')
    v <- requiredP q "v" strDecode
    app <- requiredP q "app" $ J.eitherDecodeStrict . urlDecode True
    ts <- requiredP q "ts" $ strDecode . urlDecode True
    skey <- requiredP q "skey" strDecode
    idkey <- requiredP q "idkey" strDecode
    kem <- requiredP q "kem" strDecode
    dh <- requiredP q "dh" strDecode
    pure RCInvitation {ca, host, port, v, app, ts, skey, idkey, kem, dh}

data RCSignedInvitation = RCSignedInvitation
  { invitation :: RCInvitation,
    ssig :: C.Signature 'C.Ed25519,
    idsig :: C.Signature 'C.Ed25519
  }

-- | URL-encoded and signed for showing in QR code
instance StrEncoding RCSignedInvitation where
  strEncode RCSignedInvitation {invitation, ssig, idsig} =
    mconcat
      [ strEncode invitation,
        "&ssig=",
        strEncode ssig,
        "&idsig=",
        strEncode idsig
      ]

  strP = do
    (url, invitation) <- A.match strP
    sigs <- case B.breakSubstring "&ssig=" url of
      (_, sigs) | B.null sigs -> fail "missing signatures"
      (_, sigs) -> pure $ parseSimpleQuery $ B.drop 1 sigs
    ssig <- requiredP sigs "ssig" strDecode
    idsig <- requiredP sigs "idsig" strDecode
    pure RCSignedInvitation {invitation, ssig, idsig}

signInviteURL :: C.PrivateKey C.Ed25519 -> C.PrivateKey C.Ed25519 -> RCInvitation -> RCSignedInvitation
signInviteURL sKey idKey invitation = RCSignedInvitation {invitation, ssig, idsig}
  where
    inviteUrl = strEncode invitation
    ssig =
      case C.sign (C.APrivateSignKey C.SEd25519 sKey) inviteUrl of
        C.ASignature C.SEd25519 s -> s
        _ -> error "signing with ed25519"
    inviteUrlSigned = mconcat [inviteUrl, "&ssig=", strEncode ssig]
    idsig =
      case C.sign (C.APrivateSignKey C.SEd25519 idKey) inviteUrlSigned of
        C.ASignature C.SEd25519 s -> s
        _ -> error "signing with ed25519"

verifySignedInviteURL :: RCSignedInvitation -> Bool
verifySignedInviteURL RCSignedInvitation {invitation, ssig, idsig} =
  C.verify aSKey aSSig inviteURL && C.verify aIdKey aIdSig inviteURLS
  where
    RCInvitation {skey, idkey} = invitation
    inviteURL = strEncode invitation
    inviteURLS = mconcat [inviteURL, "&ssig=", strEncode ssig]
    aSKey = C.APublicVerifyKey C.SEd25519 skey
    aSSig = C.ASignature C.SEd25519 ssig
    aIdKey = C.APublicVerifyKey C.SEd25519 idkey
    aIdSig = C.ASignature C.SEd25519 idsig

verifySignedInvitationMulticast :: RCSignedInvitation -> Bool
verifySignedInvitationMulticast RCSignedInvitation {invitation, ssig, idsig} = undefined

data RCEncryptedInvitation = RCEncryptedInvitation
  { dhPubKey :: C.PublicKeyX25519,
    encryptedInvitation :: ByteString
  }

instance Encoding RCEncryptedInvitation where
  smpEncode RCEncryptedInvitation {dhPubKey, encryptedInvitation} =
    mconcat
      [ smpEncode dhPubKey,
        smpEncode @Word32 $ fromIntegral (B.length encryptedInvitation),
        encryptedInvitation
      ]
  smpP = do
    dhPubKey <- smpP
    len <- fromIntegral @Word32 <$> smpP
    encryptedInvitation <- A.take len
    pure RCEncryptedInvitation {dhPubKey, encryptedInvitation}

-- * Utils

sessionRCInvitation ::
  -- | App information
  J.Value ->
  -- | Long-term identity key
  C.PublicKeyEd25519 ->
  CtrlSessionKeys ->
  -- | Service address
  (TransportHost, Word16) ->
  RCInvitation
sessionRCInvitation app idkey CtrlSessionKeys {ts, ca, sSigKey, dhKey, kem} (host, port) =
  RCInvitation
    { ca,
      host,
      port,
      v = mkVersionRange 1 1,
      app,
      ts,
      skey = C.publicKey sSigKey,
      idkey,
      kem = fst kem,
      dh = C.publicKey dhKey
    }

requiredP :: MonadFail m => SimpleQuery -> ByteString -> (ByteString -> Either String a) -> m a
requiredP q k f = maybe (fail $ "missing " <> show k) (either fail pure . f) $ lookup k q

optionalP :: MonadFail m => SimpleQuery -> ByteString -> (ByteString -> Either String a) -> m (Maybe a)
optionalP q k f = maybe (pure Nothing) (either fail (pure . Just) . f) $ lookup k q

data SignatureError
  = BadSessionSignature
  | BadIdentitySignature
  deriving (Eq, Show)

$(deriveJSON defaultJSON ''RCInvitation)
