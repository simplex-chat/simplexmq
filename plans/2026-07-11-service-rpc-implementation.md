# Service RPC implementation plan

RFC: [../rfcs/2026-07-11-service-rpc.md](../rfcs/2026-07-11-service-rpc.md)

Depends on: [2026-07-12-address-dr-implementation.md](2026-07-12-address-dr-implementation.md). RPC establishes the double ratchet from the address exactly as address-DR does; this is the RPC layer on top of it.

**Status: implemented and tested in this repo.** Service-side idempotency (single execution by request hash) is deferred. The `simplex-chat` integration is a separate repo.

**Scope.** One request, one response — no continuation, no streaming.

One DR-advertising contact address serves both flows: the owner branches per incoming request on the decrypted inner message — `AgentConnInfoReply` opens a connection (`REQ`), `AgentServiceRequest` answers an RPC (`SREQ`). A request gets exactly one reply, a response or a rejection; both are the single confirming message on the requester's reply queue Q_A, after which the ephemeral reply connection is torn down. Response and rejection are the same operation parameterized by the inner message (`AgentServiceResponse` payload vs `AgentRejection` reason) and outcome (the call returns the payload vs throws an agent error).

## RPC messages

No new outer envelope: the request reuses `AgentContactRequest` (tag `'A'`); the reply reuses `AgentConfirmation` (the only message on Q_A).

Inner `AgentMessage` (ratchet-encrypted, parsed by `parseMessage`), siblings of `AgentConnInfoReply`:

```haskell
  | AgentServiceRequest (NonEmpty SMPQueueInfo) MsgBody  -- 'A': reply queue Q_A + opaque payload
  | AgentServiceResponse MsgBody                         -- 'P': response payload (single, terminal)
  | AgentRejection ByteString                            -- 'J': refusal reason (single, terminal)
```

`AgentServiceRequest` carries Q_A (as `AgentConnInfoReply` does); its constructor is the only thing that distinguishes `REQ` from `SREQ`. Delivery `msgType`: `AM_SRV_RESP` routes to `sendConfirmation` (the reply is the confirming first message on Q_A). `AM_SRV_REQ` is never stored — the request is sent synchronously inside `joinConnSrv'` via `sendInvitation`, so its arms in the delivery worker are unreachable and assert (`logError`).

## Ratchet establishment — reuse of the address-DR flow

`joinConnSrv'` takes `mkInner :: SMPQueueInfo -> AgentMessage`; `joinConnSrv` is the one-line wrapper passing `AgentConnInfoReply`. `sendServiceRequest'` passes `AgentServiceRequest`.

**Request (client).** `serviceRequest_` fails fast with `A_SERVICE ASENotDRAddress` if the address carries no ratchet keys, then creates the client connection via `newConnToJoin` with `serviceRequestExpiresAt = Just (now + reqTimeout)` (the persisted per-request deadline), registers a one-shot `TMVar` in `serviceRequests`, sends the request, and blocks on the `TMVar` up to `reqTimeout`. The connection is `RcvConnection` (Q_A) with the send ratchet.

**Request (service).** `smpContactRequest` decrypts `encConnInfo` and branches on the inner message; both branches call the same `storeInvitation` → `conn_invitations`, differing only in the kind column and event:

- `AgentConnInfoReply` → `REQ` (`service_request = 0`).
- `AgentServiceRequest _ payload` → `SREQ invId payload` (`service_request = 1`).

Before storing, it **deduplicates** by the sender's ratchet-key hash (`checkRatchetKeyHashExists`/`addProcessedRatchetKeyHash`, the mechanism `newRatchetKey` uses): a redelivered/retried request reuses the same Q_A and the same `e2eSndParams`, so the hash matches and the duplicate is dropped — one invitation and one `REQ`/`SREQ` per request. Receive-time establishment on unauthenticated input — the address-DR abuse bound applies.

