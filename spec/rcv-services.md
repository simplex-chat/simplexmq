# Receive Services (Service Certificates)

> Cross-cutting specification for the rcv-services feature: service certificates enabling high-volume SMP clients (notification routers, chat relays, directory services) to bulk-subscribe to queues.

**Source branch**: `rcv-services`
**Protocol reference**: [`protocol/simplex-messaging.md`](../protocol/simplex-messaging.md)
**Phase**: 3.0a (Protocol + Transport + Server), 3.0b (Client + Agent + Store + NTF)

## Overview

A **service client** is a high-volume SMP client that presents a TLS client certificate during handshake. The server assigns it a persistent `ServiceId` derived from the certificate fingerprint. Individual queues are then **associated** with this ServiceId via per-queue `SUB` commands carrying a service signature. Once associated, the service client can **bulk-subscribe** all its queues in a single `SUBS` command instead of issuing per-queue `SUB` commands on each reconnection.

This matters for notification servers, chat relays, and directory services that manage thousands to millions of queues per SMP server. Without service certificates, reconnection requires O(n) SUB commands; with them, it requires O(1) SUBS.

### Design summary

```
Service client                    SMP Server
    |                                  |
    |---- TLS + service cert --------->|  Three-way handshake
    |<--- ServiceId -------------------|  (Transport layer)
    |                                  |
    |---- SUB + service sig ---------->|  Per-queue association
    |<--- SOK(ServiceId) --------------|  (Protocol layer, one-time)
    |     ...repeat per queue...       |
    |                                  |
    |---- SUBS count idsHash --------->|  Bulk subscribe
    |<--- SOKS count' idsHash' --------|  (count/hash from server)
    |<--- MSG ... MSG ... MSG ---------|  Buffered messages
    |<--- ALLS ------------------------|  All delivered
    |                                  |
```

## Version gates

| Constant | Value | Gate | Source |
|----------|-------|------|--------|
| `serviceCertsSMPVersion` | 16 | Service handshake, `SOK`, `useServiceAuth` | Transport.hs:214 |
| `rcvServiceSMPVersion` | 19 | `SUBS`/`NSUBS` parameters, `SOKS`/`ENDS` idsHash, messaging service role in handshake | Transport.hs:223 |

The two-version split means:
- v16-18 servers accept service certificates and per-queue `SUB` with service auth, but `SUBS`/`NSUBS` send no count/hash parameters (bare command tag only).
- v19+ servers send and receive full count + idsHash with `SUBS`/`NSUBS`/`SOKS`/`ENDS`.
- Messaging services (`SRMessaging`) are only included in the client handshake at v >= 19. Notifier services (`SRNotifier`) are included at v >= 16.

## Types

### ServiceId

`ServiceId` is an `EntityId` (24-byte base64url-encoded identifier) assigned by the server during the three-way handshake. It is derived from the service certificate fingerprint via `getCreateService` in QueueStore.

### SMPServiceRole

```haskell
data SMPServiceRole = SRMessaging | SRNotifier | SRProxy
-- Wire: "M" | "N" | "P"
```
Source: Transport.hs:594

### Party (service-related constructors)

```haskell
data Party = ... | RecipientService | NotifierService | ...
```
Source: Protocol.hs:335-346

The `ServiceParty` type family constrains to `RecipientService | NotifierService` only:
```haskell
type family ServiceParty (p :: Party) :: Constraint where
  ServiceParty RecipientService = ()
  ServiceParty NotifierService = ()
  ServiceParty p = (Int ~ Bool, TypeError ...)  -- compile-time error
```
Source: Protocol.hs:430-434

### IdsHash

16-byte XOR of MD5 hashes, used for drift detection between client and server subscription state.

```haskell
newtype IdsHash = IdsHash {unIdsHash :: BS.ByteString}

instance Semigroup IdsHash where
  (IdsHash s1) <> (IdsHash s2) = IdsHash $! BS.pack $ BS.zipWith xor s1 s2

instance Monoid IdsHash where
  mempty = IdsHash $ BS.replicate 16 0

queueIdHash :: QueueId -> IdsHash
queueIdHash = IdsHash . C.md5Hash . unEntityId
```
Source: Protocol.hs:1501-1526

**Key property**: XOR is self-inverse, so `addServiceSubs` and `subtractServiceSubs` both use `<>` (XOR) for the hash component:
```haskell
addServiceSubs (n', idsHash') (n, idsHash) = (n + n', idsHash <> idsHash')
subtractServiceSubs (n', idsHash') (n, idsHash)
  | n > n' = (n - n', idsHash <> idsHash')
  | otherwise = (0, mempty)
```
Source: Protocol.hs:1528-1534

### ServiceSub / ServiceSubResult / ServiceSubError

