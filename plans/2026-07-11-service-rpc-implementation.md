# Service RPC implementation plan

RFC: [../rfcs/2026-07-11-service-rpc.md](../rfcs/2026-07-11-service-rpc.md)

Depends on: [2026-07-12-address-dr-implementation.md](2026-07-12-address-dr-implementation.md). RPC establishes the double ratchet from the service address exactly as the address-DR plan does; this plan is the RPC layer on top of it. Steps named R2'/O2'/O3' below are from that plan. Constructor, event, table and function names are provisional.

RPC is a one-directional short-lived DR exchange: the client establishes the ratchet from the address (address-DR requester), sends one request, receives one or more responses on its reply queue, and both sides tear the ratchet down after the final response. Unlike a connection, the service does not send a reply queue back and no persistent connection remains.

## Versions

- `VersionSMPA` (agent protocol): the new `AgentServiceRequest`/`AgentServiceResponse` messages and the service address subtype. RPC requires the address-DR agent version, whose ratchet establishment it reuses.

`SSND` (SMP protocol) and the hybrid queue header (SMP client) are not used here - they are separate RFCs (combined secure-send; queue-layer PQ). The ratchet provides post-quantum encryption, and the reply queue is secured with `SKEY` as in the address-DR owner path (O3').

## Service address

A service address is a DR-advertising contact address (address-DR plan: `linkRatchetKey` in fixed data, `RatchetKeys` in mutable data) with a service subtype. There is no separate `ServiceKeyBundle` - requests are encrypted by establishing the ratchet against the advertised keys.

The subtype distinguishes RPC from a normal connection and drives the owner's handling. Reuse the `ContactConnType` char slot:

```haskell
data ContactConnType = CCTContact | CCTChannel | CCTGroup | CCTRelay | CCTService
ctTypeChar CCTService = 'S' -- 's' in links
ctTypeP 'S' = pure CCTService
```

Stored on the address receive queue as `link_contact_type` (NULL means the current contact type). A service address rejects `AgentInvitation` and connection `AgentConfirmation`; a non-service address rejects service requests.

## RPC messages

RPC adds two `AgentMessage` variants (Protocol.hs:883-889, parsed by `parseMessage`), parallel to `AgentConnInfoReply`, not new top-level envelopes. They are the decrypted content of the existing per-queue-e2e envelopes: the request is the `encConnInfo` of the address-DR `AgentConfirmation`; each response is the `encConnInfo` of an `AgentConfirmation` (first message to the reply queue) or the `encAgentMessage` of an `AgentMsgEnvelope` (later messages), all double-ratchet-encrypted. Their tags `Q`/`P` are the RFC's `agentRequest`/`agentResponse`.

```haskell
data AgentMessage
  = ... -- AgentConnInfo 'I', AgentConnInfoReply 'D', AgentRatchetInfo 'R', AgentMessage 'M'
  | AgentServiceRequest (NonEmpty SMPQueueInfo) MsgBody       -- 'Q': reply queue(s) + opaque request payload
  | AgentServiceResponse Bool (NonEmpty MsgBody)              -- 'P': final flag + one or more response payloads

-- encoding (extends AgentMessage Encoding)
AgentServiceRequest qs body -> smpEncode ('Q', qs, Tail body)
AgentServiceResponse final bodies -> smpEncode ('P', final) <> smpEncodeList (map Large (L.toList bodies))
```

One response message carries one or more response payloads, so responses known together are one message; responses over time are separate messages, each with `final = False` until the last. There is no signature and no previous-message hash: the ratchet, established against the `linkRatchetKey` committed by the link hash (address-DR authentication), authenticates each message and its message numbering detects dropping and reordering. The request payload is opaque application bytes (the chat command); the reply queue fields are outside it.

The request hash used for idempotency is `SHA3-256` of the decrypted request payload (the `MsgBody` in `AgentServiceRequest`).

The `AgentMsgEnvelope` receive path (`agentClientMsg`, Agent.hs:3289) today expects only `AgentMessage APrivHeader aMessage`; it is extended to accept `AgentServiceResponse` for the stream after the first response.

## Ratchet establishment - reuse of the address-DR flow

Request (client), reusing the address-DR requester path (R2'/R3'):

- Retrieve link data, reconstruct and negotiate the advertised `RcvE2ERatchetParamsUri`, create the reply queue Q_A (messaging mode, subscribed), establish the send ratchet (`generateSndE2EParams`, `pqX3dhSnd`, `initSndRatchet`, `createSndRatchet`).
- Send `AgentConfirmation {e2eEncryption_ = Just sndParams, ratchetKeyId = Just ratchetKeyId, encConnInfo = ratchetEncrypt(AgentServiceRequest (Q_A :| []) payload)}` to the address queue, unauthenticated (`agentCbEncryptOnce`). The client connection is `RcvConnection` (Q_A) with the send ratchet.

Request (service), reusing the address-DR owner path (O1'/O2'):

- `smpAddressConfirmation` selects the private keys by `ratchetKeyId`, `pqX3dhRcv`, `initRcvRatchet`, and `rcDecrypt` of `encConnInfo`, which also gives the connection its send side. The decrypted message is `AgentServiceRequest` (not `AgentConnInfoReply`), so the owner takes the RPC branch: create a `SndConnection` to Q_A (no Q_B, unidirectional) holding the ratchet, run idempotency (below), and either deliver `SREQ` or replay stored responses. This is receive-time establishment on unauthenticated input - the abuse bound of the address-DR plan ("Receive-time establishment, state, and abuse") applies unchanged.

Response (service): send each response to Q_A under the ratchet. The first message to Q_A is `AgentConfirmation {e2eEncryption_ = Nothing, encConnInfo = ratchetEncrypt(AgentServiceResponse final bodies)}` (per-queue e2e is unestablished on Q_A - the address-DR first-message constraint), securing Q_A with `SKEY` using the service's own key (`agentSecureSndQueue`, Q_A is messaging mode); later messages are `AgentMsgEnvelope {encAgentMessage = ratchetEncrypt(AgentServiceResponse …)}`. After the `final = True` message, delete the send connection and its ratchet.

Response (client): a message on Q_A (its `snd_service_requests` row marks it an RPC reply queue). The first is `AgentConfirmation … Nothing` and takes the address-DR `RcvConnection … Nothing` branch (R5'), extended to accept `AgentServiceResponse`; later ones are `AgentMsgEnvelope` and take the standard message path, extended to accept `AgentServiceResponse`. Each `agentRatchetDecrypt` advances the ratchet. The first response returns from the call; later responses go to the callback. On `final`, the deadline, or `cancelServiceRequest`, delete Q_A (`DEL`) and the reply connection.

## Reply queue - the requester's DR connection

The reply queue is the address-DR requester connection: an `RcvConnection` whose receive queue is Q_A, with a ratchet. No `reply_kem_priv_key`/`reply_secret` columns (those were the queue-layer hybrid secret, not used here). A `snd_service_requests` row referencing this connection marks it an RPC reply queue for dispatch and cleanup; there is no new connection type.

## Database schema

One migration (`M20260712_service_rpc`), on top of the address-DR migration. SQLite shown, PostgreSQL mirrors it.

```sql
-- service subtype on the address receive queue (address-DR adds the ratchet key columns)
ALTER TABLE rcv_queues ADD COLUMN link_contact_type TEXT; -- NULL = current contact type

-- client side: one pending request per reply queue connection.
CREATE TABLE snd_service_requests(
  snd_service_request_id INTEGER PRIMARY KEY AUTOINCREMENT,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE, -- reply queue (RcvConnection) with the ratchet
  deadline TEXT NOT NULL,
  created_at TEXT NOT NULL
);

-- service side: one record per distinct request hash on a service address.
CREATE TABLE rcv_service_requests(
  rcv_service_request_id INTEGER PRIMARY KEY AUTOINCREMENT,
  address_conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE, -- the service address connection
  request_hash BLOB NOT NULL,
  ended INTEGER NOT NULL DEFAULT 0, -- a response with final = True was produced
  expires_at TEXT NOT NULL, -- created + retention
  created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_rcv_service_requests ON rcv_service_requests(address_conn_id, request_hash);

-- service side: ordered response payloads (plaintext) for a request; re-encrypted per reply
-- connection because each request establishes its own ratchet, so ciphertext is not reusable.
CREATE TABLE rcv_service_responses(
  rcv_service_response_id INTEGER PRIMARY KEY AUTOINCREMENT,
  rcv_service_request_id INTEGER NOT NULL REFERENCES rcv_service_requests ON DELETE CASCADE,
  response_seq INTEGER NOT NULL,
  final INTEGER NOT NULL,
  response_bodies BLOB NOT NULL -- plaintext response payloads for this message (encoded NonEmpty MsgBody)
);
CREATE UNIQUE INDEX idx_rcv_service_responses ON rcv_service_responses(rcv_service_request_id, response_seq);

-- service side: reply connections subscribed under a request (the first, and any repeat while pending
-- or after completion). Each is a SndConnection to a reply queue with its own ratchet (in ratchets table).
CREATE TABLE rcv_service_reply_conns(
  rcv_service_reply_conn_id INTEGER PRIMARY KEY AUTOINCREMENT,
  rcv_service_request_id INTEGER NOT NULL REFERENCES rcv_service_requests ON DELETE CASCADE,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE, -- SndConnection to the reply queue, holds the ratchet
  last_sent_seq INTEGER NOT NULL DEFAULT 0
);
```

The service's address ratchet keys are the address-DR `address_ratchet_keys` table - not duplicated here.

## Agent API - `Simplex.Messaging.Agent`

Service side:

```haskell
-- Creates a DR-advertising contact address with CCTService subtype (address-DR createServiceAddress
-- plus the subtype), generating the link ratchet key and the first RatchetKeys row.
createServiceAddress :: AgentClient -> UserId -> UserLinkData -> AE (ConnId, ConnShortLink 'CMContact)

-- Sends one response message with one or more payloads (final = True ends the exchange). The first
-- message to each reply connection secures the reply queue with SKEY; later ones use SEND. Appends to
-- rcv_service_responses.
sendServiceReply :: AgentClient -> ServiceRequestRef -> Bool -> NonEmpty MsgBody -> AE ()
```

Key rotation and update use the address-DR `rotateRatchetKeys`/link-data update; address deletion is `deleteConnection`.

Client side (name resolution to a link is an existing API; the link must be a `CCTService` DR-advertising address):

```haskell
-- Establishes the ratchet from the address, creates the reply queue, sends the request, and waits for
-- the first response up to the deadline. The callback receives later responses while the process runs.
sendServiceRequest ::
  AgentClient -> UserId -> ConnShortLink 'CMContact -> UTCTime ->
  MsgBody -> (ServiceResponse -> IO ()) -> AE ServiceResponse

cancelServiceRequest :: AgentClient -> ConnId -> AE ()

data ServiceResponse = ServiceResponse {bodies :: NonEmpty MsgBody, final :: Bool}
```

The waiting call and the callback are held in an in-memory map in `AgentClient`, keyed by the reply queue connection, filled by the receive path; they do not survive a restart.

Service side event (`AEvent`, entity is the service address connection):

```haskell
SREQ :: ServiceRequestRef -> MsgBody -> AEvent AEConn -- request payload for the bot
```

`ServiceRequestRef` identifies the `rcv_service_requests` record; the bot passes it to `sendServiceReply`.

Rejection reuses `AgentRejection` (communicating-rejection RFC) as an `AgentServiceResponse`-level refusal or a dedicated variant - decided with that RFC.

## Agent processing

Client side:

- `sendServiceRequest`: retrieve link data per request (proxied per config); establish the ratchet and create Q_A (address-DR R2'); write the `snd_service_requests` row; send the `AgentServiceRequest` confirmation (proxied per config); wait on the in-memory sink for the first response until the deadline.
- Response processing in `processSMPTransmissions`: a message on a queue with a `snd_service_requests` row is a response; `agentRatchetDecrypt` (advancing the ratchet), parse `AgentServiceResponse`, deliver to the waiting call or the callback. On `final`/deadline/cancel, delete Q_A and the reply connection.
- `cleanupManager`: delete `snd_service_requests` past the deadline and mark their reply connections deleted; the existing deleted-connections step sends `DEL`. After a restart every row is stale, so this removes reply queues left behind.

Service side:

- Address-queue dispatch on `link_contact_type`: a service address routes `AgentConfirmation` with `ratchetKeyId` to the RPC handler (address-DR `smpAddressConfirmation` producing `AgentServiceRequest`); it rejects `AgentInvitation` and connection confirmations.
- On `AgentServiceRequest`: establish the ratchet (address-DR O2'), create the `SndConnection` to Q_A, compute the request hash, look up `rcv_service_requests` by (address conn, hash):
  - new: insert the request, insert a `rcv_service_reply_conns` row, deliver `SREQ` to the bot.
  - existing: insert a `rcv_service_reply_conns` row and send it every stored `rcv_service_responses` in order, each `AgentServiceResponse` re-encrypted under this connection's ratchet.
- `sendServiceReply`: append a `rcv_service_responses` row, then send `AgentServiceResponse` to every reply connection of the request under its ratchet (`SKEY`+`SEND` for the first message to a connection, `SEND` after); set `ended` on `final`.
- `cleanupManager`: delete `rcv_service_requests` past `expires_at` (cascading to responses and reply connections, and their ratchets/queues).

Configuration (`AgentConfig`): default request deadline, request retention period (1 to 24 hours). Ratchet key rotation interval is the address-DR config.

Errors reuse `AgentErrorType` (e.g. `CMD PROHIBITED` for a link that is not a service address).

## Idempotency

The service identifies a request by its hash and keeps, for the retention period (config, not in link data), the ordered response payloads (`rcv_service_responses`) and the reply connections under that hash (`rcv_service_reply_conns`). A repeat request (same payload, therefore same hash) establishes its own ratchet and reply connection and does not reach the bot: while pending it is added and receives the responses so far and each later one; after completion it receives the whole stored sequence. Responses are stored as plaintext and re-encrypted per reply connection because each request has its own ratchet. This gives single execution over at-least-once delivery, bounded by the retention period.

## Correlation and chat

A response is connected to its request by the reply queue (one request, one reply queue, one ratchet). The request hash is only the idempotency key. The application ID is content inside the request payload, used only by the application to make two requests equal or different; the agent does not read it.

Both ends are chat bots on the chat library, which serializes a service command into the request payload and deserializes the responses; the agent transports them and correlates by reply queue. The chat framework's `chatServiceCalls` correlation is not used.

## Tests

- Encoding roundtrips: `AgentServiceRequest`, `AgentServiceResponse` in `AgentMessage` (one and several response bodies); the service subtype in `UserContactData`/link.
- End to end (on the address-DR machinery): a request with one response; several responses streamed to the callback; `pqEncryption` on (hybrid) and off (X448-only) per the advertised keys; the request payload never travels under per-queue-only encryption.
- Idempotency: a repeat while pending coalesces onto the same operation; a repeat after completion receives the stored responses without a second `SREQ`; both under fresh ratchets.
- Lifecycle: the reply connection and the service ratchet are deleted after `final`; deadline; cancellation; a restart deletes client reply queues.
- Rejection and rejection of the wrong envelope on a service vs non-service address.

## Phases

1. Service address subtype and dispatch on top of the address-DR flow; `AgentServiceRequest`/`AgentServiceResponse` messages; `createServiceAddress`.
2. Client: `sendServiceRequest`, reply-queue reception and callback, cleanup.
3. Service: request store, `sendServiceReply`, idempotency (coalescing and repeats under fresh ratchets), end-to-end and idempotency tests.
