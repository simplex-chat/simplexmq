# Simplex.Messaging.Util

> Shared utility functions: exception handling, monadic combinators, data helpers.

**Source**: [`Util.hs`](../../../../src/Simplex/Messaging/Util.hs)

## Overview

Most of this module is straightforward. The exception handling scheme is the part that warrants documentation — the naming is misleading and the semantics are subtle.

## Exception handling scheme

Three categories of exceptions, two catch strategies:

| Category | Examples | `catchAll` | `catchOwn` |
|----------|----------|------------|------------|
| Synchronous | IOError, protocol errors | caught | caught |
| "Own" async | StackOverflow, HeapOverflow, AllocationLimitExceeded | caught | caught |
| Async cancellation | ThreadKilled, all other SomeAsyncException | caught | **re-thrown** |

### isOwnException

Classifies `StackOverflow`, `HeapOverflow`, and `AllocationLimitExceeded` as "own" — exceptions caused by this thread's resource usage, not by external cancellation. Despite being `AsyncException`, these should be caught like synchronous exceptions because they reflect the thread's own failure.

### isAsyncCancellation

True for any `SomeAsyncException` that is NOT an own exception. These represent external cancellation (e.g., `cancel`, `killThread`) and must be re-thrown to preserve structured concurrency guarantees.

### catchOwn / catchOwn'

Despite the name, these catch **all exceptions except async cancellations** — including synchronous exceptions. The name suggests "catch only own exceptions" but the actual semantics are "catch non-cancellation exceptions." This is the standard pattern for exception-safe cleanup in concurrent Haskell.

### tryAllErrors vs tryAllOwnErrors

- `tryAllErrors` / `catchAllErrors`: catch everything including async cancellations. Use when you need to convert any failure into an error value (e.g., returning error responses on a connection).
- `tryAllOwnErrors` / `catchAllOwnErrors`: catch everything except async cancellations. Use in normal business logic where cancellation should propagate.

### AnyError typeclass

Bridges `SomeException` into application error types via `fromSomeException`. All the `tryAll*` / `catchAll*` functions require this constraint.

## raceAny_

Runs all actions concurrently, waits for any one to complete, then cancels all others. Uses nested `withAsync` — earlier-launched actions are canceled last (LIFO unwinding).

## threadDelay'

Handles `Int64` delays exceeding `maxBound :: Int` (~2147 seconds on 32-bit) by looping in chunks. Necessary because `threadDelay` takes `Int`, not `Int64`.

