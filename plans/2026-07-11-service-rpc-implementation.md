# Service RPC implementation plan

RFC: [../rfcs/2026-07-11-service-rpc.md](../rfcs/2026-07-11-service-rpc.md)

Types and instances below must encode exactly the ABNF in the RFC. Constructor and event names are provisional.

## Versions

- `VersionSMPA` (agent protocol): new version for `AgentRequest`/`AgentResponse` envelopes and the service key bundle in link data.
- `VersionSMPC` (SMP client): new version for the hybrid public header.
- `VersionSMP` (SMP protocol): new version for the `SSND` command.

## Address type - `Simplex.Messaging.Agent.Protocol`

```haskell
data ContactConnType = CCTContact | CCTChannel | CCTGroup | CCTRelay | CCTService

ctTypeChar CCTService = 'S' -- 's' in links: link encoding lowercases, parsing uppercases

ctTypeP 'S' = pure CCTService
```

## Service key bundle - `Simplex.Messaging.Agent.Protocol`

```haskell
data ServiceKeyBundle = ServiceKeyBundle
  { keyId :: ByteString,
    reqDhKey :: C.PublicKeyX25519,
    reqKemKey :: KEMPublicKey
  }

instance Encoding ServiceKeyBundle where
  smpEncode ServiceKeyBundle {keyId, reqDhKey, reqKemKey} = smpEncode (keyId, reqDhKey, reqKemKey)
  smpP = do
    (keyId, reqDhKey, reqKemKey) <- smpP
    pure ServiceKeyBundle {keyId, reqDhKey, reqKemKey}
```

`UserContactData` gains a field, appended to the encoding (earlier versions skip it, its absence parses as `Nothing`):

```haskell
data UserContactData = UserContactData
  { direct :: Bool,
    owners :: [OwnerAuth],
    relays :: [ConnShortLink 'CMContact],
    userData :: UserLinkData,
    serviceKeys :: Maybe ServiceKeyBundle
  }

instance Encoding UserContactData where
  smpEncode UserContactData {direct, owners, relays, userData, serviceKeys} =
    B.concat [smpEncode direct, smpEncodeList owners, smpEncodeList relays, smpEncode userData, smpEncode serviceKeys]
  smpP = do
    direct <- smpP
    owners <- smpListP
    relays <- smpListP
    userData <- smpP
    serviceKeys <- fromMaybe Nothing <$> optional smpP -- absent in data from earlier versions
    _ <- A.takeByteString -- ignoring tail for forward compatibility
    pure UserContactData {direct, owners, relays, userData, serviceKeys}
```

The service address record stores current and previous private key bundles with rotation timestamps; expired bundles are deleted.

## SSND command - `Simplex.Messaging.Protocol`, `Simplex.Messaging.Server`

```haskell
-- Protocol.hs
SSND :: SndPublicAuthKey -> MsgFlags -> MsgBody -> Command Sender

-- CommandTag, encoding "SSND"
SSND_ :: CommandTag Sender

-- encodeProtocol
SSND k flags msg -> e (SSND_, ' ', k, ' ', flags, ' ', Tail msg)

-- protocolP, gated by VersionSMP
SSND_ -> SSND <$> (smpP <* A.space) <*> (smpP <* A.space) <*> (unTail <$> smpP)
```

`checkCredentials`: as `SKEY` - authorization required, sender entity ID. Server verification: `vc SSender (SSND k _ _) = verifySecure k` - authorized by the key it sets.

Server processing: `checkMode QMMessaging`, then `secureQueue_` (existing, idempotent), then deliver with deduplication. The queue store keeps the hash of the unacknowledged message delivered by `SSND`; a repeated `SSND` with an equal body hash responds `OK` without storing; the hash is dropped when the message is acknowledged.

## Hybrid public header - `Simplex.Messaging.Protocol`

```haskell
data PubHeader
  = PubHeader
      { phVersion :: VersionSMPC,
        phE2ePubKey :: Maybe C.PublicKeyX25519
      }
  | PubHeaderHybrid
      { phVersion :: VersionSMPC,
        phKeyId :: Maybe ByteString, -- present in requests, absent in replies
        phDhKey :: C.PublicKeyX25519,
        phKemCt :: KEMCiphertext
      }

instance Encoding PubHeader where
  smpEncode = \case
    PubHeader v k_ -> smpEncode (v, k_) -- Maybe encodes as '0' / '1' key, as today
    PubHeaderHybrid v kId_ k ct -> smpEncode (v, '2', kId_, k, ct)
  smpP = do
    v <- smpP
    A.anyChar >>= \case
      '0' -> pure $ PubHeader v Nothing
      '1' -> PubHeader v . Just <$> smpP
      '2' -> PubHeaderHybrid v <$> smpP <*> smpP <*> smpP
      _ -> fail "bad PubHeader"
```

Secret derivation and encryption (`Simplex.Messaging.Crypto`, used from `Simplex.Messaging.Agent.Client`):

```haskell
hybridSecret :: C.DhSecretX25519 -> KEMSharedKey -> C.SbKey
hybridSecret dh (KEMSharedKey k) = C.unsafeSbKey $ C.hkdf "" (C.dhBytes' dh <> BA.convert k) "SimpleXSMPQueue" 32
```

The body is encrypted with `C.sbEncrypt` (secret_box) instead of `C.cbEncrypt`, padded to the same lengths. Sending variant of `agentCbEncryptOnce`: generate ephemeral X25519 pair, encapsulate to the published KEM key, encode `PubHeaderHybrid`. Receiving: select private keys by `phKeyId` (requests) or use the reply queue keys from the request (replies); unknown key ID produces the error that makes the client re-fetch link data.