**The reply (service).** `prepareReply` fetches the invitation, enforces the kind (`CMD PROHIBITED` on the wrong one), and rejects a stale request (`A_SERVICE ASETimeout` + delete) older than `serviceResponseTimeout`; then `newConnToAccept` + `startJoinInvitationDR` build the one-directional `SndQueue` to Q_A (no reply queue back), and `storeConfirmation` queues the inner message. `sendReplySync` secures Q_A, submits the message, and deletes the connection with wait-for-delivery — **deleting the connection on failure too** (`catchAllErrors`), so a failed secure/submit does not orphan it. `sendServiceReplyAsync` defers secure+deliver+delete to the `ICReplyDel` command (retried, survives a down server). `sendServiceReply`/`Async` and `replyRequest_` return the reply `ConnId` so the caller can correlate the `SENT` event on that throwaway connection.

**The response (client).** The single `AgentConfirmation` on Q_A reaches `processConnInfo` (the `RcvConnection … New` branch). Dispatch is gated on `serviceRequestExpiresAt` and the kinds are mutually exclusive:

- `AgentConnInfoReply` **only when `isNothing serviceRequestExpiresAt`** (a contact connection) → `processConf`.
- `AgentServiceResponse` only when `isJust` → the request `TMVar` gets `Right payload`.
- `AgentRejection` when `isJust` → `Left (A_SERVICE (ASERejected reason))`; when `isNothing` → contact `RJCT`.
- anything else → `prohibited`.

The `isNothing` guard on `AgentConnInfoReply` is a security boundary: without it a malicious service could send `AgentConnInfoReply` on an RPC reply queue and drive it into the contact-`CONF` path. `dispatchServiceReply` puts the result into the `serviceRequests` `TMVar`; a reply with no pending request (e.g. post-restart) is `ERR (A_SERVICE ASENoPendingRequest)`.

## Rejection

A rejection is `AgentRejection reason` — the same single confirming message on Q_A as a response.

- **Kind guard.** `rejectContact` only on a contact invitation, `rejectServiceRequest`/`sendServiceReply` only on a request; wrong kind is `CMD PROHIBITED`. `rejectRequest_` enforces the kind **even on a `Nothing` (silent-drop) reject** — it fetches the invitation and checks before deleting, so `rejectContact … Nothing` cannot delete a service request (or vice versa).
- `reject*` take `Maybe ByteString`: `Nothing` → delete the invitation, send nothing (the requester times out); `Just reason` → the reply path with `AgentRejection`.
- Requester side: `AgentRejection` on a contact reply queue → `RJCT`; on an RPC reply queue → a thrown `A_SERVICE (ASERejected reason)`.

## Reply connections and cleanup

No reply-queue table and no new connection type.

- **Requester reply queue** (`RcvConnection` on Q_A): `connections.service_request_expires_at` is non-null only here; it is the persisted request deadline, used both to gate CONF dispatch and to reap the connection. In-memory routing is `serviceRequests :: TMap ConnId (TMVar (Either AgentErrorType MsgBody))`.
- **Timeout race.** The async `JOIN` worker holds `withConnLock c connId` around `joinConnSrv'`, and `serviceRequest_`'s cleanup holds the same lock around `TM.delete` + `deleteConnectionAsync'`. This serializes the send with the timeout teardown, so a timing-out call cannot delete the connection mid-send; after cleanup the worker's re-check of `serviceRequests` finds nothing and skips.
- **Service reply connection** (`SndConnection` to Q_A): ephemeral — created, sends the one reply, deleted with wait-for-delivery in the same operation.
- **Cleanup** (`cleanupManager`, `deleteExpiredServiceReqs`): `deleteExpiredServiceRequests` reaps unanswered `conn_invitations` (service side) older than `serviceResponseTimeout`; `getExpiredServiceConns` (`service_request_expires_at < now`) → `deleteConnectionsAsync'` reaps orphaned requester reply queues.

## Database schema

`M20260712_address_dr_rpc` (SQLite + PostgreSQL) creates `address_ratchet_keys` (address-DR) and adds:

