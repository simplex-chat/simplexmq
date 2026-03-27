# Simplex.Messaging.Agent.Store.Postgres

> PostgreSQL backend — dual-pool connection management, schema lifecycle, and migration.

**Source**: [`Agent/Store/Postgres.hs`](../../../../../../src/Simplex/Messaging/Agent/Store/Postgres.hs)

## Dual pool architecture

`connectPostgresStore` creates two connection pools (`dbPriorityPool` and `dbPool`), each with `poolSize` connections. Priority pool is used by `withTransactionPriority` for operations that shouldn't be blocked by regular queries. Both pools are TBQueue-based — connections are taken and returned after use.

All connections are created eagerly at initialization, not lazily on demand.

## uninterruptibleMask_ — pool atomicity invariant

See comment on `connectStore`. `uninterruptibleMask_` prevents async exceptions from interrupting pool filling or draining. The invariant: when `dbClosed = True`, queues are empty; when `False`, queues are full (or connections are in-flight with threads that will return them). Interruption mid-fill would break this invariant.

## Schema creation — fail-fast on missing

If the PostgreSQL schema doesn't exist and `createSchema` is `False`, the process logs an error and calls `exitFailure`. This prevents silent operation against the wrong schema.

## execSQL — not implemented

`execSQL` throws "not implemented" — the PostgreSQL client doesn't support raw SQL execution via the agent API. The function exists only to satisfy the shared interface.