Client-side types for comparing expected vs actual subscription state:
```haskell
data ServiceSub = ServiceSub
  { smpServiceId :: ServiceId,
    smpQueueCount :: Int64,
    smpQueueIdsHash :: IdsHash }

data ServiceSubResult = ServiceSubResult (Maybe ServiceSubError) ServiceSub

data ServiceSubError
  = SSErrorServiceId {expectedServiceId, subscribedServiceId :: ServiceId}
  | SSErrorQueueCount {expectedQueueCount, subscribedQueueCount :: Int64}
  | SSErrorQueueIdsHash {expectedQueueIdsHash, subscribedQueueIdsHash :: IdsHash}
```
Source: Protocol.hs:1476-1499

`serviceSubResult` compares expected vs actual, returning the first mismatch (priority: serviceId > count > idsHash).

### STMService (QueueStore)

```haskell
data STMService = STMService
  { serviceRec :: ServiceRec,
    serviceRcvQueues :: TVar (Set RecipientId, IdsHash),
    serviceNtfQueues :: TVar (Set NotifierId, IdsHash) }
```
Source: QueueStore/STM.hs:64-68

Tracks the set of queue IDs and their cumulative XOR hash per service, per role (receive vs notify).

## Transport layer: service handshake

### Three-way handshake

Standard SMP handshake is two messages: server sends `SMPServerHandshake`, client sends `SMPClientHandshake`. Service clients extend this to three messages:

1. **Server -> Client**: `SMPServerHandshake` (standard, with session ID and auth key)
2. **Client -> Server**: `SMPClientHandshake` with `clientService :: Maybe SMPClientHandshakeService`
3. **Server -> Client**: `SMPServerHandshakeResponse {serviceId}` or `SMPServerHandshakeError {handshakeError}`

Source: Transport.hs:752-791 (server), Transport.hs:796-848 (client)

### SMPClientHandshakeService

```haskell
data SMPClientHandshakeService = SMPClientHandshakeService
  { serviceRole :: SMPServiceRole,
    serviceCertKey :: CertChainPubKey }
```
Source: Transport.hs:582-585

The `serviceCertKey` contains the TLS client certificate chain and a proof-of-possession: the service's Ed25519 session key signed by the service's X.509 signing key (`C.signX509 serviceSignKey $ C.publicToX509 k`).

### Server-side validation (`getClientService`)

1. Verify certificate chain matches TLS peer certificate: `getPeerCertChain c == cc`
2. Extract identity certificate and service key from chain
3. Verify signed session key: `C.verifyX509 serviceCertKey exact`
4. Compute fingerprint: `XV.getFingerprint idCert X.HashSHA256`
5. Call `getService` callback (QueueStore.getCreateService) to get/create ServiceId
6. Send `SMPServerHandshakeResponse {serviceId}` back to client

Source: Transport.hs:775-791

### Client-side reception (`getClientService`)

Client receives either `SMPServerHandshakeResponse {serviceId}` (success) or `SMPServerHandshakeError {handshakeError}` (failure). On success, stores `THClientService {serviceId, serviceRole, serviceCertHash, serviceKey}`.

Source: Transport.hs:843-847

### Version-gated service role filtering (`mkClientService`)

```haskell
mkClientService v (ServiceCredentials {serviceRole, ...}, (k, _))
  | serviceRole == SRMessaging && v < rcvServiceSMPVersion = Nothing
  | otherwise = Just SMPClientHandshakeService {..}
```
Source: Transport.hs:838-842

Messaging services are suppressed below v19. Notifier services are sent at v16+.

### ServiceCredentials (client-side persistent state)

```haskell
data ServiceCredentials = ServiceCredentials
  { serviceRole :: SMPServiceRole,
    serviceCreds :: T.Credential,  -- TLS certificate + private key
    serviceCertHash :: XV.Fingerprint,
    serviceSignKey :: C.APrivateSignKey }
```
Source: Transport.hs:587-592

## Protocol layer: commands and messages

### Commands

| Command | Party | Entity | Auth | Description |
|---------|-------|--------|------|-------------|
| `SUB` | Recipient | QueueId | Queue key + optional service sig | Subscribe single queue; if service sig present, associates queue with service |
| `NSUB` | Notifier | NotifierId | Queue key + optional service sig | Subscribe single notifier; if service sig present, associates with service |
| `NEW` | Creator | NoEntity | Queue key + optional service sig | Create queue; if service sig present, associates at creation |
| `SUBS count idsHash` | RecipientService | ServiceId | Service session key | Bulk-subscribe all associated receive queues |
| `NSUBS count idsHash` | NotifierService | ServiceId | Service session key | Bulk-subscribe all associated notifier queues |

### Double authenticator (`useServiceAuth`)

Only `NEW`, `SUB`, and `NSUB` carry a service signature (when sent from a service connection):
```haskell
useServiceAuth = \case
  Cmd _ (NEW _) -> True
  Cmd _ SUB -> True
  Cmd _ NSUB -> True
  _ -> False
```
Source: Protocol.hs:1737-1742

