# Simplex.Messaging.Client

> Generic protocol client: connection management, command sending/receiving, batching, proxy protocol, reconnection.

**Source**: [`Client.hs`](../../../../src/Simplex/Messaging/Client.hs)

**Protocol spec**: [`protocol/simplex-messaging.md`](../../../../protocol/simplex-messaging.md) — SimpleX Messaging Protocol.

## Overview

This module implements the client side of the `Protocol` typeclass — connecting to SMP routers, sending commands, receiving command results, and managing connection lifecycle. It is generic over `Protocol v err msg`, instantiated for SMP as `SMPClient` (= `ProtocolClient SMPVersion ErrorType BrokerMsg`). The SMP proxy protocol (PRXY/PFWD/RFWD) is also implemented here.

## Four concurrent threads — teardown semantics

`getProtocolClient` launches four threads via `raceAny_`:
- `send`: reads from `sndQ` (TBQueue) and writes to TLS
- `receive`: reads from TLS and writes to `rcvQ` (TBQueue), updates `lastReceived`
- `process`: reads from `rcvQ` and dispatches to result vars or `msgQ`
- `monitor`: periodic ping loop (only when `smpPingInterval > 0`)

When ANY thread exits (normally or exceptionally), `raceAny_` cancels all others. `E.finally` ensures the `disconnected` callback always fires. Implication: a single stuck thread (e.g., TLS read blocked on a half-open connection) keeps the entire client alive until `monitor` drops it. There is no per-thread health check — liveness depends entirely on the monitor's timeout logic.

## Request lifecycle and leak risk

`mkRequest` inserts a `Request` into `sentCommands` TMap BEFORE the transmission is written to TLS. If the TLS write fails silently or the connection drops before the result arrives, the entry remains in `sentCommands` until the monitor's timeout counter exceeds `maxCnt` and drops the entire client. There is no per-request cleanup on send failure — individual request entries are only removed by `processMsg` (on result) or by `getResponse` timeout (which sets `pending = False` but doesn't remove the entry).

## getResponse — pending flag race contract

This is the core concurrency contract between timeout and result processing:

1. `getResponse` waits with `timeout` for `takeTMVar responseVar`
2. Regardless of result, atomically sets `pending = False` and tries `tryTakeTMVar` again (see comment on `getResponse`)
3. In `processMsg`, when a result arrives for a request where `pending` is already `False` (timeout won), `wasPending` is `False` and the result is forwarded to `msgQ` as `STResponse` rather than discarded

The double-check pattern (`swapTVar pending False` + `tryTakeTMVar`) handles the race window where a result arrives between timeout firing and `pending` being set to `False`. Without this, results arriving in that gap would be silently lost.

`timeoutErrorCount` is reset to 0 in three places: in `getResponse` when a result arrives, in `receive` on every TLS read, and the monitor uses this count to decide when to drop the connection.

## processMsg — router events vs expired results

When `corrId` is empty, the message is an `STEvent` (router-initiated). When non-empty and the request was already expired (`wasPending` is `False`), the result becomes `STResponse` — not discarded, but forwarded to `msgQ` with the original command context. Entity ID mismatch is `STUnexpectedError`.

## nonBlockingWriteTBQueue — fork on full

If `tryWriteTBQueue` returns `False`, a new thread is forked for the blocking write. No backpressure mechanism — under sustained overload, thread count grows without bound. This is a deliberate tradeoff: the caller never blocks (preventing deadlock between send and process threads), at the cost of potential unbounded thread creation.

## Batch commands do not expire

See comment on `sendBatch`. Batched commands are written with `Nothing` as the request parameter — the send thread skips the `pending` flag check. Individual commands use `Just r` and the send thread checks `pending` after dequeue. The coupling: if the router stops returning results, batched commands can block the send queue indefinitely since they have no timeout-based expiry.

## monitor — quasi-periodic adaptive ping

The ping loop sleeps for `smpPingInterval`, then checks elapsed time since `lastReceived`. If significant time remains in the interval (> 1 second), it re-sleeps for just the remaining time rather than sending a ping. This means ping frequency adapts to actual receive activity — frequent receives suppress pings.

Pings are only sent when `sendPings` is `True`, set by `enablePings` (called from `subscribeSMPQueue`, `subscribeSMPQueues`, `subscribeSMPQueueNotifications`, `subscribeSMPQueuesNtfs`, `subscribeService`). The client drops the connection when `maxCnt` commands have timed out in sequence AND at least `recoverWindow` (15 minutes) has passed since the last received result.

## clientCorrId — dual-purpose random values

`clientCorrId` is a `TVar ChaChaDRG` generating random `CbNonce` values that serve as both correlation IDs and nonces for proxy encryption. When a nonce is explicitly passed (e.g., by `createSMPQueue`), it is used instead of generating a random one.

## Proxy command re-parameterization

`proxySMPCommand` constructs modified `thParams` per-request — setting `sessionId`, `peerServerPubKey`, and `thVersion` to the proxy-relay connection's parameters rather than the client-proxy connection's. A single `SMPClient` connection to the proxy carries commands with different auth parameters per destination relay. The encoding, signing, and encryption all use these per-request params, not the connection's original params.

## proxySMPCommand — error classification

See comment above `proxySMPCommand` for the 9 error scenarios (0-9) mapping each combination of success/error at client-proxy and proxy-relay boundaries. Errors from the destination relay wrapped in `PRES` are thrown as `ExceptT` errors (transparent proxy). Errors from the proxy itself are returned as `Left ProxyClientError`.

## forwardSMPTransmission — proxy-side forwarding

Used by the proxy router to forward `RFWD` to the destination relay. Uses `cbEncryptNoPad`/`cbDecryptNoPad` (no padding) with the session secret from the proxy-relay connection. Result nonce is `reverseNonce` of the request nonce.

## authTransmission — dual auth with service signature

When `useServiceAuth` is `True` and a service certificate is present, the entity key signs over `serviceCertHash <> transmission` (not just the transmission) — see comment on `authTransmission`. The service key only signs the transmission itself. For X25519 keys, `cbAuthenticate` produces a `TAAuthenticator`; for Ed25519/Ed448, `C.sign'` produces a `TASignature`.

The service signature is only added when the entity authenticator is non-empty. If authenticator generation fails silently (returns empty bytes), service signing is silently skipped. This mirrors the [state-dependent parser contract](./Protocol.md#service-signature--state-dependent-parser-contract) in Protocol.hs.

## action — weak thread reference

`action` stores a `Weak ThreadId` (via `mkWeakThreadId`) to the main client thread. `closeProtocolClient` dereferences and kills it. The weak reference allows the thread to be garbage collected if all other references are dropped.

## writeSMPMessage — router-side event injection

`writeSMPMessage` writes directly to `msgQ` as `STEvent`, bypassing the entire command/result pipeline. This is used by the router to inject MSG events into the subscription result path.
