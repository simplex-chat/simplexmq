# Simplex.Messaging.Agent.Store.SQLite

> SQLite backend — store creation, encrypted connection management, migration, and custom SQL functions.

**Source**: [`Agent/Store/SQLite.hs`](../../../../../../src/Simplex/Messaging/Agent/Store/SQLite.hs)

## Security-relevant PRAGMAs

`connectDB` sets PRAGMAs at connection time:
- `secure_delete = ON`: data is overwritten (not just unlinked) on DELETE
- `auto_vacuum = FULL`: freed pages are reclaimed immediately
- `foreign_keys = ON`: referential integrity enforced

These are set per-connection, not per-database — every new connection (including re-opens) gets them.

## simplex_xor_md5_combine — custom SQLite function

A C-exported SQLite function registered at connection time. Takes an existing `IdsHash` and a `RecipientId`, XORs the hash with the MD5 of the ID. This is the SQLite implementation of the accumulative IdsHash used by service subscriptions (see [TSessionSubs.md](../TSessionSubs.md#updateActiveService--accumulative-xor-merge)). PostgreSQL uses its native `md5()` and `decode()` functions instead.

## openSQLiteStore_ — connection swap under MVar

Uses `bracketOnError` with `takeMVar`/`tryPutMVar`: takes the connection MVar, creates a new connection, and puts the new one back. If connection fails, `tryPutMVar` restores the old connection. The `dbClosed` TVar is flipped atomically with the key update.

## storeKey — conditional key retention

`storeKey key keepKey` stores the encryption key in the `dbKey` TVar only if `keepKey` is true. This allows `reopenDBStore` to re-open without the caller re-supplying the key. If `keepKey` is false and the store is closed, `reopenDBStore` fails with "no key".