For these commands, `tEncodeAuth` appends both the primary queue key signature and an optional service Ed25519 signature. `SUBS`/`NSUBS` use the ServiceId as entity and are signed only by the service session key.

### Broker messages (responses)

| Message | Fields | Description |
|---------|--------|-------------|
| `SOK` | `Maybe ServiceId` | Per-queue subscription success; `Just serviceId` when queue was associated with service |
| `SOKS` | `Int64, IdsHash` | Bulk subscription success; server's actual count and hash |
| `ALLS` | (none) | Marker: all buffered messages for this SUBS have been delivered |
| `END` | (none) | Per-queue subscription ended (another client subscribed) |
| `ENDS` | `Int64, IdsHash` | Service subscription ended (another service client took over); server's count and hash at takeover time |

### Wire encoding (version-dependent)

**SUBS/NSUBS encoding:**
```
v >= 19: tag SP count idsHash
v < 19:  tag  (bare, no parameters)
```
Source: Protocol.hs:1769-1771, 1787-1789

**SOKS/ENDS encoding:**
```
v >= 19: tag SP count idsHash
v < 19:  tag SP count  (no idsHash)
```
Source: Protocol.hs:1951-1953

**SOKS/ENDS decoding:**
```
v >= 19: tag -> resp <$> _smpP <*> smpP  (count + idsHash)
v < 19:  tag -> resp <$> _smpP <*> pure mempty  (count only, mempty hash)
```
Source: Protocol.hs:1996-1998

## Server layer

### Client state (Env/STM.hs)

Each connected client tracks:
```haskell
data Client s = Client
  { ...
    serviceSubscribed :: TVar Bool,          -- has SUBS been received?
    ntfServiceSubscribed :: TVar Bool,       -- has NSUBS been received?
    serviceSubsCount :: TVar (Int64, IdsHash),    -- running (count, hash) for receive queues
    ntfServiceSubsCount :: TVar (Int64, IdsHash), -- running (count, hash) for notifier queues
    ... }
```
Source: Env/STM.hs:437-456

Server-global state:
```haskell
data ServerSubscribers s = ServerSubscribers
  { subQ :: TQueue (ClientSub, ClientId),
    queueSubscribers :: SubscribedClients s,  -- per-queue lookup
    serviceSubscribers :: SubscribedClients s, -- per-service lookup
    totalServiceSubs :: TVar (Int64, IdsHash), -- global service sub count
    subClients :: TVar IntSet,
    pendingEvents :: TVar (IntMap (NonEmpty (EntityId, BrokerMsg))) }
```
Source: Env/STM.hs:362-369

### ClientSub events

```haskell
data ClientSub
  = CSClient QueueId (Maybe ServiceId) (Maybe ServiceId)  -- prev and new service IDs
  | CSDeleted QueueId (Maybe ServiceId)                    -- prev service ID
  | CSService ServiceId (Int64, IdsHash)                   -- service subscription change
```
Source: Env/STM.hs:426-429

These are enqueued into `subQ` and processed by `serverThread` (the subscription event loop).

### SUBS command flow

```
Client sends SUBS count idsHash
  |
  v
subscribeServiceMessages(serviceId, (count, idsHash))          Server.hs:1800
  |
  +-- sharedSubscribeService(SRecipientService, ...)            Server.hs:1849
  |    |
  |    +-- If already subscribed: return cached (count, hash)
  |    |
  |    +-- First time:
  |         +-- getServiceQueueCountHash(party, serviceId)      QueueStore
  |         |    -> returns server's actual (count', idsHash')
  |         |
  |         +-- atomically:
  |         |    writeTVar clientServiceSubscribed True
  |         |    writeTVar clientServiceSubs (count', idsHash')
  |         |
  |         +-- Compute drift stats:
  |         |    count == -1 && match  -> srvSubOk++      (old NTF server)
  |         |    diff > 0              -> srvSubMore++     (server has more)
  |         |    diff < 0              -> srvSubFewer++    (server has fewer)
  |         |    otherwise             -> srvSubDiff++     (count match, hash mismatch)
  |         |
  |         +-- Enqueue CSService event to subQ
  |
  +-- If not already subscribed:
  |    fork "deliverServiceMessages"                           Server.hs:1806
  |      |
  |      +-- foldRcvServiceMessages(serviceId, deliverQueueMsg, acc)
  |           |                                                MsgStore
  |           +-- For each queue in service:
  |           |    +-- Read queue record + first pending message
  |           |    +-- Call deliverQueueMsg(acc, rId, result)   Server.hs:1822
  |           |         |
  |           |         +-- Error -> accumulate ERR
  |           |         +-- No message -> skip
  |           |         +-- Has message:
  |           |              +-- getSubscription(rId)           Server.hs:1835
  |           |              |    If sub exists -> Nothing (skip, already delivering)
  |           |              |    Else -> create new Sub, insert in subscriptions
  |           |              +-- setDelivered sub msg
  |           |              +-- writeTBQueue msgQ [(corrId, rId, MSG ...)]
  |           |
  |           +-- After fold: write ALLS to msgQ
  |
  +-- Return SOKS count' idsHash'
```

