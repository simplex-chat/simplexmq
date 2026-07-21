# Service RPC implementation plan

RFC: [../rfcs/2026-07-11-service-rpc.md](../rfcs/2026-07-11-service-rpc.md)

Depends on: [2026-07-12-address-dr-implementation.md](2026-07-12-address-dr-implementation.md). RPC establishes the double ratchet from the address exactly as the address-DR plan does; this is the RPC layer on top of it. Steps named R2'/R5'/O2'/O3' are from that plan.

**Status: transport + rejection implemented and tested** (this repo). Service-side **idempotency** (single execution by request hash) is deferred. The `simplex-chat` integration (`RJCT` -> `XReject`/`XGrpReject`, bot consumption of `SREQ`) is a separate repo.

**Scope.** One request, **one** response - no continuation, no streaming.

**HTTP vs WebSocket.** RPC is the HTTP-shaped path: a single request and a single response, no persistent connection. A contact request is the WebSocket-shaped path: it opens a connection over which both sides then exchange messages. One DR-advertising address serves both, and the owner decides which per incoming request from the decrypted inner message - `AgentConnInfoReply` opens a connection, `AgentServiceRequest` answers an RPC. This is the HTTP-shaped path (the WebSocket-shaped path is the existing contact/connection flow).

**Single-response shape.** A request gets exactly one reply, either a response or a rejection; no follow-up messages, no `final` flag, no callback, one payload per reply. So a response and a rejection are the *same operation*: each is the single confirming message on the requester's reply queue Q_A, after which the ephemeral reply connection is torn down. They differ only in the inner message (`AgentServiceResponse` payload vs `AgentRejection` reason) and the requester's outcome (the call returns the payload vs throws an agent error). The reply path is the rejection path, parameterized by the inner message.

**No parallel flow.** On the receive side an RPC request and a contact invitation are the same message stored the same way - one `smpContactRequest` (renamed from `smpInvitationDR`) writes one `conn_invitations` row, differing only in a kind column (`is_service_request`) and the event (`REQ` vs `SREQ`). The kind makes the APIs exclusive: an invitation is only accepted, a request only responded to / rejected; the wrong API on the wrong kind is `CMD PROHIBITED`. The reply/reject send is the shared secure -> deliver-one-confirmation -> delete-with-wait-delivery path (`prepareReply` + `sendReplySync`/`sendReplyAsync`, the latter via the `ICReplyDel` internal command, renamed from `ICReject`).

## RPC messages

**No new outer envelope.** The request reuses `AgentContactRequest` (tag `'A'`, renamed from `AgentInvitationDR`); the one reply reuses `AgentConfirmation` (the confirming first message on Q_A - the only message, so never `AgentMsgEnvelope`).

**Inner `AgentMessage`** (L4, ratchet-encrypted; parsed by `parseMessage`) - three headerless variants, siblings of `AgentConnInfoReply`:

```haskell
data AgentMessage
  = ... -- AgentConnInfo 'I', AgentConnInfoReply 'D' (reply queue Q_A + profile), AgentMessage APrivHeader AMessage 'M', ...
  | AgentServiceRequest (NonEmpty SMPQueueInfo) MsgBody  -- 'A': request  - reply queue Q_A + opaque payload
  | AgentServiceResponse MsgBody                         -- 'P': response - opaque payload (single, terminal)
  | AgentRejection ByteString                            -- 'J': refusal  - opaque reason (single, terminal)

AgentServiceRequest qs body -> smpEncode ('A', qs, Tail body)
AgentServiceResponse body   -> smpEncode ('P', Tail body)
AgentRejection reason       -> smpEncode ('J', Tail reason)
```

`AgentServiceRequest` carries Q_A (as `AgentConnInfoReply` does) so the service knows where to reply; its constructor is the only thing that tells `REQ` from `SREQ`. `AgentServiceResponse`/`AgentRejection` are each the sole message on Q_A - no header, no `final`, no `NonEmpty`. `AgentMessageType` `AM_SRV_REQ`/`AM_SRV_RESP`/`AM_RJCT`: **`AM_SRV_RESP` and `AM_RJCT` both route to `sendConfirmation`** in the delivery worker (the reply is always the confirming first message on Q_A); there is no later-message path for RPC, so `agentClientMsg` is unchanged.