```sql
ALTER TABLE conn_invitations ADD COLUMN service_request INTEGER NOT NULL DEFAULT 0; -- service side: 1 = RPC request
ALTER TABLE connections ADD COLUMN service_request_expires_at TEXT;                 -- client side: request deadline; gating + cleanup (nullable)
```

The down migration drops the columns then the table/index. Schema dump tests pass (up, down, STRICT).

## Agent API — `Simplex.Messaging.Agent`

```haskell
-- service: send the one response, return the reply ConnId, then tear the reply connection down.
sendServiceReply      :: AgentClient -> NetworkRequestMode -> UserId -> InvitationId -> MsgBody -> AE ConnId
sendServiceReplyAsync :: AgentClient -> ACorrId -> UserId -> InvitationId -> MsgBody -> AE ConnId

-- refuse a request (Just reason = AgentRejection; Nothing = silent drop). PROHIBITED on wrong kind.
rejectServiceRequest      :: AgentClient -> NetworkRequestMode -> UserId -> InvitationId -> Maybe ByteString -> AE ()
rejectServiceRequestAsync :: AgentClient -> ACorrId -> UserId -> InvitationId -> Maybe ByteString -> AE ()
rejectContact      :: AgentClient -> NetworkRequestMode -> UserId -> ConfirmationId -> Maybe ByteString -> AE ()
rejectContactAsync :: AgentClient -> ACorrId -> UserId -> ConfirmationId -> Maybe ByteString -> AE ()

-- client: establish the ratchet from the address, send the request, block on the reply TMVar up to the timeout
-- (Nothing = serviceRequestTimeout; Just t overrides per request), returning the payload. Sync fails fast if the
-- server is down; async enqueues a retried JOIN command that survives an outage.
sendServiceRequest      :: AgentClient -> NetworkRequestMode -> UserId -> ConnectionRequestUri 'CMContact -> Maybe NominalDiffTime -> MsgBody -> AE MsgBody
sendServiceRequestAsync :: AgentClient -> UserId -> ConnectionRequestUri 'CMContact -> Maybe NominalDiffTime -> MsgBody -> AE MsgBody
```

Both client calls share `serviceRequest_`; the async `JOIN` worker branches on the `JRServiceReq` command to send `AgentServiceRequest`. The call blocks on the `TMVar` and returns synchronously — no events, no correlation for the app.

Events (`AEvent`, entity is the address connection):

```haskell
SREQ :: InvitationId -> MsgBody -> AEvent AEConn  -- payload = the request; mirrors REQ.
RJCT :: ConnInfo -> AEvent AEConn                 -- contact-request rejection reason.
```

Errors (`SMPAgentError`):

```haskell
| A_SERVICE {serviceError :: AgentServiceError}

data AgentServiceError
  = ASERejected {rejectReason :: Text}  -- service refused (Text: JSON-serializable, UTF-8-decoded from the reason bytes)
  | ASETimeout                          -- no reply within the timeout
  | ASENoPendingRequest                 -- a reply arrived with no pending request (e.g. post-restart)
  | ASENotDRAddress                     -- the target address advertises no ratchet keys (fail fast, no send)
```

Config (`AgentConfig`): `serviceRequestTimeout` (30 s, client wait, overridable per request) and `serviceResponseTimeout` (180 s, service reply window and cleanup TTL; must exceed `serviceRequestTimeout`).

## Idempotency (deferred)

Not built. When built, the service will key a request by hash and cache the one response for a retention period, answering a repeat from storage without reaching the bot — single execution over at-least-once delivery, with its own tables.

## Tests

In `FunctionalAPITests` (plus the encoding roundtrip in `ConnectionRequestTests`), passing with `-O0`:

- Request → one response, sync (`sendServiceReply`) and async (`sendServiceReplyAsync`).
- Request → rejection (`rejectServiceRequest (Just reason)` → thrown `A_SERVICE (ASERejected …)`).
- Resilience: `server down → send → up → receive → down → reply → up → receive response`.
- No regression: the contact rejection and DR-join suites still pass.

The `simplex-chat` end-to-end tests (happy path, drop-when-off, non-DR fail-fast) live in that repo.