### Per-queue SUB with service association

`sharedSubscribeQueue` handles four cases (Server.hs:1738-1798):

**Case 1: Service client, queue already associated with this service** (`queueServiceId == Just serviceId`)
- Duplicate association (retry after timeout/error)
- If no service sub exists yet, increment service queue count and enqueue CSClient
- Stats: `srvAssocDuplicate++`

**Case 2: Service client, queue not yet associated** (new or different service)
- Call `setQueueService(queue, party, Just serviceId)` to update QueueStore
- Increment client's `serviceSubsCount` by `(1, queueIdHash rId)`
- Enqueue CSClient event
- Stats: `srvAssocNew++` or `srvAssocUpdated++`

**Case 3: Non-service client, queue has service association** (downgrade)
- Call `setQueueService(queue, party, Nothing)` to remove association
- Stats: `srvAssocRemoved++`
- Create normal per-queue subscription

**Case 4: Non-service client, no service association** (standard SUB)
- Create/return per-queue subscription as normal

### Message delivery for service queues

When a new message arrives for a queue (`tryDeliverMessage`, Server.hs:1985-2024):

```haskell
getSubscribed = case rcvServiceId qr of
  Just serviceId -> getSubscribedClient serviceId $ serviceSubscribers subscribers
  Nothing -> getSubscribedClient rId $ queueSubscribers subscribers
```

If the queue has `rcvServiceId`, the server looks up the subscriber in `serviceSubscribers` (by ServiceId) rather than `queueSubscribers` (by QueueId).

**On-demand Sub creation** (`newServiceDeliverySub`, Server.hs:2019-2024): When a message arrives for a service queue but no `Sub` exists in the client's `subscriptions` TMap, one is created on the fly. This handles messages arriving after SUBS but before the fold reaches that queue.

### serverThread subscription event loop

`serverThread` (Server.hs:250-351) processes `ClientSub` events from `subQ`:

**CSClient** (per-queue subscription):
- If service association changed: end previous service subscription for that queue
- If new service: increment `totalServiceSubs`, end any per-queue subscriber, cancel previous service subscriber
- If no service: standard per-queue upsert

**CSDeleted** (queue deletion):
- End both queue and service subscriptions

**CSService** (bulk SUBS):
- Subtract changed subs from `totalServiceSubs` (because the client already has them counted)
- Cancel previous service subscriber for this ServiceId (sends ENDS to old client)

**Service takeover** (`cancelServiceSubs`, Server.hs:317-321):
When a new service client subscribes (same ServiceId), the previous client's service subs are zeroed out:
```haskell
cancelServiceSubs serviceId = checkAnotherClient $ \c -> do
  changedSubs <- swapTVar (clientServiceSubs c) (0, mempty)
  pure [(c, CSADecreaseSubs changedSubs, (serviceId, ENDS n idsHash))]
```
The previous client receives `ENDS count idsHash`.

### Client disconnect cleanup

`clientDisconnected` (Server.hs:1090-1121):
1. Set `connected = False`
2. Swap out all subscriptions and ntf subscriptions (clear TMap)
3. Cancel per-queue Subs
4. Update `queueSubscribers` (delete per-queue entries) and `serviceSubscribers` (delete service entry)
5. Subtract client's `serviceSubsCount` from `totalServiceSubs`
6. Kill delivery threads

**Queue-service associations persist**: Only live subscription state is cleaned up. The `rcvServiceId` field on `QueueRec` and the `STMService` queue sets survive disconnect. On reconnection, `SUBS` resubscribes without re-associating.

### Notification service subscription (`NSUBS`)

`subscribeServiceNotifications` (Server.hs:1845-1847) is a thin wrapper around `sharedSubscribeService` with `SNotifierService` party. Unlike `SUBS`, it does NOT fork a delivery thread -- notification delivery is handled by the separate `deliverNtfsThread`.

`deliverNtfsThread` (Server.hs:353) periodically scans `subClients` (which includes service subscribers) and delivers pending notifications.

## QueueStore layer

### getCreateService

Lookup by certificate fingerprint; create if not found (Server/QueueStore/STM.hs:284-310):
1. `TM.lookup fp serviceCerts` -- fast IO lookup
2. If miss: STM transaction to double-check and create
3. If hit: verify service role matches; error `SERVICE` on role mismatch
4. On new service: log via store log

### setQueueService

Updates the `rcvServiceId` (or `ntfServiceId`) field on a `QueueRec` and maintains the service's queue set (Server/QueueStore/STM.hs:312-338):
1. Read queue record
2. If same service -> no-op
3. If different: `removeServiceQueue` from old, `addServiceQueue` to new
4. Update `QueueRec` in-place

### addServiceQueue / removeServiceQueue

