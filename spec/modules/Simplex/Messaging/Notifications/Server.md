# Simplex.Messaging.Notifications.Server

> NTF router: manages tokens, subscriptions, SMP subscriber connections, and push notification delivery.

**Source**: [`Notifications/Server.hs`](../../../../../src/Simplex/Messaging/Notifications/Server.hs)

## Architecture

The NTF router runs several concurrent threads via `raceAny_`:

| Thread | Purpose |
|--------|---------|
| `ntfSubscriber` | Receives SMP messages (NMSG, END, DELD) and agent events (connect/disconnect/subscribe) |
| `ntfPush` | Reads push queue and delivers via APNS provider |
| `periodicNtfsThread` | Sends periodic "check messages" push notifications (cron) |
| `runServer` (per transport) | Accepts client connections and runs NTF protocol |
| Stats/Prometheus/Control | Optional monitoring and admin threads |

Each client connection spawns `receive`, `send`, and `client` threads via `raceAny_`.

## Non-obvious behavior

### 1. Timing attack mitigation on entity lookup

When `verifyNtfTransmission` encounters an AUTH error (entity not found), it calls `dummyVerifyCmd` to equalize response timing before returning the error. This prevents attackers from distinguishing "entity doesn't exist" from "signature invalid" based on response latency.

### 2. TNEW idempotent re-registration

When TNEW is received for an already-registered token, the router:
1. Looks up the existing token via `findNtfTokenRegistration` (matches on push provider, device token, AND verify key)
2. Verifies the DH secret matches (recomputed from the new `dhPubKey` and stored `tknDhPrivKey`)
3. If DH secrets differ → AUTH error (prevents token hijacking)
4. If they match → re-sends verification push notification

If the verify key doesn't match in step 1, the lookup returns `Nothing` and a new token is created instead — the DH secret check never runs. This makes TNEW safe for client retransmission after connection drops.

### 3. SNEW idempotent subscription

When SNEW is received for an existing subscription (same token + SMP queue), the router returns the existing `ntfSubId` if the notifier key matches. If keys differ, AUTH error. New subscriptions are only created when no match exists in `findNtfSubscription`.

### 4. PPApnsNull suppresses statistics

`incNtfStatT` skips all stat increments when the device token uses `PPApnsNull` provider. This prevents test tokens from polluting production metrics.

### 5. END requires active session validation

SMP END messages are only processed when the originating session is the currently active session for that router (`activeClientSession'` check). This prevents stale END messages from previous (reconnected) sessions from incorrectly marking subscriptions as ended.

### 6. waitForSMPSubscriber two-phase wait

`waitForSMPSubscriber` first tries a non-blocking `tryReadTMVar`. If the subscriber isn't ready yet, it falls back to a blocking `readTMVar` with a 10-second timeout. This avoids creating an extra timeout thread in the common case where the subscriber is already available.

### 7. CAServiceUnavailable triggers individual resubscription

When a service subscription becomes unavailable (SMP router rejects service credentials), the NTF router:
1. Removes the service association from the database
2. Resubscribes all individual queues for that router via `subscribeSrvSubs`

This is the fallback path from service-level to queue-level SMP subscriptions.

### 8. Push delivery single retry

`deliverNotification` retries exactly once on connection errors (`PPConnection`) or `PPRetryLater`:
1. Creates a new push client (`newPushClient`) to get a fresh connection
2. Retries the delivery

On the second failure, the error is logged and returned. `PPTokenInvalid` marks the token as `NTInvalid` on either the first or retry attempt.

### 9. TCRN minimum interval enforcement

Cron notification interval has a hard minimum of 20 minutes. `TCRN 0` disables cron notifications. `TCRN n` where `1 <= n < 20` returns `QUOTA` error.

### 10. Startup resubscription is concurrent per router

`resubscribe` uses `mapConcurrently` to resubscribe to all known SMP routers in parallel. Within each router, subscriptions are paginated via `subscribeLoop` using cursor-based pagination (`afterSubId_`).

### 11. receive separates error responses from commands

The `receive` function processes incoming transmissions and partitions results: malformed/unauthorized requests are written directly to `sndQ` as error responses, while valid commands go to `rcvQ` for processing. This ensures protocol errors get immediate responses without competing for the command processing queue.

