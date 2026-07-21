# Service RPC implementation plan

RFC: [../rfcs/2026-07-11-service-rpc.md](../rfcs/2026-07-11-service-rpc.md)

Depends on: [2026-07-12-address-dr-implementation.md](2026-07-12-address-dr-implementation.md). RPC establishes the double ratchet from the address exactly as the address-DR plan does; this plan is the RPC layer on top of it. Steps named R2'/R5'/O2'/O3' are from that plan.

**Scope: transport + rejection.** One request, **one** response - no continuation, no streaming. Service-side **idempotency** (single execution by request hash) is deferred.

**HTTP vs WebSocket.** RPC is the HTTP-shaped path: a single request and a single response, no persistent connection. A contact request is the WebSocket-shaped path: it opens a connection over which both sides then exchange messages. One DR-advertising address serves both, and the owner decides which it is per incoming request from the decrypted inner message - `AgentConnInfoReply` opens a connection, `AgentServiceRequest` answers an RPC. This plan builds the HTTP-shaped path (the WebSocket-shaped path is the existing contact/connection flow).

**Single-response shape.** A request gets exactly one reply, which is either a response or a rejection; there are no follow-up messages, no `final` flag (the one response is terminal), no callback, and one payload per reply. This makes a response and a rejection the *same operation*: each is the single confirming message on the requester's reply queue Q_A, after which the ephemeral reply connection is torn down. They differ only in the inner message (`AgentServiceResponse` payload vs `AgentRejection` reason) and in the requester's outcome (the call returns the payload vs throws an agent error with the reason). So the reply path is the rejection path already built, parameterized by the inner message.

**Design rule: no parallel flow.** On the receive side an RPC request and a contact invitation are the same message stored the same way - one `smpContactRequest` (renamed from `smpInvitationDR`) writes one `conn_invitations` row, differing only in a kind column (`is_service_request`) and the event (`REQ` vs `SREQ`). The kind makes the APIs exclusive: an invitation can only be accepted, a request only responded to or rejected; the wrong API on the wrong kind is `CMD PROHIBITED`. The reply/reject send is the shared secure -> deliver-one-confirmation -> delete-with-wait-delivery path.

## Built so far

Kept: `AgentContactRequest` rename (tag `'A'`); the `SREQ`/`RJCT` events; `SREQ :: InvitationId -> MsgBody`; contact rejection (`rejectContact`/`rejectContactAsync` via the `ICReject` internal command, requester-side `RJCT`, tests green); the `M20260712_service_rpc` migration (now `conn_invitations.is_service_request` + `connections.created_at`), schema tests green.

Small revisions to fit the single-response shape: the inner `AgentServiceResponse`/`AgentRejection` lose their `APrivHeader`, the `Bool final` flag and `NonEmpty` (below) - they are single, headerless confirming messages like `AgentConnInfoReply`; `ICReject` (secure + deliver the pending confirmation + delete) is inner-message-agnostic, so it is reused for responses too (renamed to a neutral `ICReplyDel`).

## RPC messages

**No new outer envelope.** The request reuses `AgentContactRequest` (to the address queue); the one reply reuses `AgentConfirmation` (the confirming first message on Q_A - the only message, so never `AgentMsgEnvelope`).

**Inner `AgentMessage`** (L4, ratchet-encrypted; Protocol.hs:921, `parseMessage`) - three headerless variants, siblings of `AgentConnInfoReply`:

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

`AgentServiceRequest` carries Q_A (as `AgentConnInfoReply` does) so the service knows where to reply; its constructor is the only thing that tells `REQ` from `SREQ`. `AgentServiceResponse`/`AgentRejection` are each the sole message on Q_A - no header (nothing to number or chain), no `final` (terminal), no `NonEmpty` (one payload). `AgentMessageType`: `AM_SRV_RESP` and `AM_RJCT` both route to `sendConfirmation` (the reply is always a confirmation); there is no later-message path for RPC, so `agentClientMsg` is unchanged.

## Ratchet establishment - reuse of the address-DR flow

**Request (client)** - address-DR requester path (R2'/R3'), inner is `AgentServiceRequest`:

- Negotiate the advertised ratchet params, create Q_A (messaging mode, subscribed), establish the send ratchet.
- Send `AgentContactRequest {e2eSndParams, ratchetKeyId, encConnInfo = ratchetEncrypt(AgentServiceRequest (Q_A :| []) payload)}` to the address, unauthenticated. The client connection is `RcvConnection` (Q_A) with the send ratchet; mark its `created_at` (cleanup below).

**Request (service)** - `smpContactRequest` (renamed `smpInvitationDR`, Agent.hs:3792): decrypt `encConnInfo`, then branch on the inner message. **Both branches call the same `storeInvitation` -> `conn_invitations`** (AgentStore.hs:877), writing the kind column; they differ only in the event:

- `AgentConnInfoReply` -> `REQ invId ...` (`is_service_request = 0`, unchanged).
- `AgentServiceRequest _ payload` -> `SREQ invId payload` (`is_service_request = 1`).

