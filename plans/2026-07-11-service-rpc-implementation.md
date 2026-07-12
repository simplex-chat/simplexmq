# Service RPC implementation plan

RFC: [../rfcs/2026-07-11-service-rpc.md](../rfcs/2026-07-11-service-rpc.md)

Types and instances below must encode exactly the ABNF in the RFC. Constructor, event, table and function names are provisional.

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

The contact type is currently fixed to `CCTContact` when the agent reconstructs a contact link (`Agent.hs`, `cslContact`). It becomes a stored property of the address (column `link_contact_type` below), read when the link is reconstructed and when an address queue message is dispatched.

## Service key bundle in link data - `Simplex.Messaging.Agent.Protocol`

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

`UserContactData` gains a field, appended to the encoding, absent in data written by earlier versions. The agent sets it when it signs and updates link data; the application supplies only its own data. There is no retention value in link data - retention is service configuration (see Idempotency).

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

## SSND command - `Simplex.Messaging.Protocol`, `Simplex.Messaging.Server`

```haskell
-- Protocol.hs
SSND :: SndPublicAuthKey -> MsgFlags -> MsgBody -> Command Sender

-- CommandTag, encoding "SSND"
SSND_ :: CommandTag Sender

-- encodeProtocol
SSND k flags msg -> e (SSND_, ' ', k, ' ', flags, ' ', Tail msg)

-- protocolP, in a new VersionSMP
SSND_ -> SSND <$> (smpP <* A.space) <*> (smpP <* A.space) <*> (unTail <$> smpP)
```

`checkCredentials`: as `SKEY` - authorization required, sender entity ID. Server verification: `vc SSender (SSND k _ _) = verifySecure k` - authorized by the key it sets.

Server processing: `checkMode QMMessaging`, then `secureQueue_` (existing, idempotent), then deliver with deduplication. All queue store backends (STM, journal, PostgreSQL) keep the hash of the message delivered by `SSND` until it is acknowledged; a repeated `SSND` with an equal message hash responds `OK` without delivering it again; the hash is removed when the message is acknowledged. Server stats gain an `SSND` counter.

Proxying: `proxySMPCommand` is polymorphic in the sender command, so `SSND` forwards through `PFWD`/`RFWD` without changes.

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

The body is encrypted with `C.sbEncrypt` (secret_box) rather than `C.cbEncrypt`, padded to the same lengths. The sending side generates an ephemeral X25519 pair, encapsulates to the recipient KEM key, and writes `PubHeaderHybrid`. The receiving side selects private keys by `phKeyId` for a request, or uses the reply queue keys for a reply, and computes the same secret. A request with an unknown key ID is discarded and counted.

Size constants: the hybrid header adds about 1.2KB (KEM ciphertext 1039 bytes plus the ephemeral key). Define the request and reply body length constants from the existing padded body lengths at implementation.

## Agent envelopes - `Simplex.Messaging.Agent.Protocol`

```haskell
data AgentMsgEnvelope
  = ... -- existing constructors
  | AgentRequest
      { agentVersion :: VersionSMPA,
        replyQueue :: RequestReplyQueue,
        requestPayload :: ByteString -- opaque, hashed
      }
  | AgentResponse
      { agentVersion :: VersionSMPA,
        signature :: C.Signature 'C.Ed25519, -- root key signature of signedResponse
        signedResponse :: ByteString -- encoded SignedResponse, parsed after the signature is verified
      }

data RequestReplyQueue = RequestReplyQueue
  { smpClientVersion :: VersionSMPC,
    smpServer :: SMPServer,
    senderId :: SMP.SenderId, -- sender ID of the reply queue
    dhPublicKey :: C.PublicKeyX25519, -- reply queue X25519 key (its e2e key)
    kemPublicKey :: KEMPublicKey -- reply queue sntrup761 key
  }

data SignedResponse = SignedResponse
  { requestHash :: ByteString, -- SHA3-256 of requestPayload
    prevMsgHash :: ByteString, -- SHA3-256 of the previous AgentResponse, empty in the first
    more :: Bool, -- True if more reply messages follow
    responses :: NonEmpty ByteString -- opaque application responses
  }
```

The request does not include a key to secure the reply queue: the service generates its own sender key and secures the queue with `SSND`. `requestPayload` is the only hashed part; the reply queue fields are not hashed.