Both use `setServiceQueues_` which XORs the queue's `queueIdHash` into the service's running hash (Server/QueueStore/STM.hs:383-398):
```haskell
update (s, idsHash) =
  let !s' = updateSet qId s        -- Set insert/delete
      !idsHash' = queueIdHash qId <> idsHash  -- XOR (self-inverse)
   in (s', idsHash')
```

## Test coverage

### Existing tests (ServerTests.hs)

| Test | Lines | What it covers |
|------|-------|----------------|
| `testServiceDeliverSubscribe` | 682-742 | Create queue as service, reconnect, SUBS, message delivery, ALLS |
| `testServiceUpgradeAndDowngrade` | 744-859 | Regular SUB -> service SUB -> SUBS -> downgrade back to regular SUB |
| `testMessageServiceNotifications` | 1313-1388 | NSUB with service, service takeover (ENDS), NSUBS bulk subscribe |
| `testServiceNotificationsTwoRestarts` | 1390-1434 | NSUBS persistence across two server restarts |

### Test gaps

| Gap | Severity | Description |
|-----|----------|-------------|
| **TG-SVC-01** | High | No concurrent SUBS + regular SUB on same queue -- race between fold delivery and per-queue subscription |
| **TG-SVC-02** | High | No queue deletion during SUBS fold -- what happens when a queue is deleted mid-fold? |
| **TG-SVC-03** | Medium | No duplicate SUBS test -- what if client sends SUBS twice? (code returns cached count) |
| **TG-SVC-04** | Medium | No drift detection verification -- no test checks that stats are actually logged on count/hash mismatch |
| **TG-SVC-05** | Medium | No SUBS with 0 queues -- edge case where service has no associated queues |
| **TG-SVC-06** | Medium | No concurrent message delivery during fold -- messages sent while fold is in progress |
| **TG-SVC-07** | Low | No large-scale test -- fold performance with 10k+ queues |
| **TG-SVC-08** | Low | No test for `subtractServiceSubs` underflow (`n <= n'` -> `(0, mempty)`) |

## Security invariants

| ID | Invariant | Enforced by | Test |
|----|-----------|-------------|------|
| **SI-SVC-01** | Service certificate must match TLS peer certificate | `getClientService`: `getPeerCertChain c == cc` | Implicit in all service tests |
| **SI-SVC-02** | Service session key proof-of-possession: signed by X.509 key | `C.verifyX509 serviceCertKey exact` in `getClientService` | Implicit |
| **SI-SVC-03** | Only NEW, SUB, NSUB carry service signature | `useServiceAuth` pattern match | testServiceDeliverSubscribe (ERR SERVICE on unsigned) |
| **SI-SVC-04** | SUBS/NSUBS require service session key, not queue key | Entity is ServiceId, auth is service key | testServiceDeliverSubscribe (ERR CMD NO_AUTH on wrong key) |
| **SI-SVC-05** | Service role mismatch rejected | `getCreateService`: role check -> `Left SERVICE` | testServiceDeliverSubscribe (ERR SERVICE on wrong role) |
| **SI-SVC-06** | Non-service client cannot send SUBS | `ERR SERVICE` when no service handshake | testServiceUpgradeAndDowngrade (ERR SERVICE on plain client) |
| **SI-SVC-07** | Queue-service associations persist across disconnect | `clientDisconnected` only clears live state | testServiceNotificationsTwoRestarts |
| **SI-SVC-08** | Service takeover sends ENDS to previous client | `cancelServiceSubs` -> ENDS | testMessageServiceNotifications |
| **SI-SVC-09** | Drift is informational only -- server never rejects | `sharedSubscribeService` logs stats, always returns subs | No direct test (TG-SVC-04) |

## Identified risks