## Ratchet establishment - reuse of the address-DR flow

**Request (client)** - address-DR requester path, inner is `AgentServiceRequest`. The client send reuses `joinConnSrv`, parameterized **in place**: `joinConnSrv'` takes an `mkInner :: SMPQueueInfo -> AgentMessage` and only the `sndReply` line changed; `joinConnSrv = joinConnSrv' … (\rq -> AgentConnInfoReply (rq :| []) cInfo)` is the one-line wrapper, so existing call sites are unchanged. `sendServiceRequest` calls `joinConnSrv' … (\rq -> AgentServiceRequest (rq :| []) payload)`.

- Negotiate the advertised ratchet params, create Q_A (messaging mode, subscribed), establish the send ratchet, send `AgentContactRequest {e2eSndParams, ratchetKeyId, encConnInfo = ratchetEncrypt(AgentServiceRequest (Q_A :| []) payload)}` to the address, unauthenticated. The client connection is `RcvConnection` (Q_A) with the send ratchet; its `created_at` is set (`setConnServiceReply`) to mark it a reply queue for cleanup and for the `serviceReply` flag.

**Request (service)** - `smpContactRequest` (renamed `smpInvitationDR`): decrypt `encConnInfo`, then branch on the inner message. **Both branches call the same `storeInvitation` -> `conn_invitations`**, writing the kind column; they differ only in the event:

- `AgentConnInfoReply` -> `REQ invId ...` (`is_service_request = 0`, unchanged).
- `AgentServiceRequest _ payload` -> `SREQ invId payload` (`is_service_request = 1`).

The service holds the request as an invitation with the payload as `recipient_conn_info`; no connection yet. Receive-time establishment on unauthenticated input - the address-DR abuse bound applies.

**The one reply (service)** - `sendServiceReply c nm userId invId payload` (accept-and-tear-down; the rejection path with a payload). `CMD PROHIBITED` if the invitation is a contact invitation (wrong kind), or `A_SERVICE ASETimeout` (+ delete the invitation) if it is older than `serviceReplyTimeout`; a repeat on an answered request just fails to find a pending record:

- `newConnToAccept` creates the ephemeral reply connection; `startJoinInvitationDR` builds the `SndQueue` to Q_A and the ratchet - **no reply queue back** (one-directional; the divergence from `acceptContact'`).
- `storeConfirmation` the pending `AgentServiceResponse payload` (`AM_SRV_RESP`); `acceptInvitation`; then secure Q_A + deliver + `deleteConnectionAsync' True` (`sendReplySync`). Async `sendServiceReplyAsync` defers secure+deliver+delete to `ICReplyDel` (`sendReplyAsync`, retried, never fails client-side, survives a down server). Returns `()`.