```haskell
instance Encoding AgentMsgEnvelope where
  smpEncode = \case
    ... -- existing constructors
    AgentRequest {agentVersion, replyQueue, requestPayload} ->
      smpEncode (agentVersion, 'Q', replyQueue, Tail requestPayload)
    AgentResponse {agentVersion, signature, signedResponse} ->
      smpEncode (agentVersion, 'P', signature, Tail signedResponse)
  smpP = do
    agentVersion <- smpP
    smpP >>= \case
      ... -- existing constructors
      'Q' -> do
        (replyQueue, Tail requestPayload) <- smpP
        pure AgentRequest {agentVersion, replyQueue, requestPayload}
      'P' -> do
        (signature, Tail signedResponse) <- smpP
        pure AgentResponse {agentVersion, signature, signedResponse}

instance Encoding RequestReplyQueue where
  smpEncode RequestReplyQueue {smpClientVersion, smpServer, senderId, dhPublicKey, kemPublicKey} =
    smpEncode (smpClientVersion, smpServer, senderId, dhPublicKey, kemPublicKey)
  smpP = do
    (smpClientVersion, smpServer, senderId, dhPublicKey, kemPublicKey) <- smpP
    pure RequestReplyQueue {smpClientVersion, smpServer, senderId, dhPublicKey, kemPublicKey}

instance Encoding SignedResponse where
  smpEncode SignedResponse {requestHash, prevMsgHash, more, responses} =
    smpEncode (requestHash, prevMsgHash, more) <> smpEncodeList (map Large $ L.toList responses)
  smpP = do
    (requestHash, prevMsgHash, more) <- smpP
    rs <- map unLarge <$> smpListP
    responses <- maybe (fail "empty responses") pure $ L.nonEmpty rs
    pure SignedResponse {requestHash, prevMsgHash, more, responses}
```

Signing and verification follow the link data pattern (`Simplex.Messaging.Crypto.ShortLink`):

```haskell
-- service: signing key is linkPrivSigKey from the address ShortLinkCreds
mkAgentResponse :: C.PrivateKeyEd25519 -> VersionSMPA -> SignedResponse -> AgentMsgEnvelope
mkAgentResponse rootPrivKey agentVersion resp =
  let signedResponse = smpEncode resp
   in AgentResponse {agentVersion, signature = C.sign' rootPrivKey signedResponse, signedResponse}

-- client: rootKey from the fixed link data
verifyAgentResponse :: C.PublicKeyEd25519 -> AgentMsgEnvelope -> Either AgentErrorType SignedResponse
verifyAgentResponse rootKey AgentResponse {signature, signedResponse}
  | C.verify' rootKey signature signedResponse = parse smpP (AGENT A_MESSAGE) signedResponse
  | otherwise = Left ... -- verification error
```

## Reply queue - no new connection type

The reply queue on the client is a receive connection (`RcvConnection`), extended to carry the KEM key and the computed hybrid secret. There is no new connection type and no flag on the connection: a client service request row (below) references the reply queue connection, and its presence identifies the connection as an RPC reply queue for dispatch and cleanup.

The reply queue reuses the existing receive queue fields. `e2ePrivKey` is its X25519 key, its public half is the queue address DH key sent in the request. Two nullable columns are added to `rcv_queues`:

- `reply_kem_priv_key` - the reply queue KEM private key.
- `reply_secret` - the hybrid secret, empty until the first reply, then set from the first reply's header, as the per-queue DH secret is set by `setRcvQueueConfirmedE2E` on the first message today. Later replies are decrypted with it by the standard receive path.

The service does not create a connection or queue for the reply queue. It sends replies directly to the reply queue address, as `sendInvitation` sends to a queue with no connection.

## Database schema - `Agent/Store/SQLite/Migrations`, `Agent/Store/Postgres/Migrations`

One migration (`M20260712_service_rpc`), SQLite shown, PostgreSQL mirrors it; column types follow existing schema conventions.

