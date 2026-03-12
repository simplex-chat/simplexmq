# Simplex.Messaging.Server

> SMP router (`Server` module): client handling, subscription lifecycle, message delivery, proxy forwarding, control port.

**Source**: [`Server.hs`](../../../../src/Simplex/Messaging/Server.hs)

**Protocol spec**: [`protocol/simplex-messaging.md`](../../../../protocol/simplex-messaging.md) — SimpleX Messaging Protocol.

## Overview

The router runs as `raceAny_` over many threads — any thread exit stops the entire router process. The thread set includes: one `serverThread` per subscription type (SMP, NTF), a notification delivery thread, a pending events thread, a proxy agent receiver, a SIGINT handler, plus per-transport listener threads and optional expiration/stats/prometheus/control-port threads. `E.finally` ensures `stopServer` runs on any exit.

## serverThread — subscription lifecycle with split STM

See comment on `serverThread`. It reads the subscription request from `subQ`, then looks up the client **outside** STM (via `getServerClient`), then enters an STM transaction (`updateSubscribers`) to compute which old subscriptions to end, then runs `endPreviousSubscriptions` in IO. If the client disconnects between lookup and transaction, `updateSubscribers` handles `Nothing` by still sending END/DELD to other subscribed clients.

`checkAnotherClient` ensures END messages are only sent to clients **other than** the subscribing client — if `clntId == clientId`, the action is skipped.

`removeWhenNoSubs` removes a client from `subClients` only when **both** queue and service subscriptions are empty — not after each individual unsubscription.

## SubscribedClients — TVar-of-Maybe pattern

See comment on `SubscribedClients` in Env/STM.hs. Subscription entries store `TVar (Maybe (Client s))` — the TVar's contents change between `Just client` and `Nothing` on disconnect/reconnect, allowing STM transactions reading the TVar to automatically re-evaluate when the subscriber changes. Entries **are** removed via `lookupDeleteSubscribedClient` (when subscriptions end) and `deleteSubcribedClient` (on client disconnect), though the source comment describes the original intent of never cleaning them up.

`upsertSubscribedClient` returns the previously subscribed client only if it's a **different** client (checked via `sameClientId`). Same client → returns `Nothing` (no END needed).

## ProhibitSub / ServerSub state machine

`Sub.subThread` is either `ProhibitSub` or `ServerSub (TVar SubscriptionThread)`. GET creates `ProhibitSub`, preventing subsequent SUB on the same queue (`CMD PROHIBITED`). SUB creates `ServerSub NoSub`, preventing subsequent GET (`CMD PROHIBITED`). This is enforced per-connection — the state tracks which access pattern the client chose.

`SubscriptionThread` transitions: `NoSub` → `SubPending` (sndQ full during delivery) → `SubThread (Weak ThreadId)` (delivery thread spawned). `SubPending` is set **before** the thread is spawned; the thread atomically upgrades to `SubThread` after forking. If the thread exits before upgrading, the `modifyTVar'` is a no-op (checks for `SubPending` specifically).

## tryDeliverMessage — sync/async split delivery

See comment on `tryDeliverMessage`. When a SEND arrives and the queue was empty:

1. Look up subscribed client **outside STM** (avoids transaction cost when no subscriber exists)
2. In STM: check `delivered` is Nothing, check sndQ not full → deliver synchronously, return Nothing
3. If sndQ is full: set `SubPending`, return the client/sub/stateVar triple
4. Fork a delivery thread that waits for sndQ space, verifies `sameClient` (prevents delivery to reconnected client), then delivers and sets state to `NoSub`

The `sameClient` check inside the delivery thread prevents a race: if the client reconnected between fork and delivery, the new client will receive the message via its own SUB.

`newServiceDeliverySub` creates a transient subscription **only** for service-associated queues during message delivery — this is separate from the SUB-created subscriptions.

## Constant-time authorization — dummy keys

See comment on `verifyCmdAuthorization`. Always runs verification regardless of whether the queue exists. When the queue is missing (AUTH error), `dummyVerifyCmd` runs verification with hardcoded dummy keys (Ed25519, Ed448, X25519) and the result is discarded via `seq`. The time depends only on the authorization type provided, not on queue existence. This mitigates timing side-channel attacks that could reveal whether a queue ID exists.

When the signature algorithm doesn't match the queue key, verification runs with a dummy key of the **provided** algorithm and the result is forced then discarded (`seq False`).

## Service subscription — hash-based drift detection

See comment on `sharedSubscribeService`. The client sends expected `(count, idsHash)`. The router reads the actual values from storage, then computes `subsChange = subtractServiceSubs currSubs subs'` — the **difference** between what the client's session currently tracks and the new values. This difference (not the absolute values) is passed to `serverThread` via `CSService` to adjust `totalServiceSubs`. Using differences prevents double-counting when a service resubscribes.