## Agent envelopes - `Simplex.Messaging.Agent.Protocol`

```haskell
data AgentMsgEnvelope
  = ... -- existing constructors
  | AgentRequest
      { agentVersion :: VersionSMPA,
        replyQueue :: RequestReplyQueue,
        requestBody :: ByteString
      }
  | AgentResponse
      { agentVersion :: VersionSMPA,
        signature :: C.Signature 'C.Ed25519, -- root key signature of signedReply
        signedReply :: ByteString -- encoded SignedReply, parsed after signature verification
      }

data RequestReplyQueue = RequestReplyQueue
  { smpClientVersion :: VersionSMPC,
    smpServer :: SMPServer,
    senderId :: SMP.SenderId,
    dhPublicKey :: C.PublicKeyX25519, -- fresh per request
    kemPublicKey :: KEMPublicKey, -- fresh per request
    sndAuthKey :: SndPublicAuthKey -- to secure the reply queue
  }

data SignedReply = SignedReply
  { requestHash :: ByteString, -- SHA3-256 of the request message body
    prevMsgHash :: ByteString, -- SHA3-256 of the previous reply envelope, empty in the first reply
    final :: Bool,
    replyBody :: ByteString
  }
```

```haskell
instance Encoding AgentMsgEnvelope where
  smpEncode = \case
    ... -- existing constructors
    AgentRequest {agentVersion, replyQueue, requestBody} ->
      smpEncode (agentVersion, 'Q', replyQueue, Tail requestBody)
    AgentResponse {agentVersion, signature, signedReply} ->
      smpEncode (agentVersion, 'P', signature, Tail signedReply)
  smpP = do
    agentVersion <- smpP
    smpP >>= \case
      ... -- existing constructors
      'Q' -> do
        (replyQueue, Tail requestBody) <- smpP
        pure AgentRequest {agentVersion, replyQueue, requestBody}
      'P' -> do
        (signature, Tail signedReply) <- smpP
        pure AgentResponse {agentVersion, signature, signedReply}

instance Encoding RequestReplyQueue where
  smpEncode RequestReplyQueue {smpClientVersion, smpServer, senderId, dhPublicKey, kemPublicKey, sndAuthKey} =
    smpEncode (smpClientVersion, smpServer, senderId, dhPublicKey, kemPublicKey, sndAuthKey)
  smpP = do
    (smpClientVersion, smpServer, senderId, dhPublicKey, kemPublicKey, sndAuthKey) <- smpP
    pure RequestReplyQueue {smpClientVersion, smpServer, senderId, dhPublicKey, kemPublicKey, sndAuthKey}

instance Encoding SignedReply where
  smpEncode SignedReply {requestHash, prevMsgHash, final, replyBody} =
    smpEncode (requestHash, prevMsgHash, final, Tail replyBody)
  smpP = do
    (requestHash, prevMsgHash, final, Tail replyBody) <- smpP
    pure SignedReply {requestHash, prevMsgHash, final, replyBody}
```

Signing and verification follow the link data pattern (`Simplex.Messaging.Crypto.ShortLink`):

```haskell
-- service
mkAgentResponse :: C.PrivateKeyEd25519 -> VersionSMPA -> SignedReply -> AgentMsgEnvelope
mkAgentResponse rootPrivKey agentVersion reply =
  let signedReply = smpEncode reply
   in AgentResponse {agentVersion, signature = C.sign' rootPrivKey signedReply, signedReply}

-- client
verifyAgentResponse :: C.PublicKeyEd25519 -> AgentMsgEnvelope -> Either AgentErrorType SignedReply
verifyAgentResponse rootKey AgentResponse {signature, signedReply}
  | C.verify' rootKey signature signedReply = parse smpP (AGENT A_MESSAGE) signedReply
  | otherwise = Left ... -- verification error
```

## Agent processing - `Simplex.Messaging.Agent`, `Simplex.Messaging.Agent.Client`

Client side:

- `sendServiceRequest`: read link data (cached or `LGET`, proxied per config), create the reply queue (`NEW`, `QRMessaging`, subscribe), generate fresh X25519 + KEM keys and sender auth key, build and store the request message, send (proxied per config), return request ID.
- Retries re-send the stored byte-identical message. Deadline, cancellation and `final` delete the reply queue and the request record.
- Reply queue messages in `processSMPTransmissions`: decrypt with the stored hybrid secret (first reply establishes it from the hybrid header), verify with `verifyAgentResponse` and the hash chain, deliver as events; failures are acknowledged and dropped.
- New events: reply received (request ID, final flag, body), request failed (request ID, error).

Service side:

- Address queue messages with `AgentRequest`: compute request hash, look up the dedup store; on hit re-send stored replies (or the expiry error); on miss deliver a request event to the service application.
- Send replies: secure the reply queue and send the first reply with `SSND`, subsequent replies with `SEND`; store sent replies under the request hash until the window expires.

Database:

- Client: in-flight requests - request ID, stored request message, reply queue, hybrid secret, deadline, last reply hash.
- Service: dedup store - request hash, sent replies, expiry.

## Phases

1. SMP protocol: `SSND`, hybrid public header, version bumps, server dedup marker.
2. Agent: address type, key bundle, envelopes, client API and reply processing.
3. Agent: service-side dedup store and request events.
4. Adoption: `SSND` in the fast connection handshake; hybrid scheme for invitations and confirmations.