The service holds the request as an invitation with the payload as `recipient_conn_info`; no connection yet. Receive-time establishment on unauthenticated input - the address-DR abuse bound applies unchanged.

**The one reply (service)** - `sendServiceReply c nm invId payload`, the accept-and-tear-down path (the rejection path with a payload). `CMD PROHIBITED` if the invitation is a contact invitation (wrong kind); an answered request is no longer pending, so a repeat just fails to find it:

- `newConnToAccept` (Agent.hs:1359) creates the ephemeral reply connection from the request; `startJoinInvitationDR` builds the `SndQueue` to Q_A and the ratchet - **no reply queue back** (one-directional; the divergence from `acceptContact'`, which sends `AgentConnInfoReply` with its reply queue).
- `storeConfirmation` the pending `AgentServiceResponse payload` (`AM_SRV_RESP` -> `sendConfirmation`); `acceptInvitation`; then secure Q_A + deliver + `deleteConnectionAsync' True` (wait-for-delivery, so the one message is delivered before teardown). Sync `sendServiceReply` secures via `agentSecureSndQueue`; async `sendServiceReplyAsync` defers secure+deliver+delete to `ICReplyDel` (the renamed `ICReject`, retried, never fails client-side).
- Returns `()`. There is no continuation, so no `connId` is handed back.

**The one response (client)** - the single `AgentConfirmation` on Q_A -> `smpConfirmation`'s `RcvConnection … Nothing` branch (R5', Agent.hs:3546, already parsing `AgentConnInfoReply`/`AgentRejection`), extended for `AgentServiceResponse`: an `AgentServiceResponse payload` completes the waiting `sendServiceRequest` with the payload; an `AgentRejection reason` completes it with a thrown agent error. Either way, ack and `deleteConnectionAsync' True` on Q_A. No later-message path.

## Rejection

A rejection is `AgentRejection reason` - the same single confirming message on Q_A as a response, always tearing the connection down. It refuses an RPC request and, unchanged from what is built, a contact request.

- **Kind guard:** `rejectContact` only on a contact invitation, `rejectServiceRequest` only on a request; the wrong kind is `CMD PROHIBITED` (read the kind off the pending invitation). An already accepted/responded request is not pending (`getInvitation` filters `accepted = 0`), so the reject fails to find it, as a repeat should.
- `rejectContact`/`rejectContactAsync` / `rejectServiceRequest`/`rejectServiceRequestAsync` take `Maybe ByteString`: `Nothing` -> silent drop (delete the invitation, no message); `Just reason` -> `CMD PROHIBITED` on a classic `CRInvitation` (no ratchet) or the wrong kind; else the reply path above with `AgentRejection` as the inner message.
- Requester side: `AgentRejection` on a contact reply queue -> `RJCT` event to chat (async, mapped to `XReject`/`XGrpReject`); on an RPC reply queue -> a thrown agent error ending `sendServiceRequest` (synchronous; a new `AgentErrorType` carries the reason).

## Reply connection and cleanup

No reply-queue table and no new connection type - both reply connections are ordinary connections with a ratchet.

- **Client reply queue** (`RcvConnection` on Q_A): routed by the in-memory `serviceRequests :: TMap ConnId (TMVar (Either AgentErrorType MsgBody))` in `AgentClient` (Client.hs) - `sendServiceRequest` inserts a one-shot, the receive path fills it (`Right payload` / `Left rejection`), the call unwraps it. The normal path tears the connection down within the call; only a client restart mid-call orphans it. `connections.created_at` is set when the queue is created; `cleanupManager` (Agent.hs:3162) reaps connections whose `created_at` is older than a config TTL (RPC is short-lived), emitting `DEL`.
- **Service reply connection** (`SndConnection` to Q_A): ephemeral - created, sends the one reply, and is deleted with wait-for-delivery in the same operation, so it never lingers and needs no marker.
- **Service request** (`conn_invitations`, which has `created_at`): an unanswered request is reaped by `created_at` + config TTL. This is the received-side "requests table" - `conn_invitations`, differentiated by kind - not a new table.

## Database schema (done)

`M20260712_service_rpc` (SQLite + PostgreSQL), on top of the address-DR migration:

```sql
ALTER TABLE conn_invitations ADD COLUMN is_service_request INTEGER NOT NULL DEFAULT 0; -- 1 = RPC request, 0 = contact invitation
ALTER TABLE connections ADD COLUMN created_at TEXT;  -- set on a client RPC reply queue; cleanup age (nullable)
```

The service's address ratchet keys are the address-DR `address_ratchet_keys` table. The deferred idempotency work will add its own tables when built.

## Agent API - `Simplex.Messaging.Agent`

Service side (a service publishes an ordinary DR-advertising contact address; the same address accepts both connections and RPC):