**The one response (client)** - the single `AgentConfirmation` on Q_A -> `smpConfirmation`'s `RcvConnection … Nothing` branch (already parsing `AgentConnInfoReply`/`AgentRejection`), extended, gated on the connection's `serviceReply` flag: `AgentServiceResponse payload` -> the request's `TMVar` gets `Right payload`; `AgentRejection reason` -> `Left (AGENT (A_SERVICE (ASERejected reason)))`; if `serviceReply` is set but there is no `TMVar` (post-restart), an `ERR (AGENT (A_SERVICE ASENoRequest))` event; if `serviceReply` is not set, `AgentRejection` is a contact rejection -> `RJCT`. The waiting `sendServiceRequest` unwraps the `TMVar` and tears Q_A down (`deleteConnectionAsync' True`). No later-message path.

## Rejection

A rejection is `AgentRejection reason` - the same single confirming message on Q_A as a response, always tearing the connection down. It refuses an RPC request and, unchanged, a contact request.

- **Kind guard** (`prepareReply`): `rejectContact` only on a contact invitation, `rejectServiceRequest`/`sendServiceReply` only on a request; the wrong kind is `CMD PROHIBITED`. An accepted/responded request is not pending (`getInvitation` filters `accepted = 0`), so the reject fails to find it, as a repeat should.
- `rejectContact`/`rejectContactAsync` / `rejectServiceRequest`/`rejectServiceRequestAsync` take `Maybe ByteString`: `Nothing` -> silent drop (delete the invitation, no message); `Just reason` -> `CMD PROHIBITED` on a classic `CRInvitation` (no ratchet) or the wrong kind; else the reply path with `AgentRejection` as the inner message.
- Requester side: `AgentRejection` on a contact reply queue -> `RJCT` event to chat (async, mapped to `XReject`/`XGrpReject`); on an RPC reply queue -> a thrown `A_SERVICE (ASERejected reason)` ending `sendServiceRequest` (synchronous).

## Reply connections and cleanup

No reply-queue table and no new connection type - both reply connections are ordinary connections with a ratchet.

- **The `serviceReply` flag** is on `ConnData`, loaded by `getConnData` as `created_at IS NOT NULL`; `connections.created_at` is non-null only on a client RPC reply queue (set by `sendServiceRequest`).
- **Client reply queue** (`RcvConnection` on Q_A): routed by the in-memory `serviceRequests :: TMap ConnId (TMVar (Either AgentErrorType MsgBody))` in `AgentClient` - `sendServiceRequest` inserts a one-shot, the receive path fills it. The normal path tears the queue down within the call; only a client restart mid-call orphans it, reaped by `created_at` age.
- **Service reply connection** (`SndConnection` to Q_A): ephemeral - created, sends the one reply, deleted with wait-for-delivery in the same operation.
- **Cleanup** (`cleanupManager`, one added step, using `serviceReplyTimeout` as the TTL): `deleteExpiredServiceRequests` reaps unanswered `conn_invitations` (kind = request) by `created_at`; `getExpiredServiceReplyConnIds` -> `deleteConnectionsAsync'` reaps orphaned client reply queues (`connections.created_at` non-null, not deleted, past the TTL).

## Database schema

Combined into the address-DR migration - `M20260712_address_dr_rpc` (SQLite + PostgreSQL) creates `address_ratchet_keys` (address-DR) and adds the two RPC columns:

```sql
-- ... address_ratchet_keys table + index (address-DR) ...
ALTER TABLE conn_invitations ADD COLUMN is_service_request INTEGER NOT NULL DEFAULT 0; -- 1 = RPC request, 0 = contact invitation
ALTER TABLE connections ADD COLUMN created_at TEXT;  -- non-null on a client RPC reply queue; marker + cleanup age (nullable)
```

The down migration drops the columns then the table/index. Schema dump tests pass (up, down, STRICT). The deferred idempotency work will add its own tables when built.

## Agent API - `Simplex.Messaging.Agent`

Service side (a service publishes an ordinary DR-advertising contact address; the same address accepts both connections and RPC):

```haskell
-- Sends the one response to the request from SREQ's invitation id, then tears the reply connection down.
sendServiceReply      :: AgentClient -> NetworkRequestMode -> UserId -> InvitationId -> MsgBody -> AE ()
sendServiceReplyAsync :: AgentClient -> ACorrId -> UserId -> InvitationId -> MsgBody -> AE ()

-- Refuses a request (Just reason = AgentRejection to Q_A; Nothing = silent drop). PROHIBITED on wrong kind.
rejectServiceRequest      :: AgentClient -> NetworkRequestMode -> UserId -> InvitationId -> Maybe ByteString -> AE ()
rejectServiceRequestAsync :: AgentClient -> ACorrId -> UserId -> InvitationId -> Maybe ByteString -> AE ()

-- contact rejection, now sharing prepareReply + the kind guard:
rejectContact      :: AgentClient -> NetworkRequestMode -> UserId -> ConfirmationId -> Maybe ByteString -> AE ()
rejectContactAsync :: AgentClient -> ACorrId -> UserId -> ConfirmationId -> Maybe ByteString -> AE ()
```

Client side:

