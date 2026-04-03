# Notifications

How push notifications work: encryption architecture, SMP server notification infrastructure, NTF server processing, agent subscription supervisor, and push notification delivery. This is the cross-cutting view spanning SMP server, NTF server, agent, and push provider layers.

For service certificate lifecycle and NSUBS bulk subscription, see [client-services.md](client-services.md). For the router subscription model, see [subscriptions.md](subscriptions.md). For the worker framework used by NtfSubSupervisor, see [agent/infrastructure.md](../agent/infrastructure.md#worker-framework).

- [End-to-end flow](#end-to-end-flow)
- [Encryption architecture](#encryption-architecture)
- [SMP server notification infrastructure](#smp-server-notification-infrastructure)
- [NTF server](#ntf-server)
- [Agent NtfSubSupervisor](#agent-ntfsubsupervisor)
- [Push notification processing](#push-notification-processing)

---

## End-to-end flow

**Source**: [Server.hs](../../src/Simplex/Messaging/Server.hs), [Notifications/Server.hs](../../src/Simplex/Messaging/Notifications/Server.hs), [Agent.hs](../../src/Simplex/Messaging/Agent.hs)

### Setup (one-time per device)

1. App calls `registerNtfToken` with device token and `NMInstant` mode.
2. Agent sends `TNEW` to NTF server - NTF server sends verification code via APNs.
3. App receives push notification, extracts code, calls `verifyNtfToken` (sends `TVFY`).
4. Token becomes `NTActive`. Agent calls `initializeNtfSubs` for all active connections.

### Per-connection subscription setup (dual worker pipeline)

```
ntfSubQ (NSCCreate)
  -> NtfSubSupervisor: partitions queues by SMP server
  -> SMP worker: NKEY authKey dhKey -> SMP server
  <- SMP server: NID notifierId srvDhKey
  -> Agent stores ClientNtfCreds (notifierId, rcvNtfDhSecret)
  -> NTF worker: SNEW tknId (server, notifierId) ntfPrivKey -> NTF server
  -> NTF server stores sub, sends NSUB to SMP server
  <- SMP server registers NTF server as notification subscriber
```

### Message notification delivery

```
Sender -> SEND msg (notification=True) -> SMP server
  -> enqueueNotification: encrypt NMsgMeta with rcvNtfDhSecret -> NtfStore
  -> deliverNtfsThread (periodic): NMSG nonce encMeta -> NTF server
  -> ntfSubscriber.receiveSMP: PNMessageData -> addTokenLastNtf -> pushQ
  -> ntfPush: encrypt PNMessageData list with tknDhSecret -> APNs -> device
  -> App wakes, calls getNotificationConns
  -> Agent: decrypt with tknDhSecret, then decrypt encMeta with rcvNtfDhSecret
  -> App fetches actual message from SMP server
```

---

## Encryption architecture

**Source**: [Server.hs](../../src/Simplex/Messaging/Server.hs), [Notifications/Server.hs](../../src/Simplex/Messaging/Notifications/Server.hs), [Agent.hs](../../src/Simplex/Messaging/Agent.hs)

The notification system uses two independent encryption layers to ensure no single entity (other than the recipient) can correlate queue identity with message metadata.

### Layer 1: SMP server to recipient (rcvNtfDhSecret)

When the agent sends `NKEY authKey dhKey` to the SMP server, both sides compute a DH shared secret (`rcvNtfDhSecret`). The SMP server uses this to encrypt `NMsgMeta {msgId, msgTs}` inside each `NMSG`. The NTF server cannot decrypt this - it forwards the encrypted blob opaquely.

### Layer 2: NTF server to device (tknDhSecret)

During `TNEW`, the agent and NTF server establish `tknDhSecret` via DH exchange. The NTF server encrypts the entire `PNMessageData` list (containing `smpQueue`, `ntfTs`, `nmsgNonce`, `encNMsgMeta`) with this secret before sending via APNs.

### What each entity can see

| Entity | Queue identity | Message metadata | Message content |
|--------|---------------|-----------------|----------------|
| SMP server | Yes (stores queue) | Yes (creates NMsgMeta) | No (E2E encrypted) |
| NTF server | Yes (smpQueue in PNMessageData) | No (encNMsgMeta opaque) | No |
| Push provider (APNs) | No (tknDhSecret encrypted) | No | No |
| Recipient | Yes | Yes (two-layer decrypt) | Yes |

### Device-side two-layer decryption

In `getNotificationConns`, the agent decrypts in two steps:
1. Decrypt push payload with `tknDhSecret` (NTF-to-device) to get `PNMessageData` list
2. For each entry, decrypt `encNMsgMeta` with `rcvNtfDhSecret` (SMP-to-recipient) to get `NMsgMeta {msgId, msgTs}`

---

## SMP server notification infrastructure

**Source**: [Server.hs](../../src/Simplex/Messaging/Server.hs), [Server/NtfStore.hs](../../src/Simplex/Messaging/Server/NtfStore.hs)

### Notifier credentials on queues

Each queue's `QueueRec` has an optional `notifier :: Maybe NtfCreds` containing:
- `notifierId` - the entity ID the NTF server uses for NSUB
- `notifierKey` - public auth key for verifying NSUB commands
- `rcvNtfDhSecret` - shared secret for encrypting notification metadata
- `ntfServiceId` - optional service association for bulk NSUBS

`NKEY` creates these credentials (generating the DH shared secret server-side). `NDEL` removes them and deletes pending notifications from NtfStore.

### Notification generation

When a sender sends a message with `notification msgFlags == True`, `enqueueNotification` creates a `MsgNtf` containing `NMsgMeta {msgId, msgTs}` encrypted with `rcvNtfDhSecret` and a random nonce. The notification is stored in the in-memory `NtfStore` (a `TMap NotifierId (TVar [MsgNtf])`) - multiple notifications can accumulate per queue.

### deliverNtfsThread - periodic batch delivery

Runs every `ntfDeliveryInterval` microseconds. Each cycle:

1. Reads all pending notifications from `NtfStore`.
2. Calls `getQueueNtfServices` to partition notifications by service association.
3. For service-associated queues: delivers NMSG to the subscribed service client via `serviceSubscribers`.
4. For non-service queues: iterates through `subClients` and delivers to individually-subscribed clients.
5. Each NMSG contains `(ntfNonce, encNMsgMeta)` - the encrypted notification metadata.
6. All pending notifications for a given client are delivered in one cycle (no per-cycle cap). Transmissions are batched into TLS frames by the transport layer.
7. Notifications for deleted queues (discovered during partitioning) are cleaned up from `NtfStore`.

This is periodic, not event-driven - there is a deliberate latency trade-off to reduce overhead. Notifications are not pushed immediately when a message arrives.

---

## NTF server

**Source**: [Notifications/Server.hs](../../src/Simplex/Messaging/Notifications/Server.hs), [Notifications/Server/Env.hs](../../src/Simplex/Messaging/Notifications/Server/Env.hs)

### Architecture

Three main concurrent threads:

- **ntfSubscriber**: receives NMSG events from SMP servers and SMP client agent state changes
- **ntfPush**: sends push notifications (APNs/Firebase) from a bounded queue
- **periodicNtfsThread**: sends periodic "check messages" background notifications based on per-token cron intervals

### Token lifecycle

```
NTRegistered (after TNEW, verification push sent)
  -> NTConfirmed (APNs accepts verification push delivery)
  -> NTActive (after TVFY with correct code)

Any state -> NTInvalid (push provider reports token invalid during any push)
Any state -> NTExpired (provider reports token expired)
```

`NTNew` exists only on the agent side (pre-registration); the NTF server creates tokens directly in `NTRegistered`. `NTInvalid` can be reached from any state where a push delivery is attempted (including `NTRegistered` during verification), not only from `NTActive`.

`allowTokenVerification` permits TVFY from `NTRegistered`, `NTConfirmed`, and `NTActive` states. `TRPL` replaces the device token (e.g., after OS token refresh) while keeping all subscriptions - it resets status to `NTRegistered` and re-sends verification.

### Subscription handling

`SNEW tknId (SMPQueueNtf smpServer notifierId) ntfPrivateKey` creates a subscription record and delegates to the SMP subscriber infrastructure:

1. `subscribeNtfs` gets or creates a per-SMP-server `SMPSubscriber` thread.
2. The subscriber thread reads from its queue and calls `subscribeQueuesNtfs`, which sends `NSUB` to the SMP server using the `ntfPrivateKey` provided by the agent.
3. `SCHK` returns the current subscription status; the agent uses this for periodic health checks.

### ntfSubscriber - receiving from SMP

Runs two concurrent sub-threads:

**receiveSMP**: reads from the SMP client agent's `msgQ`:
- `NMSG nmsgNonce encNMsgMeta`: Creates `PNMessageData`, calls `addTokenLastNtf` to look up the owning token and aggregate with other recent notifications, then enqueues `PNMessage` to `pushQ`.
- `END`: Updates subscription status to `NSEnd`.
- `DELD`: Updates subscription status to `NSDeleted`.

**receiveAgent**: reads from `agentQ` for client state changes:
- `CAConnected`: Logs reconnection (no status update).
- `CADisconnected`: Updates affected subscriptions to `NSInactive`.
- `CASubscribed`: Marks subscriptions as `NSActive`.
- `CASubError`: Updates individual subscription errors.
- `CAServiceDisconnected` / `CAServiceSubError`: Logs only.
- `CAServiceSubscribed`: Logs, warns on count/hash mismatches.
- `CAServiceUnavailable`: Calls `removeServiceAndAssociations` - nuclear recovery (see [client-services.md](client-services.md#notification-server-usage)).

### Token-level notification batching

`addTokenLastNtf` is critical for push efficiency. The `last_notifications` table is keyed by `(token_id, subscription_id)` and UPSERT'd - each subscription contributes only its most recent notification. When a push is sent, multiple `PNMessageData` entries for the same token are combined into a single APNs payload. This means one push notification can carry metadata for messages across multiple queues.

### Push notification types

| Type | Content | Trigger |
|------|---------|---------|
| `PNVerification` | Encrypted registration code | TNEW / TRPL |
| `PNMessage` | Encrypted `PNMessageData` list | NMSG from SMP server |
| `PNCheckMessages` | `{"checkMessages": true}` | periodicNtfsThread (cron) |

`PNMessage` is sent as a mutable-content alert ("Encrypted message or another app event"). `PNVerification` and `PNCheckMessages` are silent background notifications.

---

## Agent NtfSubSupervisor

**Source**: [Agent/NtfSubSupervisor.hs](../../src/Simplex/Messaging/Agent/NtfSubSupervisor.hs), [Agent/Env/SQLite.hs](../../src/Simplex/Messaging/Agent/Env/SQLite.hs)

### Supervisor structure

```
NtfSupervisor
  ntfTkn           :: TVar (Maybe NtfToken)       -- current active token
  ntfSubQ          :: TBQueue (NtfSupervisorCommand, NonEmpty ConnId)
  ntfWorkers       :: TMap NtfServer Worker        -- per-NTF-server
  ntfSMPWorkers    :: TMap SMPServer Worker         -- per-SMP-server
  ntfTknDelWorkers :: TMap NtfServer Worker         -- token deletion
```

The main loop (`runNtfSupervisor`) reads commands from `ntfSubQ` and dispatches to `processNtfCmd`. Commands are only enqueued when `hasInstantNotifications` is true (active token in `NMInstant` mode).

### Dual worker pipeline

SMP workers and NTF workers form a two-stage pipeline, communicating through the DB-persisted `NtfSubAction`:

**Stage 1 - SMP workers** (`runNtfSMPWorker`):
- `NSASmpKey`: Generates auth+DH key pairs, sends `NKEY` to SMP server, stores `ClientNtfCreds`, then sets action to `NSANtf NSACreate` and kicks NTF workers.
- `NSASmpDelete`: Resets notifier credentials, sends `NDEL` to SMP server, deletes the subscription.

**Stage 2 - NTF workers** (`runNtfWorker`):
- `NSACreate`: Sends `SNEW` to NTF server, stores `ntfSubId`, schedules first check.
- `NSACheck`: Sends `SCHK` to NTF server. AUTH errors from the check are handled separately - those subscriptions are immediately recreated via `recreateNtfSub`. For successful checks, if the subscription is in a subscribe-able status (`NSNew`, `NSPending`, `NSActive`, `NSInactive`), reschedules next check. Any other status (ended, deleted, service error, etc.) also triggers recreation from scratch (resets to `NSASmpKey`).

### Cross-protocol link

The SMP workers (`enableQueuesNtfs` / `disableQueuesNtfs` in `Agent/Client.hs`) use the agent's normal SMP client pool to send `NKEY`/`NDEL` to SMP servers. This is the cross-protocol dependency visible in the agent architecture - notification subscription setup requires SMP protocol operations.

### Subscription state machine

```
(new connection, notifications enabled)
  -> NSASMP NSASmpKey        -- SMP worker: send NKEY to SMP server
  -> NSANtf NSACreate        -- NTF worker: send SNEW to NTF server
  -> NSANtf NSACheck         -- NTF worker: periodic SCHK
  -> (steady state)

(notifications disabled or connection deleted)
  -> NSASMP NSASmpDelete     -- SMP worker: send NDEL to SMP server
  -> (subscription deleted)

(check fails: subscription ended/deleted/auth)
  -> NSASMP NSASmpKey        -- restart from scratch
```

Each action is persisted in the store before execution, so the pipeline resumes after agent restart. Workers use `withRetryInterval` for temporary errors.

### NotificationsMode

- **NMInstant**: NTF server maintains active NSUB subscriptions and pushes immediately when messages arrive. Requires the full dual-worker pipeline.
- **NMPeriodic**: No NSUB subscriptions. NTF server sends periodic `PNCheckMessages` background notifications based on `tknCronInterval` (set via `TCRN`). Device wakes and fetches messages on its own schedule.

Switching from NMInstant to NMPeriodic triggers `deleteNtfSubs` which flushes the `ntfSubQ` and sends `NSCSmpDelete` commands through the async worker pipeline to remove all notification subscriptions.

---

## Push notification processing

**Source**: [Agent.hs](../../src/Simplex/Messaging/Agent.hs), [Notifications/Server.hs](../../src/Simplex/Messaging/Notifications/Server.hs)

### getNotificationConns - device wake path

When the device wakes from a push notification, the app calls `getNotificationConns`:

1. Retrieves the active token's `ntfDhSecret`.
2. Decrypts the push payload using `ntfDhSecret` and the nonce from the APNs notification.
3. Parses the result as `NonEmpty PNMessageData` (semicolon-separated list).
4. For each entry:
   - Looks up the `RcvQueue` by `smpQueue` (`SMPServer` + `notifierId`) via `getNtfRcvQueue`.
   - Decrypts `encNMsgMeta` using the queue's `rcvNtfDhSecret` and `nmsgNonce` to get `NMsgMeta {msgId, msgTs}`.
5. Filters "init" notifications (all but the last) by comparing `msgTs` against `lastBrokerTs` - notifications with timestamps not newer than the last seen broker timestamp are discarded. If `lastBrokerTs` is not set, the notification passes through.
6. Returns `NonEmpty NotificationInfo` for the app to fetch actual messages.

### Token registration state machine

`registerNtfToken` handles multiple states based on `(ntfTokenId, ntfTknAction)`:

- `(Nothing, Just NTARegister)`: Re-register (first attempt failed after key generation).
- `(Just tknId, Nothing)`: Same device token - re-register; different token - replace via `TRPL`.
- `(Just tknId, Just NTAVerify code)`: Same device token - verify; different token - replace via `TRPL`.
- `(Just tknId, Just NTACheck)`: Same device token - check status, then initialize or delete subscriptions based on mode; different token - replace via `TRPL`.

All `(Just tknId, ...)` branches check whether the device token changed and fall through to `replaceToken` on mismatch.

### ntfSubQ writers

The `ntfSubQ` is written by multiple paths in `Agent.hs`, all via `sendNtfSubCommand`:
- `sendNtfCreate` - during `subscribeConnections_` and `subscribeAllConnections'` (writes both `NSCCreate` and `NSCSmpDelete` depending on per-connection `enableNtfs`)
- `toggleConnectionNtfs'` - when the app enables/disables notifications for a connection
- `initializeNtfSubs` / `deleteNtfSubs` - during token activation and mode switching
- `newQueueNtfSubscription` - when joining a new connection
- `unsubNtfConnIds` - writes `NSCDeleteSub` during connection deletion
- `ICQDelete` async command handler - during queue rotation
