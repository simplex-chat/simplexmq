// Retry interval logic.
// Transpilation of Agent/RetryInterval.hs (lines 27-118).
// withRetryForeground is skipped (uses registerDelay + STM retry, Haskell-specific).

import {TMVar} from "./tmvar.js"

// RetryInterval (RetryInterval.hs:27-31)
// All intervals in microseconds (matching Haskell Int64).
export interface RetryInterval {
  initialInterval: number
  increaseAfter: number
  maxInterval: number
}

// RetryInterval2 (RetryInterval.hs:33-36)
export interface RetryInterval2 {
  riSlow: RetryInterval
  riFast: RetryInterval
}

// RI2State (RetryInterval.hs:38-41)
export interface RI2State {
  slowInterval: number
  fastInterval: number
}

// RetryIntervalMode (RetryInterval.hs:51)
export type RetryIntervalMode = "RISlow" | "RIFast"

// nextRetryDelay (RetryInterval.hs:114-118)
export function nextRetryDelay(elapsed: number, delay: number, ri: RetryInterval): number {
  if (elapsed < ri.increaseAfter || delay === ri.maxInterval) return delay
  return Math.min(Math.floor(delay * 3 / 2), ri.maxInterval)
}

// updateRetryInterval2 (RetryInterval.hs:44-49)
export function updateRetryInterval2(state: RI2State, ri2: RetryInterval2): RetryInterval2 {
  return {
    riSlow: {...ri2.riSlow, initialInterval: state.slowInterval, increaseAfter: 0},
    riFast: {...ri2.riFast, initialInterval: state.fastInterval, increaseAfter: 0},
  }
}

function delay(us: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, us / 1000))
}

// withRetryInterval (RetryInterval.hs:54-55)
export function withRetryInterval(
  ri: RetryInterval,
  action: (delay: number, loop: () => Promise<void>) => Promise<void>,
): Promise<void> {
  return withRetryIntervalCount(ri, (_n, d, loop) => action(d, loop))
}

// withRetryIntervalCount (RetryInterval.hs:57-66)
export function withRetryIntervalCount(
  ri: RetryInterval,
  action: (n: number, delay: number, loop: () => Promise<void>) => Promise<void>,
): Promise<void> {
  function callAction(n: number, elapsed: number, d: number): Promise<void> {
    return action(n, d, async () => {
      await delay(d)
      const elapsed_ = elapsed + d
      return callAction(n + 1, elapsed_, nextRetryDelay(elapsed_, d, ri))
    })
  }
  return callAction(0, 0, ri.initialInterval)
}

// withRetryLock2 (RetryInterval.hs:90-112)
// Two-mode retry with lock. The lock (TMVar<void>) can be released early
// by an external signal (e.g., QCONT message), cancelling the timer wait.
//
// The action receives the current RI2State and a loop function.
// Calling loop(mode) sleeps for the appropriate interval, then recurses.
// During sleep, if the lock is released externally, sleep ends early.
export function withRetryLock2(
  ri2: RetryInterval2,
  lock: TMVar<void>,
  action: (state: RI2State, loop: (mode: RetryIntervalMode) => Promise<void>) => Promise<void>,
): Promise<void> {
  function callAction(slow: [number, number], fast: [number, number]): Promise<void> {
    return action({slowInterval: slow[1], fastInterval: fast[1]}, (mode) => {
      if (mode === "RISlow") return run(slow, ri2.riSlow, (s) => callAction(s, fast))
      return run(fast, ri2.riFast, (f) => callAction(slow, f))
    })
  }

  async function run(
    [elapsed, d]: [number, number],
    ri: RetryInterval,
    call: (state: [number, number]) => Promise<void>,
  ): Promise<void> {
    await wait(d)
    const elapsed_ = elapsed + d
    const delay_ = nextRetryDelay(elapsed_, d, ri)
    return call([elapsed_, delay_])
  }

  // wait (RetryInterval.hs:105-112)
  // Race between timer expiry and external lock release.
  // In Haskell: forkIO sets a timer that puts () into the lock TMVar,
  // then the main thread takes from the lock (blocking until timer or external signal).
  async function wait(d: number): Promise<void> {
    let waiting = true
    // Start timer that will release the lock after delay
    const timer = setTimeout(() => {
      if (waiting) lock.tryPut(undefined as any)
    }, d / 1000)
    // Block until lock is released (by timer or externally)
    await lock.take()
    waiting = false
    clearTimeout(timer)
  }

  return callAction([0, ri2.riSlow.initialInterval], [0, ri2.riFast.initialInterval])
}