```haskell
-- Sends the one response to the request from SREQ's invitation id, then tears the reply connection down.
sendServiceReply      :: AgentClient -> NetworkRequestMode -> InvitationId -> MsgBody -> AE ()
sendServiceReplyAsync :: AgentClient -> ACorrId -> InvitationId -> MsgBody -> AE ()

-- Refuses a request (Just reason = AgentRejection to Q_A; Nothing = silent drop). PROHIBITED on wrong kind.
rejectServiceRequest      :: AgentClient -> NetworkRequestMode -> UserId -> InvitationId -> Maybe ByteString -> AE ()
rejectServiceRequestAsync :: AgentClient -> ACorrId -> UserId -> InvitationId -> Maybe ByteString -> AE ()

-- contact rejection (built), plus the new kind guard:
rejectContact      :: AgentClient -> NetworkRequestMode -> UserId -> ConfirmationId -> Maybe ByteString -> AE ()
rejectContactAsync :: AgentClient -> ACorrId -> UserId -> ConfirmationId -> Maybe ByteString -> AE ()
```

Client side:

```haskell
-- Establishes the ratchet from the address, creates Q_A, sends the request, and waits for the one response up to
-- the client-config timeout. Returns the response payload; a rejection or timeout is a thrown agent error. No callback.
sendServiceRequest ::
  AgentClient -> NetworkRequestMode -> UserId -> ConnectionRequestUri 'CMContact -> MsgBody -> AE MsgBody
```

`sendServiceRequest`'s address input is the resolved `ConnectionRequestUri 'CMContact` (reuses the address-DR `joinConnSrv` path, testable like the DR tests); short-link resolution can wrap it later. The wait is bounded by an `AgentConfig` timeout, not a per-call deadline. No `cancelServiceRequest` - an aborted call's Q_A is reaped by `created_at`.

Events (`AEvent`, entity is the address connection):

```haskell
SREQ :: InvitationId -> MsgBody -> AEvent AEConn  -- mirrors REQ (InvitationId); payload = the request.
RJCT :: ConnInfo -> AEvent AEConn                 -- built; contact-request rejection reason to chat.
```

## Agent processing

Client:

- `sendServiceRequest`: address-DR R2' (ratchet + Q_A) with `AgentServiceRequest` inside; set `created_at`; insert the one-shot `TMVar` keyed by the reply `connId`; send `AgentContactRequest`; block on the `TMVar` until the response or the config timeout; on either, `deleteConnectionAsync' True` on Q_A; return the payload or throw.
- Reception: only `smpConfirmation` R5' is touched (`AgentServiceResponse` -> fill `Right`, `AgentRejection` -> fill `Left`); no later-message path.
- `cleanupManager`: delete connections whose `created_at` is older than the TTL (restart-orphaned reply queues).

Service:

- `smpContactRequest`: one `storeInvitation` (writing the kind), branch the event `REQ`/`SREQ`.
- `sendServiceReply`: `newConnToAccept` + `startJoinInvitationDR` (no reply queue back) + `storeConfirmation (AgentServiceResponse payload)` + `acceptInvitation` + secure + deliver + `deleteConnectionAsync' True`. Async defers to `ICReplyDel`.
- `rejectServiceRequest`: the same path with `AgentRejection`, guarded by kind. `sendServiceReply`, `rejectServiceRequest`, and `rejectContact` share one helper, parameterized by the inner message and the kind it expects.
- `cleanupManager`: reap `conn_invitations` requests older than the TTL.

Config (`AgentConfig`): service-request timeout (the client-side wait bound); RPC cleanup TTL.

## Idempotency (deferred)

Not built. When built, the service will key a request by hash and cache the one response for a retention period, so a repeat request is answered from storage without reaching the bot - single execution over at-least-once delivery, with its own tables.

## Tests

- Encoding roundtrips: `AgentServiceRequest`, `AgentServiceResponse`, `AgentRejection` in `AgentMessage`; the `AgentContactRequest` rename (wire unchanged). (Revise the built roundtrip for the headerless/single shape.)
- End to end: a request with one response; `pqEncryption` on/off per advertised keys; the payload never travels under per-queue-only encryption.
- Rejection: `rejectServiceRequest (Just reason)` ends `sendServiceRequest` with the reason (thrown); `rejectContact (Just reason)` reaches the requester as `RJCT`, `Nothing` = silent drop; a wrong-kind reject is `CMD PROHIBITED`; the same address serves a connection and an RPC and can refuse either.
- Lifecycle: the reply connection and ratchet are deleted after the response and after a rejection; the config timeout ends a request with no reply; a restart reaps orphaned client reply queues via `created_at`.

## Phases

1. **[migration + `SREQ` done]** Message revision: `AgentServiceResponse`/`AgentRejection` -> headerless single (drop `APrivHeader`/`Bool`/`NonEmpty`), update encodings + the built contact-rejection call sites + roundtrip test; rename `ICReject` -> `ICReplyDel`; add the `AgentErrorType` rejection reason; thread `is_service_request` onto `Invitation`/`getInvitation` and add the kind guard to `rejectContact`.
2. `smpContactRequest` dispatch (`AgentServiceRequest` -> `SREQ`, writing the kind); the shared `sendServiceReply`/`rejectServiceRequest` (+ async) reply helper; client `sendServiceRequest` + `smpConfirmation` reception + `serviceRequests` one-shot map; both-sides `cleanupManager` steps. End-to-end and rejection tests.

Later, separate pass: idempotency.
