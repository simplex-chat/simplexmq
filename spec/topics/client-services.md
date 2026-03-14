# Client Services

How service certificates enable bulk queue subscriptions: identity lifecycle, queue association, service subscription flow, tracking, reconnection, and notification server usage. This is the cross-cutting view spanning transport, protocol, server, client, agent, and store layers.

For agent-internal subscription tracking (TSessionSubs service state, active/pending promotion), see [agent/infrastructure.md](../agent/infrastructure.md#subscription-tracking). For the router subscription model and delivery mechanics, see [subscriptions.md](subscriptions.md). For the full implementation reference with types, wire encoding, test gaps, security invariants, and risk analysis, see [rcv-services.md](../rcv-services.md).

- [Overview](#overview)
- [Service identity lifecycle](#service-identity-lifecycle)
- [Queue-service association](#queue-service-association)
- [Service subscription flow](#service-subscription-flow)
- [Service tracking in TSessionSubs](#service-tracking-in-tsessionsubs)
- [Reconnection and graceful degradation](#reconnection-and-graceful-degradation)
- [Notification server usage](#notification-server-usage)

---

## Overview

**Source**: [Server.hs](../../src/Simplex/Messaging/Server.hs), [Client.hs](../../src/Simplex/Messaging/Client.hs), [Agent/Client.hs](../../src/Simplex/Messaging/Agent/Client.hs)

A **service client** is a high-volume SMP client (notification router, chat relay, directory service) that presents a TLS client certificate during handshake. The router assigns it a persistent `ServiceId` derived from the certificate fingerprint. Individual queues are then associated with this ServiceId via per-queue `SUB` commands carrying a service signature. Once associated, the service client can bulk-subscribe all its queues with a single `SUBS` command instead of O(n) individual `SUB` commands on each reconnection.

```
Service client                    SMP Router
    |                                  |
    |---- TLS + service cert --------->|  Three-way handshake
    |<--- ServiceId -------------------|  (Transport layer)
    |                                  |
    |---- SUB + service sig ---------->|  Per-queue association
    |<--- SOK(ServiceId) --------------|  (one-time per queue)
    |                                  |
    |---- SUBS count idsHash --------->|  Bulk subscribe
    |<--- SOKS count' idsHash' --------|  (server's actual state)
    |<--- MSG ... MSG ... MSG ---------|  Buffered messages
    |<--- ALLS ------------------------|  All delivered
```

Two version gates control feature availability: `serviceCertsSMPVersion` (v16) enables the service handshake, `SOK`, and dual signatures; `rcvServiceSMPVersion` (v19) adds count+hash parameters to `SUBS`/`NSUBS`/`SOKS`/`ENDS` and enables the messaging service role (`SRMessaging`). Below v19, `SUBS`/`NSUBS` exist but are sent without parameters.

---

## Service identity lifecycle

**Source**: [Transport.hs](../../src/Simplex/Messaging/Transport.hs), [Agent/Client.hs](../../src/Simplex/Messaging/Agent/Client.hs), [Agent/Store/AgentStore.hs](../../src/Simplex/Messaging/Agent/Store/AgentStore.hs)

### Credential generation

The agent generates a self-signed X.509 certificate per (userId, server) pair on first use via `getServiceCredentials`. The certificate is generated with `genCredentials` using a long validity period and is stored in the `client_services` table along with the private signing key and certificate fingerprint. The `ServiceId` column is NULL until the first successful handshake.

### Three-way handshake

Standard SMP handshake is two messages (server sends `SMPServerHandshake`, client sends `SMPClientHandshake`). When the client includes service credentials, an optional third message is added:

1. **Router -> Client**: standard `SMPServerHandshake`
2. **Client -> Router**: `SMPClientHandshake` with `SMPClientHandshakeService {serviceRole, serviceCertKey}`. The `serviceCertKey` contains the TLS client certificate chain plus a proof-of-possession - a fresh per-session Ed25519 key pair signed by the X.509 signing key.
3. **Router -> Client**: `SMPServerHandshakeResponse {serviceId}`. The router verifies the certificate chain matches the TLS peer certificate, extracts the fingerprint, and calls `getCreateService` to find or create a `ServiceId` for that fingerprint.

The per-session Ed25519 key (not the X.509 key) is used to sign `SUBS`/`NSUBS` commands. This limits exposure - compromising a session key does not compromise the long-term service identity.

### Dual signature scheme

When the TLS handshake established a service identity (the client has a `THClientService`) and the command is `NEW`, `SUB`, or `NSUB` (per `useServiceAuth`), `authTransmission` appends two signatures:

1. The entity key signs over `serviceCertHash || transmission` - binding the service identity to the queue operation
2. The service session key signs over `transmission` alone

This prevents MITM service substitution within TLS: an attacker cannot replace the service certificate hash without invalidating the entity key signature.

### Version-gated role filtering

Messaging services (`SRMessaging`) are suppressed below v19 - `mkClientService` returns `Nothing` for messaging role when the router version is below `rcvServiceSMPVersion`. Notifier services (`SRNotifier`) are sent at v16+. This allows gradual rollout - routers can support notification service certificates before full messaging service support.

---

## Queue-service association

**Source**: [Server.hs](../../src/Simplex/Messaging/Server.hs), [Server/QueueStore.hs](../../src/Simplex/Messaging/Server/QueueStore.hs)

Queues are associated with services through per-queue `SUB` commands (with service signature) or at creation time via `NEW`. The router stores `rcvServiceId :: Maybe ServiceId` on each `QueueRec`.

### sharedSubscribeQueue - four cases

`sharedSubscribeQueue` handles the intersection of client type and existing association:

**Case 1: Service client, queue already associated with this service** - Duplicate association (retry after lost response). If no service subscription exists yet, increments the client's service queue count.

**Case 2: Service client, queue not yet associated** (or different service) - Calls `setQueueService` to persist the association in `QueueRec`, increments client's `serviceSubsCount` by `(1, queueIdHash rId)`.

**Case 3: Non-service client, queue has service association** - Calls `setQueueService` with `Nothing` to **remove** the association. This is the migration path when a user disables services.

**Case 4: Non-service client, no service association** - Standard per-queue subscription, no service involvement.

### Association persistence

The `setQueueService` function in QueueStore updates `rcvServiceId` on the queue record and maintains the service's aggregate queue set (`STMService.serviceRcvQueues`). The set and its XOR hash are updated atomically. Associations persist across client disconnect - only live subscription state is cleaned up, not the stored `rcvServiceId`.

### IdsHash - XOR-based drift detection

`IdsHash` is a 16-byte value computed as XOR of MD5 hashes of individual queue IDs. XOR is self-inverse, so both `addServiceSubs` and `subtractServiceSubs` use the same `<>` (XOR) operator for the hash component. The count field prevents collision - two different queue sets with the same XOR could have different counts.

---

## Service subscription flow

**Source**: [Server.hs](../../src/Simplex/Messaging/Server.hs), [Client.hs](../../src/Simplex/Messaging/Client.hs), [Agent/Client.hs](../../src/Simplex/Messaging/Agent/Client.hs)

### SUBS command processing

1. `subscribeServiceMessages` receives `SUBS count idsHash` from the client.
2. `sharedSubscribeService` queries `getServiceQueueCountHash` for the router's actual count and hash, sets `clientServiceSubscribed = True`, and enqueues a `CSService` event to `subQ`. `serverThread` processes this asynchronously: adds the client to `subClients`, adjusts `totalServiceSubs`, and upserts into `serviceSubscribers` (displacing any previous subscriber).
3. Returns `SOKS count' idsHash'` immediately - the client can compare expected vs actual to detect drift.

### deliverServiceMessages and ALLS

If this is a new subscription (not duplicate), the router forks `deliverServiceMessages`:

1. `foldRcvServiceMessages` iterates all queues associated with the service.
2. For each queue with a pending message: `getSubscription` creates a `Sub` in the client's `subscriptions` TMap (if not already present), sets `delivered`, and writes the MSG event to `msgQ` immediately.
3. Queue errors are accumulated in a list whose initial value is `[(NoCorrId, NoEntity, ALLS)]`. Errors are prepended, so ALLS ends up as the last event.
4. After the fold completes, the accumulated events (errors plus ALLS) are written to `msgQ` in one batch.

MSG events are delivered individually during the fold (not accumulated), while ALLS is deferred to the end - this ensures ALLS arrives only after all pending messages have been sent.

If the subscription is a duplicate (`hasSub` is `True`), `deliverServiceMessages` is NOT forked - only `SOKS` is returned.

### On-demand Sub creation for new messages

When a new message arrives for a service-associated queue via `tryDeliverMessage`, the router looks up the subscriber in `serviceSubscribers` (by ServiceId) rather than `queueSubscribers` (by QueueId). If no `Sub` exists in the client's `subscriptions` TMap (the fold hasn't reached this queue yet, or the queue was associated after SUBS), `newServiceDeliverySub` creates one on the fly. The fold's `getSubscription` performs the same check. STM serialization ensures at most one path creates the Sub for a given queue.

### Service displacement

When a new service client subscribes to the same ServiceId and the previous subscriber is a different, still-connected client, `cancelServiceSubs` atomically zeros out the old client's `clientServiceSubs` counter and prepares an `ENDS count idsHash` event. `endPreviousSubscriptions` then swaps out the old client's individual subscription map, cancels per-queue Subs, and places ENDS in `pendingEvents` for deferred delivery via `sendPendingEvtsThread`. The old client's fold thread (if still running from `deliverServiceMessages`) continues writing to the old client's `msgQ` until ALLS, then exits.

---

## Service tracking in TSessionSubs

**Source**: [Agent/TSessionSubs.hs](../../src/Simplex/Messaging/Agent/TSessionSubs.hs), [Agent/Client.hs](../../src/Simplex/Messaging/Agent/Client.hs)

### Aggregate tracking - service queues are not in activeSubs

When a queue has both a matching `serviceId` and `serviceAssoc = True`, it is tracked only via the count and hash in `activeServiceSub`, **not** in the `activeSubs` TMap. Callers pre-separate queues into two lists before calling `batchAddActiveSubs`: non-service queues go to `activeSubs`, service-associated queues are counted via `updateActiveService`. A queue on a service-capable session but with `serviceAssoc = False` still lands in `activeSubs` normally. Consequence: `hasActiveSub(rId)` returns `False` for service-associated queues - callers must check the service subscription separately.

### Session ID gating

`setActiveServiceSub` only promotes the service subscription from pending to active if the session ID matches the current TLS session. If a reconnection occurred between sending SUBS and receiving SOKS, the stale response is kept as pending rather than promoted. This prevents a response from an old session from corrupting the new session's state.

### State transitions

- **setPendingServiceSub**: stores expected `ServiceSub` before SUBS is sent
- **setActiveServiceSub**: promotes to active after SOKS, with session ID validation
- **updateActiveService**: incrementally builds the active service sub as individual queues return `SOK(Just serviceId)` - used when per-queue SUBs succeed with service association
- **setServiceSubPending_**: demotes active to pending on disconnect (called by `setSubsPending`)
- **deleteServiceSub**: clears both active and pending on ENDS

### Service events

| Event | When |
|-------|------|
| `SERVICE_UP srv result` | SUBS succeeded; `ServiceSubResult` carries any drift errors (count/hash/serviceId mismatch) |
| `SERVICE_DOWN srv sub` | Client disconnected while service was subscribed |
| `SERVICE_ALL srv` | ALLS received - all buffered messages delivered |
| `SERVICE_END srv sub` | ENDS received - another service client took over |

All are entity-less (`AENone`) events.

---

## Reconnection and graceful degradation

**Source**: [Agent/Client.hs](../../src/Simplex/Messaging/Agent/Client.hs)

### updateClientService - credential synchronization

After each SMP connection, `updateClientService` reconciles the agent's stored ServiceId with the router's:

- **ServiceId matches**: normal path, no action needed
- **ServiceId changed** (router data was reset): calls `removeRcvServiceAssocs` to clear all queue-service associations for this server, forcing re-association via individual SUBs
- **Router lost service support** (version downgrade): calls `deleteClientService` to remove the local service record entirely
- **Router returned ServiceId without credentials**: logs error (should not happen)

### Resubscription ordering

On reconnect, the resubscription worker processes the pending service subscription **before** individual queues. This ensures the service context is established before queue-level SUB commands that depend on it (the router uses `clntServiceId` from the TLS session for queue-service association).

### Fallback to individual subscriptions

`resubscribeClientService` handles two error classes by falling back to `unassocSubscribeQueues`:

- `SSErrorServiceId` - the router returned a different ServiceId than expected
- `clientServiceError` - matches `NO_SERVICE`, `SERVICE`, and `PROXY(BROKER NO_SERVICE)` errors

`unassocSubscribeQueues` deletes the `client_services` row, sets `rcv_service_assoc = 0` on all queues, and resubscribes them individually. This is the nuclear recovery path - service state is fully reset, and the next connection will generate fresh credentials.

### Agent store triggers

The agent's `client_services` table tracks `service_queue_count` and `service_queue_ids_hash`. SQLite triggers on `rcv_queues` automatically maintain these counters when `rcv_service_assoc` changes. The triggers use `simplex_xor_md5_combine` - the SQLite equivalent of Haskell's `queueIdHash <>`. On credential update (new cert), `service_id` is set to NULL via `ON CONFLICT DO UPDATE`, forcing a fresh handshake.

---

## Notification server usage

**Source**: [Notifications/Server.hs](../../src/Simplex/Messaging/Notifications/Server.hs), [Notifications/Server/Env.hs](../../src/Simplex/Messaging/Notifications/Server/Env.hs)

The notification server is the primary consumer of service certificates for the `SRNotifier` role. It manages thousands to millions of SMP queue subscriptions per SMP router.

### Credential management

`NtfServerConfig.useServiceCreds` controls whether the NTF server uses service certificates. On first use per SMP router, `mkDbService` generates a self-signed TLS certificate (stored in the `smp_servers` table) and reuses it across connections.

### Startup subscription

If a stored service subscription exists, `subscribeSrvSubs` sends `NSUBS` first (one command for all associated queues), then subscribes all queues individually in batches via `subscribeQueuesNtfs` (including service-associated queues, which were previously associated via `NSUB`).

### Recovery path

On `CAServiceUnavailable` (irrecoverable service error, e.g., ServiceId mismatch after cert rotation), `removeServiceAndAssociations` performs nuclear recovery: clears all service credentials, resets counters, removes all `ntf_service_assoc` flags, and resubscribes all queues individually. The Postgres schema uses `xor_combine` triggers (equivalent to the agent's SQLite triggers) to maintain per-SMP-server notifier count and hash.

### NSUBS vs SUBS

`NSUBS` uses the same `sharedSubscribeService` for registration in `serviceSubscribers` but does **not** fork `deliverServiceMessages`. Notification delivery is handled by the separate `deliverNtfsThread` which uses `serviceSubscribers` to look up the subscribed service client for each notification queue. Consequently, there is no `ALLS` signal for NSUBS subscriptions.