```sql
-- address contact type (contact address queues), and reply queue keys (reply queues).
-- NULL link_contact_type means 'A' (contact) for existing rows.
ALTER TABLE rcv_queues ADD COLUMN link_contact_type TEXT;
ALTER TABLE rcv_queues ADD COLUMN reply_kem_priv_key BLOB;
ALTER TABLE rcv_queues ADD COLUMN reply_secret BLOB;

-- service side: current and retired bundle private keys.
CREATE TABLE service_address_keys(
  service_address_key_id INTEGER PRIMARY KEY AUTOINCREMENT,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  key_id BLOB NOT NULL,
  dh_priv_key BLOB NOT NULL,
  kem_priv_key BLOB NOT NULL,
  created_at TEXT NOT NULL,
  retired_at TEXT -- set on rotation, row deleted when the key retention period ends
);
CREATE UNIQUE INDEX idx_service_address_keys ON service_address_keys(conn_id, key_id);

-- client side: one pending request per reply queue connection.
CREATE TABLE snd_service_requests(
  snd_service_request_id INTEGER PRIMARY KEY AUTOINCREMENT,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE, -- reply queue connection
  request_hash BLOB NOT NULL,
  root_key BLOB NOT NULL, -- to verify replies
  last_reply_hash BLOB, -- updated as reply messages arrive
  deadline TEXT NOT NULL,
  created_at TEXT NOT NULL
);

-- service side: one record per distinct request hash on an address.
CREATE TABLE rcv_service_requests(
  rcv_service_request_id INTEGER PRIMARY KEY AUTOINCREMENT,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE, -- address connection
  request_hash BLOB NOT NULL,
  ended INTEGER NOT NULL DEFAULT 0, -- a reply message with more = False was sent
  expires_at TEXT NOT NULL, -- created + retention
  created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_rcv_service_requests ON rcv_service_requests(conn_id, request_hash);

-- service side: ordered signed reply messages for a request; the signed envelope
-- is independent of the reply queue, so it is stored once and encrypted per queue on send.
CREATE TABLE rcv_service_replies(
  rcv_service_reply_id INTEGER PRIMARY KEY AUTOINCREMENT,
  rcv_service_request_id INTEGER NOT NULL REFERENCES rcv_service_requests ON DELETE CASCADE,
  reply_seq INTEGER NOT NULL,
  more INTEGER NOT NULL,
  signed_reply BLOB NOT NULL -- encoded AgentResponse
);
CREATE UNIQUE INDEX idx_rcv_service_replies ON rcv_service_replies(rcv_service_request_id, reply_seq);

-- service side: reply queues subscribed under a request (the first, and any repeat).
CREATE TABLE rcv_service_reply_queues(
  rcv_service_reply_queue_id INTEGER PRIMARY KEY AUTOINCREMENT,
  rcv_service_request_id INTEGER NOT NULL REFERENCES rcv_service_requests ON DELETE CASCADE,
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  snd_id BLOB NOT NULL,
  server_key_hash BLOB,
  reply_secret BLOB NOT NULL, -- hybrid secret to this reply queue
  secured INTEGER NOT NULL DEFAULT 0, -- reply queue secured with SSND
  last_sent_seq INTEGER NOT NULL DEFAULT 0
);
```

## Agent API - `Simplex.Messaging.Agent`

Service side:

```haskell
-- Creates a contact connection with CCTService link type, generates the root key
-- and the first key bundle, composes and signs link data.
createServiceAddress :: AgentClient -> UserId -> UserLinkData -> AE (ConnId, ConnShortLink 'CMContact)

-- Re-signs and updates user data with LSET, keeping the agent-owned key bundle.
updateServiceAddressData :: AgentClient -> ConnId -> UserLinkData -> AE ()

-- Generates a new bundle, updates link data, retires the previous keys until the retention period ends.
-- Also runs on a schedule (config) while the address is subscribed.
rotateServiceAddressKeys :: AgentClient -> ConnId -> AE ()

-- Sends one reply message with a list of responses; more = False ends the exchange.
-- The first message to each reply queue secures it with SSND; later messages use SEND.
sendServiceReply :: AgentClient -> ServiceRequestRef -> Bool -> NonEmpty ByteString -> AE ()
```

Address deletion: existing `deleteConnection`.

Client side (name resolution to a link is an existing API; the link must have `CCTService` type and a key bundle in link data):

```haskell
-- Retrieves link data, creates the reply queue, sends the request, and waits for the first
-- reply message up to the deadline. The callback receives later reply messages while the process runs.
sendServiceRequest ::
  AgentClient -> UserId -> ConnShortLink 'CMContact -> UTCTime ->
  ByteString -> (ServiceReply -> IO ()) -> AE ServiceReply

-- Deletes the reply queue and the request row, and drops the callback.
cancelServiceRequest :: AgentClient -> ConnId -> AE ()

data ServiceReply = ServiceReply {responses :: NonEmpty ByteString, more :: Bool}
```

The first reply message returns from `sendServiceRequest`; later messages are delivered through the callback. Both the waiting call and the callback are held in an in-memory map in `AgentClient`, keyed by the reply queue connection, and filled by the receive path. They do not survive a restart.

