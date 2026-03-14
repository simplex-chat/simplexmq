# Subscriptions

How messages reach recipients: router subscription model, subscription-driven delivery, cross-layer subscription flow, and reconnection. This is the cross-cutting view spanning all three layers (router, client, agent).

For agent-internal subscription tracking (TSessionSubs, pending/active state machine, UP event deduplication), see [agent/infrastructure.md](../agent/infrastructure.md#subscription-tracking). For service subscription lifecycle, see [client-services.md](client-services.md). For the SMP protocol specification, see [simplex-messaging.md](../../protocol/simplex-messaging.md).

- [Router subscription model](#router-subscription-model)
- [Subscription-driven delivery](#subscription-driven-delivery)
- [Cross-layer subscription flow](#cross-layer-subscription-flow)
- [Reconnection and resubscription](#reconnection-and-resubscription)
- [Service subscriptions](#service-subscriptions)

---

## Router subscription model

**Source**: [Server.hs](../../src/Simplex/Messaging/Server.hs), [Server/Env/STM.hs](../../src/Simplex/Messaging/Server/Env/STM.hs)

The router tracks which client connection is subscribed to each queue. At most one client can be subscribed to a given queue at a time - a new subscription displaces the previous one.

### SubscribedClients - the TVar-of-Maybe pattern

`SubscribedClients` is a `TMap EntityId (TVar (Maybe (Client s)))`. The indirection through `TVar (Maybe ...)` serves two purposes:

1. **STM re-evaluation**: any transaction reading the TVar automatically re-evaluates when the subscriber changes (disconnects, gets displaced). This is used by `tryDeliverMessage` - if the subscriber disconnects mid-delivery, the STM transaction retries and sees `Nothing`.

2. **Reconnection continuity**: when a mobile client disconnects and reconnects, the TVar is reused rather than recreated. Subscriptions that were made at any point are never removed from the map - this is a deliberate trade-off for intermittently connected mobile clients.

The `SubscribedClients` constructor is not exported from `Server/Env/STM.hs` (only the type is). All access goes through `getSubscribedClient` (IO, outside STM) and `upsertSubscribedClient` (STM). This prevents accidental use of `TM.lookup` inside STM transactions, which would add the entire TMap to the transaction's read set.

Two instances exist: `queueSubscribers` for individually-subscribed queues and `serviceSubscribers` for service-subscribed queues.

### serverThread - split-STM processing

`serverThread` processes subscription registration events from `subQ`. It runs separately from the client handler threads and uses a split-STM pattern to reduce contention:

```
subQ (TQueue)                         -- (A) STM: read event
  → getServerClient clientId          -- (B) IO: lookup client outside STM
  → updateSubscribers                 -- (C) STM: register in SubscribedClients
  → endPreviousSubscriptions          -- (D) IO: notify displaced clients
```

Step (B) is deliberately outside STM. If the client lookup were inside the transaction, the transaction would re-evaluate every time the clients `IntMap` TVar changes (e.g., when any client connects or disconnects). By reading in IO, only the `updateSubscribers` transaction needs to be STM.

If the client disconnects between steps (B) and (C), `updateSubscribers` handles `Nothing` - it still sends END/DELD to any existing subscriber for the same queue.

### Subscription displacement

When `upsertSubscribedClient` finds a different client already subscribed to the same entity, it returns the previous client. `endPreviousSubscriptions` then:

1. Queues `(entityId, END)` or `(entityId, DELD)` into `pendingEvents` (a `TVar (IntMap (NonEmpty ...))` keyed by client ID).
2. Removes the subscription from the displaced client's local `subscriptions` map and cancels any delivery thread.

A separate `sendPendingEvtsThread` flushes `pendingEvents` on a timer (`pendingENDInterval`), delivering END/DELD events to displaced clients via their `sndQ`. If the client's `sndQ` is full, it forks a blocking thread rather than stalling the flush.

For service subscriptions, the displacement event is `ENDS n idsHash` rather than `END`.

### GET vs SUB mutual exclusion

When `GET` is used on a queue, the server creates a `ProhibitSub` subscription. This prevents `SUB` on the same queue in the same connection (`CMD PROHIBITED`). Conversely, if `SUB` is active, `GET` is prohibited. GET clients are not added to `ServerSubscribers` and do not receive END events.

---

## Subscription-driven delivery

**Source**: [Server.hs](../../src/Simplex/Messaging/Server.hs)

The router delivers at most one unacknowledged message per subscription. The `delivered :: TVar (Maybe (MsgId, SystemSeconds))` in each `Sub` record is the gate: `Just _` means a message is in flight (awaiting ACK), `Nothing` means the next message can be delivered.

### Three delivery triggers

**1. SUB** - `subscribeQueueAndDeliver`: after registering the subscription, the server peeks the first pending message (`tryPeekMsg`). If one exists, it is delivered alongside the `SOK` response in the same transmission batch. `setDelivered` records the message ID and timestamp.

**2. ACK** - `acknowledgeMsg`: when the client ACKs a message, the server clears `delivered`, then calls `tryDelPeekMsg` which deletes the ACK'd message AND peeks the next. If a next message exists, it is immediately delivered in the ACK response and `setDelivered` is called again. This means ACK responses can piggyback the next message - minimizing round-trips.

**3. SEND to empty queue** - `tryDeliverMessage`: when a sender writes a message to a previously empty queue (`wasEmpty = True`), the server attempts to push it to the subscribed recipient immediately.

### Sync/async split in tryDeliverMessage

`tryDeliverMessage` has a three-phase structure optimized for the common case:

**Phase 1 - outside STM**: `getSubscribedClient` reads the `SubscribedClients` TMap via `readTVarIO` (IO, not STM). If no subscriber exists, the function returns immediately without entering any STM transaction. This avoids transaction overhead for queues with no active subscriber.

**Phase 2 - STM transaction** (`deliverToSub`): reads the client TVar (inside STM, so the transaction re-evaluates if the subscriber changes), checks `subThread == NoSub` and `delivered == Nothing`. Then:

- If the client's `sndQ` is **not full**: delivers the message directly in the same STM transaction (`writeTBQueue sndQ`), sets `delivered`. No thread is needed. This is the fast path.
- If the client's `sndQ` is **full**: sets `subThread = SubPending` and returns the client + sub for phase 3.

**Phase 3 - forked thread** (`forkDeliver`): a `deliverThread` is spawned that blocks until the `sndQ` has room. Before delivering, it re-checks that the subscriber is still the same client and `delivered` is still `Nothing` - handling the race where the client disconnected and a new one subscribed between phases 2 and 3.

### Per-queue encryption

The server encrypts every message before delivery using `encryptMsg`: `XSalsa20-Poly1305` with the per-queue DH shared secret (`rcvDhSecret` from `QueueRec`) and a nonce derived from the message ID. This is the server-to-recipient transport encryption layer - independent of the end-to-end encryption between sender and recipient.

---

## Cross-layer subscription flow

**Source**: [Agent.hs](../../src/Simplex/Messaging/Agent.hs), [Agent/Client.hs](../../src/Simplex/Messaging/Agent/Client.hs), [Client.hs](../../src/Simplex/Messaging/Client.hs)

### Subscribe path (agent → router)

```
subscribeConnections'
  ├── getConnSubs (DB) → load RcvQueueSub per connection
  └── subscribeConnections_
        ├── partition: send-only/new → immediate results; duplex/rcv → subscribe
        ├── resumeDelivery, resumeConnCmds
        └── subscribeQueues
              ├── checkQueues (filter GET-locked queues)
              ├── batchQueues by SMPTransportSession
              ├── addPendingSubs (mark pending in currentSubs)
              └── mapConcurrently per session:
                    subscribeSessQueues_
                      ├── getSMPServerClient (get/create TCP connection)
                      ├── subscribeSMPQueues (protocol client: batch TLS write)
                      ├── processSubResults (STM: pending → active, record failures)
                      └── notify UP (for newly active connections)
```

**Batching**: `batchQueues` groups queues by `SMPTransportSession = (UserId, SMPServer, Maybe ByteString)`. The third field carries the connection ID in entity-session mode (each connection gets its own TCP session) or `Nothing` in shared mode (all queues to the same server share one session). Per-session batches are subscribed concurrently via `mapConcurrently`.

**Protocol client**: `subscribeSMPQueues` maps each queue to a `SUB` command, batches them into physical TLS writes (respecting server block size limits via `batchTransmissions'`), and awaits responses concurrently. `processSUBResponse_` classifies responses: `OK`/`SOK serviceId` (success), `MSG` (immediate message delivery piggybacked on response), or error.

### Receive path (router → application)

```
Router MSG → TLS → protocol client rcvQ
  → processMsg: server push (empty corrId) → STEvent → msgQ
  → subscriber thread (Agent.hs):
      readTBQueue msgQ → processSMPTransmissions
        ├── STEvent MSG → processSMP → withConnLock → decrypt → subQ → Application
        ├── STEvent END → removeSubscription → subQ END
        ├── STEvent DELD → removeSubscription → subQ DELD
        └── STResponse SUB OK → processSubOk → addActiveSub → accumulate UP
```

The protocol client's `processMsg` thread classifies each incoming transmission:
- **Non-empty corrId**: response to a pending command - delivered to the waiting `getResponse` caller via `responseVar`.
- **Empty corrId**: server-initiated push (MSG, END, DELD, ENDS) - wrapped as `STEvent` and forwarded to `msgQ`.
- **Expired/unexpected responses**: also forwarded to `msgQ` as `STResponse`.

The agent's `subscriber` thread reads from `msgQ` and processes all events under `agentOperationBracket AORcvNetwork`.

### Dual UP event sources

UP events can originate from two paths:
- **Synchronous** (`subscribeSessQueues_`): after `processSubResults` promotes pending → active, notifies `UP srv connIds` for newly active connections. Used during initial subscription.
- **Asynchronous** (`processSMPTransmissions`): when SUB responses arrive via `msgQ` (e.g., after reconnection), `processSubOk` promotes pending → active and accumulates `upConnIds`, which are batch-notified at the end of the transmission batch.

Both paths guard against duplicates: they only emit UP for connections that were not already in `activeSubs`.

---

## Reconnection and resubscription

**Source**: [Server.hs](../../src/Simplex/Messaging/Server.hs), [Agent/Client.hs](../../src/Simplex/Messaging/Agent/Client.hs)

### Server-side disconnect cleanup

When a client disconnects (`clientDisconnected`):

1. `connected = False` - any STM transaction reading this TVar re-evaluates.
2. All `subscriptions` and `ntfSubscriptions` are swapped to empty maps.
3. Each subscription's delivery thread is killed (`cancelSub`).
4. `deleteSubcribedClient` sets each queue's `TVar (Maybe Client)` to `Nothing` and removes the entry from the `SubscribedClients` map. The `sameClient` check (comparing `clientId`) prevents removing a newer subscriber that connected after the disconnect.
5. The client is removed from `subClients` IntSet.

After disconnect, the queue's messages remain stored. The next client to SUB the same queue will receive the first pending message in the SUB response.

### Agent-side reconnection

When the protocol client detects a TLS disconnect, `smpClientDisconnected` fires in the agent:

1. `removeSessVar` with CAS check (monotonic `sessionVarId` prevents stale callbacks from removing newer clients).
2. `setSubsPending` demotes all active subscriptions for the matching session to pending in `currentSubs`.
3. `DOWN srv connIds` is sent to the application for affected connections.
4. Resubscription begins - the mechanism depends on transport session mode:
   - **Entity-session mode**: `resubscribeSMPSession` spawns a persistent worker thread.
   - **Shared mode**: directly calls `subscribeQueues` and `subscribeClientService` without a persistent worker.

In entity-session mode, the resubscription worker loops with exponential backoff until all pending subscriptions are resubscribed:

1. Gets or creates a new SMP client connection to the server.
2. Reads pending subscriptions for the session.
3. Calls `subscribeSessQueues_` with `withEvents = True` to re-send SUB commands.
4. On success, subscriptions move from pending → active and `UP` events are emitted.
5. On temporary error, backs off and retries.
6. Worker self-cleans on exit via `removeSessVar`.

### Stale response protection

Both subscription paths (synchronous `processSubResults` and asynchronous `processSubOk`) verify that the queue is still pending in `currentSubs` for the **current** session before promoting to active. If a session was replaced between sending SUB and receiving the response, the stale response is silently discarded. This prevents a response from an old TLS session from marking a queue as active when it should be pending for the new session.

---

## Service subscriptions

**Source**: [Server.hs](../../src/Simplex/Messaging/Server.hs), [Protocol.hs](../../src/Simplex/Messaging/Protocol.hs)

Service subscriptions are a bulk mechanism where one `SUBS n idsHash` command subscribes all queues associated with a service identity. The service identity is derived from a long-term TLS client certificate presented during the transport handshake.

### How service subscriptions differ from individual subscriptions

| Aspect | Individual (SUB) | Service (SUBS) |
|--------|------------------|----------------|
| Granularity | One queue per SUB command | All associated queues in one command |
| Subscriber tracking | `queueSubscribers` (keyed by QueueId) | `serviceSubscribers` (keyed by ServiceId) |
| Displacement signal | `END` per queue | `ENDS n idsHash` per service |
| Message delivery | Immediate (first message in SUB response) | Iterative (`deliverServiceMessages` iterates all queues, sends `ALLS` when complete) |
| Association | Implicit (queue + subscriber) | Explicit (`rcvServiceId` in QueueRec, set via `setQueueService`) |

### SUBS flow on the router

1. `sharedSubscribeService` checks the actual queue count and IDs hash against the stored service state, and enqueues a `CSService` event to `subQ` for `serverThread` to process (registration in `serviceSubscribers` happens asynchronously).
2. If this is a new service subscription (not previously subscribed): `deliverServiceMessages` iterates all service-associated queues via `foldRcvServiceMessages`, creates per-queue `Sub` entries, and delivers pending messages.
3. After iteration completes, `ALLS` is sent to signal the client that all pending messages have been delivered.

For notification servers, `NSUBS` uses the same `sharedSubscribeService` for registration but does not deliver pending messages (no `deliverServiceMessages` call) - notification subscriptions only register for future `NMSG` events.

For service certificate lifecycle and agent-side service management, see [client-services.md](client-services.md).
