# Service RPC implementation plan

RFC: [../rfcs/2026-07-11-service-rpc.md](../rfcs/2026-07-11-service-rpc.md)

Depends on: [2026-07-12-address-dr-implementation.md](2026-07-12-address-dr-implementation.md). RPC establishes the double ratchet from the address exactly as the address-DR plan does; this plan is the RPC layer on top of it. Steps named R2'/O2'/O3' below are from that plan. Constructor, event, table and function names are provisional.

**Scope of this pass: transport + rejection.** The request/response/rejection exchange and its teardown, plus communicated rejection of contact and RPC requests. Service-side **idempotency** (single execution by request hash) is **deferred** to a later pass; it stays documented below (the schema and the Idempotency section), marked deferred, but is not built now.

RPC is a one-directional short-lived DR exchange: the client establishes the ratchet from the address (address-DR requester), sends one request, receives one or more responses on its reply queue, and both sides tear the ratchet down after the final response. Unlike a connection, the service does not send a reply queue back and no persistent connection remains. A service publishes an ordinary DR-advertising contact address - the same address also accepts connection requests, and the owner distinguishes the two by the decrypted inner message (`AgentConnInfoReply` -> a connection, `AgentServiceRequest` -> an RPC).

## Versions

- `VersionSMPA` (agent protocol): the new inner `AgentServiceRequest`/`AgentServiceResponse`/`AgentRejection` messages, and the `AgentInvitationDR` -> `AgentContactRequest` rename. RPC reuses the address-DR ratchet establishment; `AgentInvitationDR` is unreleased (`currentSMPAgentVersion = 7`, Protocol.hs:339), so the rename and the new inner variants need no version gate beyond the address-DR work.