Service side events (`AEvent`, entity is the address connection):

```haskell
SREQ :: ServiceRequestRef -> ByteString -> AEvent AEConn -- request received, payload for the bot
```

`ServiceRequestRef` identifies the request record; the bot passes it to `sendServiceReply`.

## Agent processing - `Simplex.Messaging.Agent`, `Simplex.Messaging.Agent.Client`

Client side:

- `sendServiceRequest`: retrieve link data (`LGET`, proxied per config) for every request - no caching; create the reply queue (`NEW`, messaging mode, subscribed) with an added KEM key; write the `snd_service_requests` row; send the request (proxied per config); wait on the in-memory sink for the first reply until the deadline.
- Reply processing in `processSMPTransmissions`: a message on a receive queue that has a `snd_service_requests` row is a reply. Decrypt (the first message sets `reply_secret` from its header), verify with `verifyAgentResponse`, check the request hash and the previous-message hash, update `last_reply_hash`, deliver to the waiting call or the callback. A message that fails verification is acknowledged and discarded. On `more = False`, or on the deadline, or on `cancelServiceRequest`, delete the reply queue (`DEL`) and the row.
- `cleanupManager` gains one step: delete `snd_service_requests` past the deadline and mark their reply queue connections deleted; the existing deleted-connections step sends `DEL` and removes them. After a restart every row is stale, so this step removes all reply queues left behind.

Service side:

- Address queue message dispatch reads `link_contact_type`: a service address accepts only `AgentRequest` and rejects invitations and confirmations; a non-service address rejects `AgentRequest`.
- On `AgentRequest`: select bundle private keys by `keyId`, decrypt, compute the request hash. Look up `rcv_service_requests` by (address conn, hash):
  - new: insert the request, insert a `rcv_service_reply_queues` row for the reply queue in the request, deliver `SREQ` to the bot.
  - existing: insert a `rcv_service_reply_queues` row for the reply queue in this request, and send it every `rcv_service_replies` message already stored, in order.
- `sendServiceReply`: append a `rcv_service_replies` message (sign with the address root key), then send it to every reply queue of the request - `SSND` for a queue not yet secured, `SEND` after - encrypting the stored envelope to each queue's `reply_secret`; set `ended` when `more = False`.
- `cleanupManager` gains one step: delete `rcv_service_requests` past `expires_at` (cascading to replies and reply queues) and `service_address_keys` past the key retention period.

Configuration (`AgentConfig`): default request deadline, request retention period (1 to 24 hours), key rotation interval.

Errors: API failures reuse `AgentErrorType` (for example `CMD PROHIBITED` for a link that is not a service address). A new constructor is added only if the chat library needs to distinguish service request failures - decided at implementation.

## Correlation and chat

A reply is connected to its request by the reply queue: one request has one reply queue, and every message in that queue is a reply to that request. The request hash is used only in the reply signature, to bind a reply to the request content. The application ID is content inside `requestPayload`, used only by the application to make two requests equal or different; the agent does not read it.

Both ends are chat bots on the chat library. The chat library serializes a service command into `requestPayload` and deserializes the responses; the agent transports them and correlates by reply queue. The chat framework's `chatServiceCalls` correlation by `(AgentConnId, SharedMsgId)` is not used - the agent correlates by reply queue and the call returns the first reply directly.

## Tests

- Encoding roundtrips: envelopes, `ServiceKeyBundle` in `UserContactData`, `PubHeader` (all three variants), `SSND`, `SignedResponse` with one and several responses.
- Server: `SSND` on messaging and contact queues, repeated `SSND` before and after ACK, a different key, via proxy.
- Agent end-to-end: a request with one reply message; several responses in one message; responses in several messages delivered to the callback; a repeat request while pending coalesces onto the same operation; a repeat request after completion receives the stored messages without a second execution; key rotation with an old key still accepted while kept; a request whose key was deleted fails at the deadline; deadline; cancellation; a restart deletes reply queues; envelope rejection on both address types.

## Phases

1. SMP protocol: `SSND`, hybrid public header, version bumps, server dedup hash, server tests.
2. Agent: address type, key bundle in link data, envelopes, reply queue columns, schema migration, `createServiceAddress`, `sendServiceRequest`, reply processing, cleanup.
3. Agent: service-side request store, `sendServiceReply`, coalescing and repeats, key rotation, end-to-end tests.
4. Adoption: `SSND` in the fast connection handshake; the hybrid scheme for invitations and confirmations.