| ID | Risk | Severity | Description |
|----|------|----------|-------------|
| **R-SVC-01** | Postgres fold full table scan | High | `foldRcvServiceMessages` (Postgres.hs:127-139) uses `ROW_NUMBER() OVER (PARTITION BY recipient_id ORDER BY message_id ASC)` as a subquery joined to `msg_queues`. This window function scans the **entire `messages` table** before filtering. For a service with 100k+ queues and millions of messages, this query can be very slow. The STM backend iterates an in-memory Set (fast), and the Journal backend uses per-queue file locks (moderate). Only the Postgres path has this scaling problem. Consider rewriting to use a lateral join or per-queue subquery to avoid the full-table window. |
| **R-SVC-02** | `totalServiceSubs` accounting drift | Low | `totalServiceSubs` is incremented by `serverThread` when processing CSClient events (line 281), but `clientDisconnected` subtracts the full `clientServiceSubs` (line 1120) which was eagerly updated by `sharedSubscribeQueue`. If CSClient events are still pending in `subQ` at disconnect time, `totalServiceSubs` is decremented for increments that never happened, causing negative drift. `totalServiceSubs` is never read for any decision (only written), so this is cosmetic. Resets on server restart. Consider periodic reconciliation or removing the counter if unused. |
| **R-SVC-03** | Fold thread continues after service takeover | Needs analysis | When a second service client connects (same cert), `cancelServiceSubs` sends ENDS to the old client. But the old client's `deliverServiceMessages` fold thread (forked via `forkClient`, tracked in `endThreads`) keeps running -- it writes MSG to the old client's `msgQ` (captured in closure). The old client receives and can ACK these messages. After ALLS the thread exits. New messages route to the new client via `tryDeliverMessage`. Questions: (1) Can the old client's ACKs interfere with the new client's subscription state? (2) If the old client disconnects mid-fold, `clientDisconnected` kills the fold thread (line 1111) -- are partially-delivered Subs cleaned up correctly? (3) Could the fold's `getSubscription` (which inserts into old client's `subscriptions`) conflict with the old client's subscription TMap being swapped out by `clientDisconnected`? |
| **R-SVC-04** | Cert rotation = full re-association | Medium (operational) | `getCreateService` maps cert fingerprint -> ServiceId. A new cert = new fingerprint = new ServiceId. All existing queue associations remain on the old ServiceId. The service must re-SUB every queue with the new service signature -- O(n), exactly the cost SUBS was designed to avoid. Old fingerprint->ServiceId mappings remain in memory/DB (no GC). For a notification server with millions of queues, cert rotation means a full re-association storm. |
| **R-SVC-05** | Fold blocking | Low | `foldRcvServiceMessages` iterates all service queues sequentially, reading queue records and first messages. For services with many queues, this could take significant time. It runs in a forked thread, so it doesn't block the client's command processing, but the ALLS marker is delayed. No progress signal between SOKS and ALLS -- client doesn't know how many messages to expect. |
| **R-SVC-06** | XOR hash collision | Very Low | IdsHash uses XOR of MD5 hashes. XOR is commutative and associative, so different queue sets with the same XOR-combined hash would not be detected. Given 16-byte hashes, collision probability is negligible for realistic queue counts, but the hash provides no ordering information. |
| **R-SVC-07** | Count underflow in subtractServiceSubs | Very Low | If `n <= n'`, the function returns `(0, mempty)` -- a full reset. This is a defensive fallback but could mask accounting errors. |

### Considered and dismissed

- **Fold-delivery race**: Both the fold's `getSubscription` (Server.hs:1828) and `newServiceDeliverySub` (Server.hs:1999-2023) operate on the same `subscriptions clnt` TMap within `atomically` blocks. STM serialization ensures at most one creates the Sub; the other sees it and skips. No race exists.
- **Sub accumulation during fold**: Each service queue with a pending message gets a Sub created in the client's `subscriptions` TMap. This is necessary and correct -- the Sub holds the `delivered` TVar for ACK verification and `subThread` for delivery state. Without per-queue Subs the server cannot track what was delivered or verify ACKs. Subs are cleaned on ACK or disconnect.
- **Store log replay ordering**: `writeQueueStore` writes all services before queues. `addQueue_` (QueueStore/STM.hs:119-132) calls `addServiceQueue` when `rcvServiceId` is present in QueueRec, so snapshot replay correctly rebuilds STMService queue sets. Incremental `QueueService` log entries are always preceded by `NewService` because the handshake (which creates the service) happens before SUB (which associates queues). No ordering issue.

---

## SMP Client layer (Client.hs)

### Service subscription command

```haskell
subscribeService :: (PartyI p, ServiceParty p) => SMPClient -> SParty p -> Int64 -> IdsHash -> ExceptT SMPClientError IO ServiceSub
subscribeService c party n idsHash = case smpClientService c of
  Just THClientService {serviceId, serviceKey} -> do
    sendSMPCommand c NRMBackground (Just (C.APrivateAuthKey C.SEd25519 serviceKey)) serviceId subCmd >>= \case
      SOKS n' idsHash' -> pure $ ServiceSub serviceId n' idsHash'
      r -> throwE $ unexpectedResponse r
    where subCmd = case party of
            SRecipientService -> SUBS n idsHash
            SNotifierService -> NSUBS n idsHash
  Nothing -> throwE PCEServiceUnavailable
```
Source: Client.hs:921-934

Entity is `serviceId`, auth key is the service session key (Ed25519). The client passes its expected count and hash; the server returns its own.

### Per-queue SUB with service

`subscribeSMPQueue` (Client.hs:843-846) and `subscribeSMPQueues` (Client.hs:850-855) send `SUB` commands. The response handler `processSUBResponse_` (Client.hs:867-872) accepts both `OK` (no service) and `SOK serviceId_` (service-associated).

`nsubResponse_` (Client.hs:914-918) does the same for `NSUB`.

### Dual signature scheme (`authTransmission`)

When `serviceAuth = True` and `useServiceAuth` returns True for the command (Client.hs:1385-1403):

1. The entity key signs over `serviceCertHash || transmission` (not just transmission)
2. The service key signs over `transmission` alone

This prevents MITM service substitution inside TLS: an attacker cannot replace the service certificate hash without invalidating the entity key signature.