`SSND` (SMP protocol) and the hybrid queue header (SMP client) are not used here - they are separate RFCs (combined secure-send; queue-layer PQ). The ratchet provides post-quantum encryption, and the reply queue is secured with `SKEY` as in the address-DR owner path (O3').

## RPC messages

Two envelope layers, and it matters which is which (the L3/L4 layers of the address-DR plan). RPC and rejection add **no new outer envelope** - they reuse three existing ones; every new type is an **inner** `AgentMessage` variant, under the ratchet.

**Outer `AgentMsgEnvelope`** (L3, per-queue-e2e; encoding at Protocol.hs:874) - what an SMP queue carries:

- `AgentContactRequest` (renamed from `AgentInvitationDR`, tag `'A'`) - the request sent to the address queue, used for BOTH a contact invitation and an RPC request. Carries `e2eSndParams` (the requester's Snd X3DH parameters), `ratchetKeyId`, and `encConnInfo` (the ratchet-encrypted inner message). A contact invitation and an RPC request are byte-identical on the wire; they differ only in the inner message, which is under the ratchet and invisible to servers - the "same outside double ratchet" property. (`AgentInvitationDR` is unreleased, so the tag was changed freely from `'J'` to `'A'`.)
- `AgentConfirmation` (tag `'C'`, with `e2eEncryption_ = Nothing`) - the first response on the reply queue Q_A. It *confirms Q_A*: establishes Q_A's per-queue e2e and SKEY-secures it, exactly as the first message on any fresh receive queue. `encConnInfo` is the ratchet-encrypted inner message.
- `AgentMsgEnvelope` (tag `'M'`) - every later response on Q_A. `encAgentMessage` is the ratchet-encrypted inner message.

**Inner `AgentMessage`** (L4, double-ratchet-encrypted; encoding at Protocol.hs:921, parsed by `parseMessage`) - the decrypted content of the outer `encConnInfo`/`encAgentMessage`. RPC and rejection add three variants alongside `AgentConnInfoReply`:

```haskell
data AgentMessage
  = ... -- AgentConnInfo 'I', AgentConnInfoReply 'D' (contact invitation: reply queue Q_A + profile),
        --     AgentRatchetInfo 'R', AgentMessage APrivHeader AMessage 'M'
  | AgentServiceRequest (NonEmpty SMPQueueInfo) MsgBody        -- 'A': RPC request  - reply queue Q_A + opaque payload
  | AgentServiceResponse APrivHeader Bool (NonEmpty MsgBody)   -- 'P': RPC response - header + final flag + one or more payloads
  | AgentRejection APrivHeader ByteString                      -- 'J': refusal      - header + opaque reason (contact or RPC)

-- encoding (extends AgentMessage Encoding)
AgentServiceRequest qs body           -> smpEncode ('A', qs, Tail body)
AgentServiceResponse hdr final bodies -> smpEncode ('P', hdr, final, fmap Large bodies)
AgentRejection hdr reason             -> smpEncode ('J', hdr, Tail reason)
```

The owner tells a request apart by its inner variant after decryption: `AgentConnInfoReply` -> a contact request (`REQ`); `AgentServiceRequest` -> an RPC request (`SREQ`). `AgentServiceResponse`/`AgentRejection` are responses on Q_A, delivered to the client's waiting call or callback.

`AgentServiceResponse` carries an `APrivHeader` (`{sndMsgId, prevMsgHash}`, the same header as `AgentMessage 'M'`), so the response stream gets agent-level numbering and a previous-message-hash chain on top of the ratchet - a dropped or reordered response is caught by the chain, not only by the ratchet counters. One message still carries one or more payloads (`NonEmpty MsgBody`): responses known together in one message, responses over time in separate messages, each `final = False` until the last. `AgentServiceRequest` needs no header - a request is a single message. `AgentRejection` carries the header too, because a refusal can be the terminal message of a response stream (after zero or more `AgentServiceResponse`) and must chain with it; for a refused contact request it is the sole message on Q_A, with `sndMsgId = 1` and an empty previous hash.

The `AgentMsgEnvelope` receive path (`agentClientMsg`, Agent.hs:3289) today expects only `AgentMessage APrivHeader aMessage`; it is extended to accept `AgentServiceResponse` and `AgentRejection` for the stream after the first response.

## Ratchet establishment - reuse of the address-DR flow

Request (client), reusing the address-DR requester path (R2'/R3'):

- Retrieve link data, reconstruct and negotiate the advertised `RcvE2ERatchetParamsUri`, create the reply queue Q_A (messaging mode, subscribed), establish the send ratchet (`generateSndE2EParams`, `pqX3dhSnd`, `initSndRatchet`, `createSndRatchet`).
- Send `AgentContactRequest {e2eSndParams = sndParams, ratchetKeyId, encConnInfo = ratchetEncrypt(AgentServiceRequest (Q_A :| []) payload)}` to the address queue, unauthenticated (`agentCbEncryptOnce`) - the same outer envelope a contact invitation uses, with `AgentServiceRequest` inside instead of `AgentConnInfoReply`. The client connection is `RcvConnection` (Q_A) with the send ratchet.

Request (service), reusing the address-DR owner path (O1'/O2'):

- The DR-request handler (built as `smpInvitationDR`; renamed to the generic `smpContactRequest`, since it now serves both invitations and RPC) selects the private keys by `ratchetKeyId`, `pqX3dhRcv`, `initRcvRatchet`, and `rcDecrypt` of `encConnInfo`, which also gives the connection its send side. It branches on the decrypted inner message: `AgentConnInfoReply` -> the existing contact-request path (store the request, emit `REQ`); `AgentServiceRequest` -> the RPC path: create a `SndConnection` to Q_A (no Q_B, unidirectional) holding the ratchet and deliver `SREQ` to the bot. This is receive-time establishment on unauthenticated input - the abuse bound of the address-DR plan ("Receive-time establishment, state, and abuse") applies unchanged.

Response (service): send each response to Q_A under the ratchet. The first message to Q_A is `AgentConfirmation {e2eEncryption_ = Nothing, encConnInfo = ratchetEncrypt(AgentServiceResponse hdr final bodies)}` (per-queue e2e is unestablished on Q_A - it is the confirming first message), securing Q_A with `SKEY` using the service's own key (`agentSecureSndQueue`, Q_A is messaging mode); later messages are `AgentMsgEnvelope {encAgentMessage = ratchetEncrypt(AgentServiceResponse hdr …)}`. After the `final = True` message, delete the send connection and its ratchet.

Response (client): a message on Q_A (its `snd_service_requests` row marks it an RPC reply queue). The first is `AgentConfirmation … Nothing` and takes the address-DR `RcvConnection … Nothing` branch (R5'), extended to accept `AgentServiceResponse` and `AgentRejection`; later ones are `AgentMsgEnvelope` and take the standard message path, extended the same way. Each `agentRatchetDecrypt` advances the ratchet. The first response returns from the call; later responses go to the callback; an `AgentRejection` ends the exchange like a `final = True` response, surfacing the reason. On `final`, a rejection, the deadline, or `cancelServiceRequest`, delete Q_A (`DEL`) and the reply connection.

## Rejection

A rejection is the inner `AgentRejection` variant (above): a terminal message carrying an opaque reason, delivered to the requester's Q_A under the ratchet. The same variant refuses an RPC request and a contact request (which today is dropped silently).

- Delivery: `AgentRejection` is the inner message of an `AgentConfirmation` sent to Q_A - the confirming first message on Q_A, exactly like the first response, but terminal and carrying no reply queue (an acceptance sends `AgentConnInfoReply` with Q_B; a rejection sends `AgentRejection` with nothing). If a rejection instead follows some RPC responses, it is the inner message of an `AgentMsgEnvelope`, chained by its `APrivHeader`.
- Owner/service API: parameterize the current silent drop. `rejectContact` (Agent.hs:1606, today `deleteInvitation` only) gains an optional reason: `Nothing` -> silent drop (unchanged); `Just reason` -> the owner already holds the post-decrypt ratchet in the stored DR request, so it encrypts `AgentRejection` under that ratchet, sends it to Q_A as an `AgentConfirmation`, then deletes the request. Only DR requests can be refused this way (they hold the ratchet); a classic `AgentInvitation` request has no ratchet and can only be dropped. An RPC request is refused the same way from its reply connection (`rejectServiceRequest`).
- Requester side: `AgentRejection` on a contact reply queue surfaces as a rejection event to chat (which maps it to `XReject`/`XGrpReject`, communicating-rejection RFC); on an RPC reply queue it ends `sendServiceRequest` with the reason.

## Reply queue - the requester's DR connection

The reply queue is the address-DR requester connection: an `RcvConnection` whose receive queue is Q_A, with a ratchet. No `reply_kem_priv_key`/`reply_secret` columns (those were the queue-layer hybrid secret, not used here). A `snd_service_requests` row referencing this connection marks it an RPC reply queue for dispatch and cleanup; there is no new connection type.

## Database schema

One migration (`M20260712_service_rpc`), on top of the address-DR migration. SQLite shown, PostgreSQL mirrors it. Only `snd_service_requests` (client side) is built this pass; the three `rcv_service_*` tables belong to the deferred idempotency work, kept here so the schema stays in one place.

```sql
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
-- No separate service-address creation: a service publishes an ordinary DR-advertising contact address
-- (address-DR address creation with InitialKeys). The same address accepts both connections and RPC.

-- Sends one response message with one or more payloads (final = True ends the exchange). The first message
-- to the reply connection secures Q_A with SKEY; later ones use SEND. connId is the reply connection from SREQ.
sendServiceReply :: AgentClient -> ConnId -> Bool -> NonEmpty MsgBody -> AE ()

-- Refuses an RPC request with an opaque reason (AgentRejection to Q_A), terminal; deletes the reply connection.
rejectServiceRequest :: AgentClient -> ConnId -> ByteString -> AE ()

-- Refuses a contact request: Nothing = silent drop (unchanged behaviour); Just reason = AgentRejection to Q_A.
rejectContact :: AgentClient -> ConfirmationId -> Maybe ByteString -> AE ()
```

Key rotation and update use the address-DR `rotateRatchetKeys`/link-data update; address deletion is `deleteConnection`.

Client side (name resolution to a link is an existing API; the link must be a DR-advertising address):

```haskell
-- Establishes the ratchet from the address, creates the reply queue, sends the request, and waits for
-- the first response up to the deadline. The callback receives later responses while the process runs.
sendServiceRequest ::
  AgentClient -> UserId -> ConnShortLink 'CMContact -> UTCTime ->
  MsgBody -> (ServiceResponse -> IO ()) -> AE ServiceResponse

cancelServiceRequest :: AgentClient -> ConnId -> AE ()

data ServiceResponse
  = ServiceResponse {bodies :: NonEmpty MsgBody, final :: Bool}
  | ServiceRejected {reason :: ByteString}
```

The waiting call and the callback are held in an in-memory map in `AgentClient`, keyed by the reply queue connection, filled by the receive path; they do not survive a restart.

Service side event (`AEvent`, entity is the address connection):

```haskell
-- connId = the reply (SndConnection) to Q_A; the bot passes it to sendServiceReply / rejectServiceRequest.
-- MsgBody = the opaque request payload.
SREQ :: ConnId -> MsgBody -> AEvent AEConn
```

## Agent processing

Client side:

- `sendServiceRequest`: retrieve link data per request (proxied per config); establish the ratchet and create Q_A (address-DR R2'); write the `snd_service_requests` row; send the `AgentContactRequest` carrying `AgentServiceRequest` (proxied per config); wait on the in-memory sink for the first response until the deadline.
- Response processing in `processSMPTransmissions`: a message on a queue with a `snd_service_requests` row is a response; `agentRatchetDecrypt` (advancing the ratchet), parse `AgentServiceResponse`/`AgentRejection`, deliver to the waiting call or the callback. On `final`/rejection/deadline/cancel, delete Q_A and the reply connection.
- `cleanupManager`: delete `snd_service_requests` past the deadline and mark their reply connections deleted; the existing deleted-connections step sends `DEL`. After a restart every row is stale, so this removes reply queues left behind.

Service side:

- Address-queue dispatch: `smpContactRequest` (the renamed `smpInvitationDR`) decrypts `encConnInfo` and branches on the inner message - `AgentConnInfoReply` -> the contact-request path (`REQ`); `AgentServiceRequest` -> the RPC path.
- On `AgentServiceRequest`: establish the ratchet (address-DR O2'), create the `SndConnection` to Q_A, deliver `SREQ connId payload` to the bot (`connId` = the reply connection). No request-hash store this pass, so every request - including a repeat - reaches the bot as a fresh `SREQ` (single execution is the deferred idempotency work).
- `sendServiceReply`: send `AgentServiceResponse hdr final bodies` to Q_A under the ratchet (`SKEY`+`SEND` for the first message, `SEND` after); after `final = True`, delete the reply connection and its ratchet.
- `rejectServiceRequest`: send `AgentRejection hdr reason` to Q_A the same way, terminal; delete the reply connection.

Configuration (`AgentConfig`): default request deadline. (The retention period belongs to the deferred idempotency work.)

Errors reuse `AgentErrorType`.

## Idempotency (deferred)

**Deferred - not built this pass** (see the scope note); documented here for the follow-up. The service identifies a request by its hash and keeps, for the retention period (config, not in link data), the ordered response payloads (`rcv_service_responses`) and the reply connections under that hash (`rcv_service_reply_conns`). A repeat request (same payload, therefore same hash) establishes its own ratchet and reply connection and does not reach the bot: while pending it is added and receives the responses so far and each later one; after completion it receives the whole stored sequence. Responses are stored as plaintext and re-encrypted per reply connection because each request has its own ratchet. This gives single execution over at-least-once delivery, bounded by the retention period.

## Correlation and chat

A response is connected to its request by the reply queue (one request, one reply queue, one ratchet). The request hash is only the idempotency key. The application ID is content inside the request payload, used only by the application to make two requests equal or different; the agent does not read it.

Both ends are chat bots on the chat library, which serializes a service command into the request payload and deserializes the responses; the agent transports them and correlates by reply queue. The chat framework's `chatServiceCalls` correlation is not used.

## Tests

- Encoding roundtrips: `AgentServiceRequest`, `AgentServiceResponse` (one and several response bodies), `AgentRejection` in `AgentMessage`; the renamed `AgentContactRequest` (wire unchanged from `AgentInvitationDR`).
- End to end (on the address-DR machinery): a request with one response; several responses streamed to the callback; `pqEncryption` on (hybrid) and off (X448-only) per the advertised keys; the request payload never travels under per-queue-only encryption.
- Rejection: an RPC request refused with `rejectServiceRequest` ends `sendServiceRequest` with the reason; a contact request refused with `rejectContact (Just reason)` reaches the requester as a rejection, vs `Nothing` = silent drop; the same address accepts a connection and an RPC and can refuse either.
- Lifecycle: the reply connection and the service ratchet are deleted after `final` and after a rejection; deadline; cancellation; a restart deletes client reply queues.
- (Idempotency tests are part of the deferred idempotency pass.)

## Phases

1. Rename `AgentInvitationDR` -> `AgentContactRequest`; add inner `AgentServiceRequest`/`AgentServiceResponse`/`AgentRejection`; generic inner-message dispatch in `smpContactRequest`; `SREQ` event. Encoding roundtrip tests.
2. Client: `sendServiceRequest`, reply-queue reception and callback, `cancelServiceRequest`, `snd_service_requests` + cleanup. Service: `sendServiceReply`. End-to-end request/response tests.
3. Rejection: `rejectContact` optional reason, `rejectServiceRequest`, requester-side surfacing; rejection tests.

Later, separate pass: idempotency (the deferred schema + Idempotency section).
