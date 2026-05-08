# Simplex.Messaging.Agent.RetryInterval

> Retry-with-backoff combinators for agent reconnection and worker loops.

**Source**: [`Agent/RetryInterval.hs`](../../../../../src/Simplex/Messaging/Agent/RetryInterval.hs)

## Overview

Four retry combinators with increasing sophistication: basic (`withRetryInterval`), counted (`withRetryIntervalCount`), foreground-aware (`withRetryForeground`), and dual-interval with external wake-up (`withRetryLock2`). All share the same backoff curve via `nextRetryDelay`.

## Backoff curve — nextRetryDelay

Delay stays constant at `initialInterval` until `elapsed >= increaseAfter`, then grows by 1.5x per step (`delay * 3 / 2`) up to `maxInterval`. The `delay == maxInterval` guard short-circuits the comparison once the cap is reached.

## updateRetryInterval2 — resume from saved state

Sets `increaseAfter = 0` on both intervals. This skips the initial constant-delay phase — the next retry will immediately begin increasing from the saved interval. Used to restore retry state across reconnections without restarting from the initial interval.

## withRetryForeground — reset on foreground/online transition

The retry loop resets to `initialInterval` when either:
- The app transitions from background to foreground (`not wasForeground && foreground`)
- The network transitions from offline to online (`not wasOnline && online`)

The STM transaction blocks on three things simultaneously: the `registerDelay` timer, the `isForeground` TVar, and the `isOnline` TVar. Whichever fires first unblocks the retry. On reset, elapsed time is zeroed.

The `registerDelay` is capped at `maxBound :: Int` (~36 minutes on 32-bit) to prevent overflow.

## withRetryLock2 — interruptible dual-interval retry

Maintains two independent backoff states (slow and fast) that the action toggles between by calling the loop continuation with `RISlow` or `RIFast`. Only the chosen interval advances; the other preserves its state.

The `wait` function is the non-obvious part: it spawns a timer thread that puts `()` into the `lock` TMVar after the delay, while the main thread blocks on `takeTMVar lock`. This means the retry can be woken early by *external code* putting into the same TMVar — the timer is just a fallback. The `waiting` TVar prevents a stale timer from firing after the main thread has already been woken by an external signal.

**Consumed by**: [Agent/Client.hs](./Client.md) — `reconnectSMPClient` uses the lock TMVar to allow immediate reconnection when new subscriptions arrive, rather than waiting for the full backoff delay.