```haskell
(t', serviceSig) = case clientService =<< thAuth of
  Just THClientService {serviceCertHash = XV.Fingerprint fp, serviceKey} | serviceAuth ->
    (fp <> t, Just $ C.sign' serviceKey t)
  _ -> (t, Nothing)
```
Source: Client.hs:1398-1401

### Service runtime accessors

```haskell
smpClientService :: SMPClient -> Maybe THClientService
smpClientService = thAuth . thParams >=> clientService

smpClientServiceId :: SMPClient -> Maybe ServiceId
smpClientServiceId = fmap (\THClientService {serviceId} -> serviceId) . smpClientService
```
Source: Client.hs:936-942

### Configuration

`ProtocolClientConfig` (Client.hs:466-483) carries `serviceCredentials :: Maybe ServiceCredentials`. On handshake, the client generates a fresh Ed25519 key pair per connection and signs it with the service's X.509 key (via `mkClientService`).

`serviceAuth` flag is set to `thVersion >= serviceCertsSMPVersion` (Client.hs:230), enabling dual signatures for all commands on v16+ connections.

## Agent layer

### Agent events

Four service-specific events (Agent/Protocol.hs:401-404):

| Event | Payload | When |
|-------|---------|------|
| `SERVICE_UP` | `SMPServer, ServiceSubResult` | SUBS succeeded; carries drift info |
| `SERVICE_DOWN` | `SMPServer, ServiceSub` | Server disconnected while service was subscribed |
| `SERVICE_ALL` | `SMPServer` | ALLS received — all buffered messages delivered |
| `SERVICE_END` | `SMPServer, ServiceSub` | ENDS received — another service client took over |

### Service subscription flow (`Agent/Client.hs`)

```
subscribeClientService(c, withEvent, userId, srv, serviceSub)     Client.hs:1743
  |
  +-- withServiceClient(c, tSess, ...)                             Client.hs:1752
  |     |
  |     +-- Get SMPClient for tSess
  |     +-- Check smpClientServiceId is Just -> smpServiceId
  |
  +-- setPendingServiceSub(tSess, serviceSub, currentSubs)         TSessionSubs
  |
  +-- subscribeClientService_(c, withEvent, tSess, smp, serviceSub)  Client.hs:1760
       |
       +-- subscribeService smp SRecipientService n idsHash        -> ServiceSub
       +-- serviceSubResult expected subscribed                     -> ServiceSubResult
       +-- atomically: setActiveServiceSub(tSess, sessId, subscribed)
       +-- if withEvent: notify SERVICE_UP srv result
```

### Reconnection / resubscription (`Agent/Client.hs:1727-1740`)

On service subscription failure during resubscription:
- `SSErrorServiceId` (server returned different ServiceId): fall back to `unassocSubscribeQueues` — removes all service associations for this server and resubscribes queues individually
- `clientServiceError`: same fallback
- Other errors: propagated

### Startup subscription (`Agent.hs:1622-1641`)

At agent startup, `subscribeService` is called in parallel per server. On `SSErrorServiceId` or `SSErrorQueueCount {n > 0, n' == 0}` (service exists but has no queues): falls back to unassociating queues and resubscribing individually.

### Server disconnection (`Agent/Client.hs:787-800`)

`serverDown` emits `SERVICE_DOWN`, then resubscribes:
- If session mode matches: full `resubscribeSMPSession`
- Otherwise: `resubscribeClientService` for service, then `subscribeQueues` for individual queues

## TSessionSubs (Agent/TSessionSubs.hs)

Per-session subscription state tracking, ~264 lines.

```haskell
data SessSubs = SessSubs
  { subsSessId :: TVar (Maybe SessionId),
    activeSubs :: TMap RecipientId RcvQueueSub,
    pendingSubs :: TMap RecipientId RcvQueueSub,
    activeServiceSub :: TVar (Maybe ServiceSub),
    pendingServiceSub :: TVar (Maybe ServiceSub) }
```
Source: TSessionSubs.hs:59-65

Key operations:
- `setPendingServiceSub`: stores expected ServiceSub before SUBS is sent
- `setActiveServiceSub`: promotes to active after SOKS, validates session ID
- `updateActiveService`: increments count/hash when per-queue SUBs with service signature succeed (used by `Client/Agent.hs` when individual SUBs return `SOK(Just serviceId)`)
- `deleteServiceSub`: clears both active and pending (on ENDS)

## Agent Store (AgentStore.hs)

### `client_services` table

```sql
CREATE TABLE client_services(
  user_id INTEGER NOT NULL REFERENCES users ON DELETE CASCADE,
  host TEXT NOT NULL, port TEXT NOT NULL,
  server_key_hash BLOB,
  service_cert BLOB NOT NULL,
  service_cert_hash BLOB NOT NULL,
  service_priv_key BLOB NOT NULL,
  service_id BLOB,                    -- assigned by server, NULL until first handshake
  service_queue_count INTEGER NOT NULL DEFAULT 0,
  service_queue_ids_hash BLOB NOT NULL DEFAULT x'00000000000000000000000000000000'
);
```
Source: Agent/Store/SQLite/Migrations/M20260115_service_certs.hs:11-23

