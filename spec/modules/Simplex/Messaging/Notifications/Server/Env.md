# Simplex.Messaging.Notifications.Server.Env

> NTF server environment: configuration, subscriber state, and push provider management.

**Source**: [`Notifications/Server/Env.hs`](../../../../../../src/Simplex/Messaging/Notifications/Server/Env.hs)

## Non-obvious behavior

### 1. Service credentials are lazily generated

`mkDbService` in `newNtfServerEnv` generates service credentials on demand: when `getCredentials` is called for an SMP server, it checks the database. If the server is known and already has credentials, they are reused. If the server is known but has no credentials yet (first connection), new credentials are generated via `genCredentials`, stored in the database, and returned. If the server is not in the database at all, `PCEServiceUnavailable` is thrown (this case should not occur in practice, as clients only connect to servers already tracked in the database).

Service credentials are only used when `useServiceCreds` is enabled in the config.

### 2. PPApnsNull creates a no-op push client

`newPushClient` checks `apnsProviderHost` for the push provider. `PPApnsNull` returns `Nothing`, which creates a no-op client (`\_ _ -> pure ()`). Real providers create an actual APNS connection. This is the mechanism that allows `PPApnsNull` tokens to function without push infrastructure.

### 3. getPushClient lazy initialization

`getPushClient` looks up the push client by provider in `pushClients` TMap. If not found, it calls `newPushClient` to create and register one. Push provider connections are established on first use, not at server startup.

### 4. Service credential validity: 25h backdating, ~2700yr forward

`genCredentials` creates self-signed Ed25519 certificates valid from 25 hours in the past to `24 * 999999` hours (~2,739 years) in the future. The 25-hour backdating protects against clock skew between NTF and SMP routers. The near-permanent forward validity avoids the need for credential rotation infrastructure.

### 5. newPushClient race creates duplicate clients

`newPushClient` atomically inserts into `pushClients` after creating the client. A concurrent `getPushClient` call between creation start and TMap insert will see `Nothing`, create a second client, and overwrite the first. This race is tolerable — APNS connections are cheap and the overwritten client is garbage collected.

### 6. Bidirectional activity timestamps

`NtfServerClient` has separate `rcvActiveAt` and `sndActiveAt` TVars, both initialized to connection time and updated independently. `disconnectTransport` considers both — a client that only receives (or only sends) is still considered active.

### 7. pushQ bounded TBQueue creates backpressure

`pushQ` in `NtfPushServer` is a `TBQueue` sized by `pushQSize`. When full, any thread writing to it (NMSG processing, periodic cron, verification) blocks in STM until space is available. This prevents the push delivery pipeline from being overwhelmed.

### 8. subscriberSeq provides monotonic session variable ordering

The `subscriberSeq` TVar is used by `getSessVar` to assign monotonically increasing IDs to subscriber session variables. `removeSessVar` uses compare-and-swap with this ID — only the variable with the matching ID can be removed, preventing stale removal when a new subscriber has already replaced the old one.

### 9. SMPSubscriber holds Weak ThreadId for GC-based cleanup

`subThreadId` is `Weak ThreadId`, not `ThreadId`. Using `Weak ThreadId` allows the GC to collect thread resources when no strong references remain. `stopSubscriber` uses `deRefWeak` to obtain the `ThreadId` (if the thread hasn't been GC'd) before calling `killThread`. The `Nothing` case (thread already collected) is simply skipped.