### 12. Maintenance mode saves state then exits immediately

When `maintenance` is set in `startOptions`, the router restores stats, calls `stopServer` (closes DB, saves stats), and exits with `exitSuccess`. It never starts transport listeners, subscriber threads, or resubscription. This provides a way to run database migrations without the router serving traffic.

### 13. Resubscription runs as a detached fork

`resubscribe` is launched via `forkIO` before `raceAny_` starts — it is **not part of the `raceAny_` group**. Most exceptions are silently lost per `forkIO` semantics. However, `ExitCode` exceptions (like `exitFailure` from pattern 20) are special-cased by GHC's runtime and propagate to the main thread, terminating the process.

### 14. TNEW re-registration resets status for non-verifiable tokens

When a re-registration TNEW matches on DH secret but `allowTokenVerification tknStatus` is `False` (token is `NTNew`, `NTInvalid`, or `NTExpired`), the router resets status to `NTRegistered` before sending the verification push. This makes TNEW a "status repair" mechanism — clients with stuck tokens can restart the verification flow by re-registering with the same DH key.

### 15. DELD unconditionally updates status (no session validation)

Unlike `SMP.END` which checks `activeClientSession'` to prevent stale session messages from changing state, `SMP.DELD` updates subscription status to `NSDeleted` unconditionally. This is correct because DELD means the queue was permanently deleted on the SMP router — the information is valid regardless of which session reports it.

### 16. TRPL generates new code but reuses the DH key

`TRPL` (token replace) creates a new registration code and resets status to `NTRegistered`, but does NOT generate a new router DH key pair. The existing `tknDhPrivKey` and `tknDhSecret` are preserved — only the push provider token and registration code change. The encrypted channel between client and NTF router persists across device token replacements.

### 17. PNMessage delivery requires NTActive, verification and cron do not

`ntfPush` applies `checkActiveTkn` only to `PNMessage` notifications. Verification pushes (`PNVerification`) and cron check-messages pushes (`PNCheckMessages`) are delivered regardless of token status. This is necessary because verification pushes must be sent before NTActive, and cron pushes are already filtered at the database level.

### 18. CAServiceSubscribed validates count and hash with warning-only behavior

When a service subscription is confirmed, the NTF router compares expected and confirmed subscription count and IDs hash. Mismatches in either are logged as warnings but no corrective action is taken. Only when both match is an informational message logged.

### 19. subscribeLoop uses 100x database batch multiplier

`dbBatchSize = batchSize * 100` reads subscriptions from the database in chunks 100 times larger than the SMP subscription batches. This reduces database round-trips during resubscription while keeping individual SMP batches small enough to avoid overwhelming SMP routers.

### 20. subscribeLoop calls exitFailure on database error

If `getServerNtfSubscriptions` returns `Left _` during startup resubscription, the router terminates via `exitFailure`. Since `resubscribe` runs in a forked thread (pattern 13), this `exitFailure` terminates the entire process — a transient database error during startup resubscription kills the router.

### 21. Stats log aligns to wall-clock time of day

The stats logging thread calculates an `initialDelay` to synchronize the first flush to `logStatsStartTime`. If the target time already passed today, it adds 86400 seconds to schedule for the next day. Subsequent flushes occur at exact `logInterval` cadence from that aligned start point.

### 22. NMSG AUTH errors silently counted, not logged

When `addTokenLastNtf` returns `Left AUTH` (notification for a queue whose subscription/token association is invalid), the router increments `ntfReceivedAuth` but takes no corrective action. Other error types are silently ignored. This is expected — subscriptions may be deleted while messages are in-flight.

### 23. PNVerification delivery transitions token to NTConfirmed

When a verification push is successfully delivered to the push provider, `setTknStatusConfirmed` transitions the token to `NTConfirmed`, but only if not already `NTConfirmed` or `NTActive`. This creates a two-phase confirmation: push delivery confirms the channel works (`NTConfirmed`), then TVFY confirms the client received it (`NTActive`).

### 24. disconnectTransport always passes noSubscriptions = True

Unlike the SMP router which checks active subscriptions before disconnecting idle clients, the NTF router always returns `True` for the "no subscriptions" check. NTF clients are disconnected purely on inactivity timeout — the NTF protocol has no long-lived client subscriptions.