Stats classification: exactly one of `srvSubOk`/`srvSubMore`/`srvSubFewer`/`srvSubDiff` is incremented per subscription. `count == -1` is a special case for old NTF servers.

## Proxy forwarding — single transmission, no service identity

See comment on `processForwardedCommand`. Only single forwarded transmissions are allowed — batches are rejected with `BLOCK`. The synthetic `THandleAuth` has `peerClientService = Nothing`, preventing forwarded clients from claiming service identity. Only SEND, SKEY, LKEY, and LGET are allowed through `rejectOrVerify`.

Double encryption: response is encrypted first to the client (with `C.cbEncrypt` using `reverseNonce clientNonce`), then wrapped and encrypted to the proxy (with `C.cbEncryptNoPad` using `reverseNonce proxyNonce`). Using reversed nonces ensures request and response directions use distinct nonces.

## Proxy concurrency limiter

See `wait`/`signal` around `forkProxiedCmd`. `procThreads` TVar implements a counting semaphore via STM `retry`. When `used >= serverClientConcurrency`, the transaction retries until another thread finishes. No bound on wait time — under sustained proxy load, commands queue indefinitely.

## sendPendingEvtsThread — atomic swap

`swapTVar pendingEvents IM.empty` atomically takes all pending events and clears the map. Events accumulated during processing are captured in the next interval. `tryWriteTBQueue` is tried first (non-blocking); if the sndQ is full, a forked thread does the blocking write. This prevents the pending events thread from stalling on one slow client.

## deliverNtfsThread — throwSTM for control flow

See `withSubscribed`. When a service client unsubscribes between the TVar read and the flush, `throwSTM (userError "service unsubscribed")` aborts the STM transaction. This is caught by `tryAny` and logged as "cancelled" — it's a successful path, not an error. The `flushSubscribedNtfs` function also cancels via `throwSTM` if the client is no longer current or sndQ is full.

## Batch subscription responses — SOK grouped with MSG

See comment on `processSubBatch`. When batched SUB commands produce SOK responses plus messages, the first message is appended to the SOK batch (up to 4 SOKs per block) in a single transmission. Remaining messages go to `msgQ` for separate delivery. This ensures the client receives at least one message quickly with its subscription acknowledgments.

## send thread — MVar fair lock

The TLS handle is wrapped in an `MVar` (`newMVar h`). Both `send` (command responses from `sndQ`) and `sendMsg` (messages from `msgQ`) acquire this lock via `withMVar`. This ensures fair interleaving between response batches and individual messages, preventing either from starving the other.

## Queue creation — ID oracle prevention

See comment on queue creation with client-supplied IDs. When `clntIds = True`, the ID must equal `B.take 24 (C.sha3_384 (bs corrId))`. This prevents ID oracle attacks where an attacker could probe for queue existence by attempting to create a queue with a specific ID and observing DUPLICATE vs AUTH errors.

## disconnectTransport — subscription-aware idle timeout

See `noSubscriptions`. The idle client disconnect thread only checks expiration when the client has **no** subscriptions (not in `subClients` for either SMP or NTF subscribers). Subscribed clients are kept alive indefinitely regardless of inactivity — they're waiting for messages, not idle.

## clientDisconnected — ordered cleanup

On disconnect: (1) set `connected = False`, (2) atomically swap out all subscriptions, (3) cancel subscription threads, (4) if router is still active: delete client from `serverClients` map, update queue and service subscribers. Service subscription cleanup (`updateServiceSubs`) subtracts the client's accumulated `(count, idsHash)` from `totalServiceSubs`. End threads are swapped out and killed.

## Control port — single auth, no downgrade

See `controlPortAuth`. Role is set on first `CPAuth` only (`CPRNone` case). Subsequent AUTH commands print the current role but do not change it — the message says "start new session to change." This prevents role downgrade attacks within a session.

## withQueue_ — updatedAt time check

Every queue command calls `withQueue_` which checks if `updatedAt` matches today's date. If not, `updateQueueTime` is called to update it. This means `updatedAt` is a daily resolution activity timestamp, not a per-command timestamp. The SEND path passes `queueNotBlocked = False` to still update the time even for blocked queues (though SEND fails on blocked queues separately).

## foldrM in client command processing

`foldrM process ([], [])` processes a batch of verified commands right-to-left, accumulating responses and messages. The responses list is built with `(:)`, so the final order matches the original command order. Messages from SUB are collected separately and passed as the second element of the `sndQ` tuple.
