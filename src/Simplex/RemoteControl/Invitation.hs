{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.RemoteControl.Invitation
  ( RCInvitation (..)
  , signInvitation
  , RCSignedInvitation (..)
  , verifySignedInvitation
  , RCVerifiedInvitation (..)
  , RCEncInvitation (..)
  ) where

import qualified Data.Aeson as J
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Time.Clock.System (SystemTime)
import Data.Word (Word16)
import Network.HTTP.Types (parseSimpleQuery)
import Network.HTTP.Types.URI (SimpleQuery, renderSimpleQuery, urlDecode)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Transport.Client (TransportHost)
import Simplex.Messaging.Version (VersionRange)

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
    -- | Session X25519 DH key
    dh :: C.PublicKeyX25519
  }
  deriving (Show)

instance StrEncoding RCInvitation where
  strEncode RCInvitation {ca, host, port, v, app, ts, skey, idkey, dh} =
    mconcat
      [ "xrcp:/",
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
        [ ("v", strEncode v),
          ("app", LB.toStrict $ J.encode app),
          ("ts", strEncode ts),
          ("skey", strEncode skey),
          ("idkey", strEncode idkey),
          ("dh", strEncode dh)
        ]

  strP = do
    _ <- A.string "xrcp:/"
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
    skey <- requiredP q "skey" $ parseAll strP
    idkey <- requiredP q "idkey" $ parseAll strP
    dh <- requiredP q "dh" $ parseAll strP
    pure RCInvitation {ca, host, port, v, app, ts, skey, idkey, dh}

data RCSignedInvitation = RCSignedInvitation
  { invitation :: RCInvitation,
    ssig :: C.Signature 'C.Ed25519,
    idsig :: C.Signature 'C.Ed25519
  }
  deriving (Show)

-- | URL-encoded and signed for showing in QR code
instance StrEncoding RCSignedInvitation where
  strEncode RCSignedInvitation {invitation, ssig, idsig} =
    mconcat
      [ strEncode invitation,
        "&ssig=",
        strEncode $ C.signatureBytes ssig,
        "&idsig=",
        strEncode $ C.signatureBytes idsig
      ]

  strP = do
    -- TODO this assumes some order or parameters, can be made independent
    (url, invitation) <- A.match strP
    sigs <- case B.breakSubstring "&ssig=" url of
      (_, sigs) | B.null sigs -> fail "missing signatures"
      (_, sigs) -> pure $ parseSimpleQuery $ B.drop 1 sigs
    ssig <- requiredP sigs "ssig" $ parseAll strP
    idsig <- requiredP sigs "idsig" $ parseAll strP
    pure RCSignedInvitation {invitation, ssig, idsig}

signInvitation :: C.PrivateKey C.Ed25519 -> C.PrivateKey C.Ed25519 -> RCInvitation -> RCSignedInvitation
signInvitation sKey idKey invitation = RCSignedInvitation {invitation, ssig, idsig}
  where
    uri = strEncode invitation
    ssig =
      case C.sign (C.APrivateSignKey C.SEd25519 sKey) uri of
        C.ASignature C.SEd25519 s -> s
        _ -> error "signing with ed25519"
    inviteUrlSigned = mconcat [uri, "&ssig=", strEncode ssig]
    idsig =
      case C.sign (C.APrivateSignKey C.SEd25519 idKey) inviteUrlSigned of
        C.ASignature C.SEd25519 s -> s
        _ -> error "signing with ed25519"

newtype RCVerifiedInvitation = RCVerifiedInvitation RCInvitation
  deriving (Show)

verifySignedInvitation :: RCSignedInvitation -> Maybe RCVerifiedInvitation
verifySignedInvitation RCSignedInvitation {invitation, ssig, idsig} =
  if C.verify' skey ssig inviteURL && C.verify' idkey idsig inviteURLS
    then Just $ RCVerifiedInvitation invitation
    else Nothing
  where
    RCInvitation {skey, idkey} = invitation
    inviteURL = strEncode invitation
    inviteURLS = mconcat [inviteURL, "&ssig=", strEncode ssig]

data RCEncInvitation = RCEncInvitation
  { dhPubKey :: C.PublicKeyX25519,
    nonce :: C.CbNonce,
    encInvitation :: ByteString
  }

instance Encoding RCEncInvitation where
  smpEncode RCEncInvitation {dhPubKey, nonce, encInvitation} =
    smpEncode (dhPubKey, nonce, Tail encInvitation)
  smpP = do
    (dhPubKey, nonce, Tail encInvitation) <- smpP
    pure RCEncInvitation {dhPubKey, nonce, encInvitation}

-- * Utils

requiredP :: MonadFail m => SimpleQuery -> ByteString -> (ByteString -> Either String a) -> m a
requiredP q k f = maybe (fail $ "missing " <> show k) (either fail pure . f) $ lookup k q
