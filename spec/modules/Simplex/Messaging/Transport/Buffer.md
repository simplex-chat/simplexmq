# Simplex.Messaging.Transport.Buffer

> Buffered TLS reading with TMVar-based concurrency lock.

**Source**: [`Transport/Buffer.hs`](../../../../../src/Simplex/Messaging/Transport/Buffer.hs)

## TBuffer — concurrent read safety via getLock

`TBuffer` uses a `TMVar ()` as a mutex (`getLock`). `getBuffered` acquires the lock via `withBufferLock`, then loops and accumulates bytes until the requested count is reached.

## getBuffered — first chunk has no timeout

`getBuffered` reads the first chunk via `getChunk` (no timeout), but applies `withTimedErr t_` (the transport timeout) to subsequent chunks.

## getLnBuffered — test only

The source comment states: "This function is only used in test and needs to be improved before it can be used in production, it will never complete if TLS connection is closed before there is newline."
