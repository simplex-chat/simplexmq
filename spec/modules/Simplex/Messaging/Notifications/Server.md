# Simplex.Messaging.Notifications.Server

> NTF server: manages tokens, subscriptions, SMP subscriber connections, and push notification delivery.

**Source**: [`Notifications/Server.hs`](../../../../../src/Simplex/Messaging/Notifications/Server.hs)

## Architecture

The NTF server runs several concurrent threads via `raceAny_`:

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

When TNEW is received for an already-registered token, the server:
1. Looks up the existing token via `findNtfTokenRegistration`
2. Verifies the DH secret matches (recomputed from the new `dhPubKey` and stored `tknDhPrivKey`)
3. If DH secrets differ → AUTH error (prevents token hijacking)
4. If they match → re-sends verification push notification

This makes TNEW safe for client retransmission after connection drops.

### 3. SNEW idempotent subscription

When SNEW is received for an existing subscription (same token + SMP queue), the server returns the existing `ntfSubId` if the notifier key matches. If keys differ, AUTH error. New subscriptions are only created when no match exists in `findNtfSubscription`.

### 4. PPApnsNull suppresses statistics

`incNtfStatT` skips all stat increments when the device token uses `PPApnsNull` provider. This prevents test tokens from polluting production metrics.

### 5. END requires active session validation

SMP END messages are only processed when the originating session is the currently active session for that server (`activeClientSession'` check). This prevents stale END messages from previous (reconnected) sessions from incorrectly marking subscriptions as ended.

### 6. waitForSMPSubscriber two-phase wait

`waitForSMPSubscriber` first tries a non-blocking `tryReadTMVar`. If the subscriber isn't ready yet, it falls back to a blocking `readTMVar` with a 10-second timeout. This avoids creating an extra timeout thread in the common case where the subscriber is already available.

### 7. CAServiceUnavailable triggers individual resubscription

When a service subscription becomes unavailable (SMP server rejects service credentials), the NTF server:
1. Removes the service association from the database
2. Resubscribes all individual queues for that server via `subscribeSrvSubs`

This is the fallback path from service-level to queue-level SMP subscriptions.

### 8. Push delivery single retry

`deliverNotification` retries exactly once on connection errors (`PPConnection`) or `PPRetryLater`:
1. Creates a new push client (`newPushClient`) to get a fresh connection
2. Retries the delivery

On the second failure, the error is logged and returned. `PPTokenInvalid` marks the token as `NTInvalid` on either the first or retry attempt.

### 9. TCRN minimum interval enforcement

Cron notification interval has a hard minimum of 20 minutes. `TCRN 0` disables cron notifications. `TCRN n` where `1 <= n < 20` returns `QUOTA` error.

### 10. Startup resubscription is concurrent per server

`resubscribe` uses `mapConcurrently` to resubscribe to all known SMP servers in parallel. Within each server, subscriptions are paginated via `subscribeLoop` using cursor-based pagination (`afterSubId_`).

### 11. receive separates error responses from commands

The `receive` function processes incoming transmissions and partitions results: malformed/unauthorized requests are written directly to `sndQ` as error responses, while valid commands go to `rcvQ` for processing. This ensures protocol errors get immediate responses without competing for the command processing queue.