### `rcv_queues.rcv_service_assoc`

Boolean column added to `rcv_queues`. When set, the queue is associated with the service for this server. SQLite triggers automatically maintain `service_queue_count` and `service_queue_ids_hash` on insert/delete/update of `rcv_queues` rows.

Triggers: `tr_rcv_queue_insert`, `tr_rcv_queue_delete`, `tr_rcv_queue_update_remove`, `tr_rcv_queue_update_add` (same migration file, lines 30-76). All use `simplex_xor_md5_combine` — the SQLite equivalent of Haskell's `queueIdHash <>`.

### Key CRUD operations

| Function | What it does |
|----------|--------------|
| `getClientServiceCredentials` | Load cert + key for a server; returns `Maybe ((KeyHash, TLS.Credential), Maybe ServiceId)` |
| `getSubscriptionService` | Load `ServiceSub` (serviceId, count, hash) for reconnection |
| `setClientServiceId` | Store ServiceId after first handshake |
| `setRcvServiceAssocs` | Mark queues as service-associated (sets `rcv_service_assoc = 1`) |
| `removeRcvServiceAssocs` | Remove service association for all queues on a server |
| `unassocUserServerRcvQueueSubs` | Remove association and return queues for re-subscription |

Source: AgentStore.hs:419-494, 2378-2414

### Service ID nullification on cert change

`INSERT ... ON CONFLICT DO UPDATE SET ... service_id = NULL` (AgentStore.hs:429) — when service credentials are updated (new cert), the stored `service_id` is cleared, forcing a new handshake to get a fresh ServiceId.

## Notification server (Notifications/Server.hs)

The NTF server is the primary consumer of service certificates for `SRNotifier` role.

### Configuration

`NtfServerConfig.useServiceCreds :: Bool` (Env.hs:80) — controls whether the NTF server uses service certificates for SMP subscriptions.

### Credential generation

On first use per SMP server, `mkDbService` (Env.hs:126-142) generates a self-signed TLS certificate (valid ~2400 days) and stores it in the `smp_servers` table. The cert is reused across connections to the same SMP server.

### Startup subscription

`subscribeSrvSubs` (Server.hs:460-481):
1. If service credentials exist: send NSUBS first (one command for all associated queues)
2. Then subscribe remaining individual queues in batches via `subscribeQueuesNtfs`

### Event handling

| Event | Handler |
|-------|---------|
| `CAServiceSubscribed` | Log count/hash match or mismatch |
| `CAServiceDisconnected` | Log disconnection |
| `CAServiceSubError` | Log error (non-fatal; fatal errors go to `CAServiceUnavailable`) |
| `CAServiceUnavailable` | **Critical recovery path**: calls `removeServiceAndAssociations`, wipes service creds, resubscribes all queues individually |

Source: Server.hs:567-602

### `removeServiceAndAssociations` (Store/Postgres.hs:620-652)

Nuclear recovery: clears `ntf_service_id`, `ntf_service_cert*`, resets `smp_notifier_count`/`smp_notifier_ids_hash`, and removes all `ntf_service_assoc` flags from subscriptions. Used when the service subscription is irrecoverably broken (e.g., ServiceId mismatch after cert rotation).

### NTF Postgres schema

The `smp_servers` table stores per-SMP-server state:
- `ntf_service_id`, `ntf_service_cert`, `ntf_service_cert_hash`, `ntf_service_priv_key` — service identity
- `smp_notifier_count`, `smp_notifier_ids_hash` — maintained by Postgres triggers on the `subscriptions` table

Triggers use `xor_combine` (Postgres equivalent of XOR hash combine) and fire on `ntf_service_assoc` changes.

## Agent test coverage

### Existing tests

| Test | File | What it covers |
|------|------|----------------|
| `testMigrateToServiceSubscriptions` | AgentTests/NotificationTests.hs:930-1016 | Full lifecycle: no service -> enable service (creates association) -> use service (NSUBS) -> disable service (downgrade to individual) -> re-enable |

### Additional test gaps (Phase 3.0b)

| Gap | Severity | Description |
|-----|----------|-------------|
| **TG-SVC-09** | Medium | No agent-level test for `SSErrorServiceId` recovery — the `unassocQueues` fallback path |
| **TG-SVC-10** | Medium | No agent-level test for concurrent reconnection — service resubscription racing with individual queue resubscription |
| **TG-SVC-11** | Medium | No test for `SERVICE_END` agent event handling — what does the agent do after receiving ENDS? |
| **TG-SVC-12** | Low | No test for SQLite trigger correctness — verifying `service_queue_count`/`service_queue_ids_hash` match expected values after insert/delete/update cycles |