```haskell
-- Both establish the ratchet from the address, create Q_A, send the request, and block on the reply TMVar up to
-- serviceRequestTimeout, returning the payload (a rejection or timeout is a thrown agent error). No callback.
-- Sync: the send is direct and fails fast if the server is down. Async: the send is enqueued as a retried command.
sendServiceRequest      :: AgentClient -> NetworkRequestMode -> UserId -> ConnectionRequestUri 'CMContact -> MsgBody -> AE MsgBody
sendServiceRequestAsync :: AgentClient -> UserId -> ConnectionRequestUri 'CMContact -> MsgBody -> AE MsgBody
```

Both share `serviceRequest_` (create Q_A + mark `created_at` + register the `TMVar` + block on it up to `serviceRequestTimeout` + tear down); they differ only in the send. **Sync** calls `joinConnSrv'` directly - it fails fast on `BROKER NETWORK` if the server is down (`NRMBackground` only sets the per-attempt timeout, it does not retry a refused connection). **Async** enqueues an ordinary `JOIN (JRConnReq …)` command, which the command worker runs through `tryCommand` (`withRetryInterval`/`temporaryOrHostError`, the same retry the reply's `ICReplyDel` uses) - so the send survives a server outage. No new command or serialization: the `JOIN` worker branches on the reply queue's `serviceReply` flag (persistent, from `created_at`) to send `AgentServiceRequest` via `joinConnSrv'` instead of `AgentConnInfoReply`, and skips the `JOINED` event. Either way the call blocks on the `TMVar` and returns the response synchronously - no events, so the app has no correlation to do. There is no `cancelServiceRequest` - an aborted call's Q_A is reaped by `created_at`.

Events (`AEvent`, entity is the address connection):

```haskell
SREQ :: InvitationId -> MsgBody -> AEvent AEConn  -- mirrors REQ (InvitationId); payload = the request.
RJCT :: ConnInfo -> AEvent AEConn                 -- contact-request rejection reason to chat.
```

Errors (`SMPAgentError`, mirroring `A_CRYPTO {cryptoErr :: AgentCryptoError}`):

```haskell
| A_SERVICE {serviceError :: AgentServiceError}

data AgentServiceError
  = ASERejected {rejectReason :: String}  -- the service refused, reason as latin1 String (bytes round-trip)
  | ASETimeout                            -- no reply within the timeout (client wait, or a late service reply)
  | ASENoRequest                          -- a reply arrived with no pending request (e.g. post-restart)
```

Config (`AgentConfig`): `serviceRequestTimeout` (30 s, the client wait) and `serviceReplyTimeout` (180 s, the service reply window and the cleanup TTL; must exceed `serviceRequestTimeout`).

## Idempotency (deferred)

Not built. When built, the service will key a request by hash and cache the one response for a retention period, so a repeat request is answered from storage without reaching the bot - single execution over at-least-once delivery, with its own tables.

## Tests

Implemented and passing (in `FunctionalAPITests`, plus the encoding roundtrip in `ConnectionRequestTests`):

- Encoding roundtrip: `AgentServiceRequest`/`AgentServiceResponse`/`AgentRejection` (headerless single) + the `AgentContactRequest` rename.
- Request -> one response (sync `sendServiceReply`).
- Request -> one response (async `sendServiceReplyAsync`).
- Request -> rejection (`rejectServiceRequest (Just reason)` -> thrown `A_SERVICE (ASERejected …)`).
- **Resilience**: `server down -> send -> up -> receive -> down -> reply -> up -> receive response` - the send (`sendServiceRequestAsync`) is enqueued and retried through the outage, the reply (`sendServiceReplyAsync`) is queued and delivered on reconnect; both blocking calls receive their result.
- No regression: the existing rejection + schema tests still pass.

Not yet covered (code-complete): the wrong-kind `CMD PROHIBITED` guards; the client timeout (`ASETimeout`); the late-reply timeout (`serviceReplyTimeout`); `cleanupManager` reaping; the `ASENoRequest` post-restart path. A full `simplexmq-test` run and the PostgreSQL migration path are also not yet run here.

## Status

Both implementation phases are done and compile clean. Remaining in this repo: the test gaps above, a full suite run, and the PostgreSQL path. Separate `simplex-chat` repo: `RJCT` -> `XReject`/`XGrpReject`, bot consumption of `SREQ` / `sendServiceReply`, and `sendServiceRequest` on the client. Later, separate pass: idempotency.
