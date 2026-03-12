# Simplex.Messaging.Server.Env.STM

> Server environment, configuration, client state, subscription types, and storage initialization.

**Source**: [`Env/STM.hs`](../../../../../../src/Simplex/Messaging/Server/Env/STM.hs)

## Overview

This module defines the server's shared state (`Env`, `Server`, `Client`) and the subscription model types. Most non-obvious patterns are about concurrency safety — preventing STM contention while maintaining consistency. Key patterns are documented in [Server.md](../Server.md) where they're used; this doc covers patterns specific to the type definitions and initialization.

## SubscribedClients — TVar-of-Maybe pattern

See comment on `SubscribedClients`. Entries store `TVar (Maybe (Client s))` rather than the client directly. Three implications:

1. STM transactions reading the TVar automatically re-evaluate when the subscriber changes (disconnect/reconnect)
2. IO lookups via `TM.lookupIO` can be done outside STM safely (the TVar reference itself is stable while it exists)
3. Reconnecting clients can reuse existing subscription slots without map-level contention

Note: despite the source comment saying subscriptions "are not removed," the code does remove entries via `lookupDeleteSubscribedClient` (when subscriptions end) and `deleteSubcribedClient` (on client disconnect). The comment reflects the original design intent for mobile client continuity, but the current implementation does clean up.

See also [Server.md#subscribedclients--tvar-of-maybe-pattern](../Server.md#subscribedclients--tvar-of-maybe-pattern).

## deleteSubcribedClient — split transaction for contention avoidance

See comment on `deleteSubcribedClient`. The TVar lookup is in a separate IO read from the client comparison and deletion. This is safe because the client is read in the same STM transaction as the deletion — if another client was inserted between lookup and delete, `sameClient` returns False and the delete is skipped. After setting the TVar to `Nothing`, the entry is also removed from the TMap.

## insertServerClient — connected check

`insertServerClient` checks `connected` inside the STM transaction before inserting. If the client was already marked disconnected (race with cleanup), the insert is skipped and returns `False`. This prevents resurrecting a disconnected client in the server map.

## SupportedStore — compile-time storage validation

Type family with `(Int ~ Bool, TypeError ...)` for invalid combinations. The unsatisfiable `Int ~ Bool` constraint forces GHC to emit the `TypeError` message. Valid: Memory+Memory, Memory+Journal, Postgres+Journal, Postgres+Postgres (with flag). Invalid: Memory+Postgres, Postgres+Memory. The `dbServerPostgres` CPP flag controls whether Postgres+Postgres is available.

## newEnv — initialization order

Store initialization order matters: (1) create message store (loads store log for STM backends), (2) create notification store (empty TMap), (3) generate TLS credentials, (4) compute server identity from fingerprint, (5) create stats, (6) create proxy agent. The store log load (`loadStoreLog`) calls `readWriteQueueStore` which reads the existing log, replays it to build state, then opens a new log for writing. `setStoreLog` attaches the write log to the store.

HTTPS credentials are validated: must be at least 4096-bit RSA (`public_size >= 512` bytes). The check explicitly notes that Let's Encrypt ECDSA uses "insecure curve p256."

## ServerSubscribers — dual subscriber tracking

`ServerSubscribers` has two `SubscribedClients` maps: `queueSubscribers` (one entry per queue, for direct subscriptions) and `serviceSubscribers` (one entry per service, for service-certificate subscriptions). `totalServiceSubs` tracks the aggregate `(count, IdsHash)` across all services. `subClients` is an `IntSet` of all client IDs with any subscription (union of queue and service subscribers) — used for idle disconnect decisions.

## endThreads — weak references with sequence counter

See comment on `endThreads`. Forked client threads (delivery, proxy commands) are tracked in `IntMap (Weak ThreadId)` with a monotonically increasing `endThreadSeq`. On client disconnect, all threads are swapped out and killed. Weak references allow GC to collect threads that finished normally without explicit cleanup.
