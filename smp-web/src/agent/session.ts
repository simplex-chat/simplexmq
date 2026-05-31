// SessionVar — pending protocol client connection tracking.
// Transpilation of Simplex.Messaging.Session (Session.hs:18-42).
//
// SessionVar wraps a Promise that resolves when the client connection is established.
// First caller creates it (Left/new), subsequent callers get the existing one (Right/existing)
// and await the same Promise.

export interface SessionVar<T> {
  id: number
  ts: number  // creation timestamp (ms)
  promise: Promise<T>
  resolve: (v: T) => void
  reject: (e: Error) => void
  value: T | undefined  // set after resolve, for tryRead
}

// getSessVar (Session.hs:24-33)
// Get existing SessionVar for key, or create a new empty one.
// Returns {isNew: true, v} for new, {isNew: false, v} for existing.
// Mirrors Haskell Left (new) / Right (existing).
export function getSessVar<T>(
  seq: {val: number},
  key: string,
  vars: Map<string, SessionVar<T>>,
): {isNew: boolean, v: SessionVar<T>} {
  const existing = vars.get(key)
  if (existing) return {isNew: false, v: existing}
  let resolve!: (v: T) => void
  let reject!: (e: Error) => void
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej })
  // When resolved, store value for tryRead
  const v: SessionVar<T> = {
    id: seq.val++,
    ts: Date.now(),
    promise,
    resolve: (val: T) => { v.value = val; resolve(val) },
    reject,
    value: undefined,
  }
  vars.set(key, v)
  return {isNew: true, v}
}

// removeSessVar (Session.hs:35-39)
// Remove only if the ID matches — guards against removing a replaced session.
export function removeSessVar<T>(
  v: SessionVar<T>,
  key: string,
  vars: Map<string, SessionVar<T>>,
): void {
  const current = vars.get(key)
  if (current && current.id === v.id) vars.delete(key)
}

// tryReadSessVar (Session.hs:41-42)
// Non-blocking read of resolved value. Returns undefined if not yet resolved.
export function tryReadSessVar<T>(
  key: string,
  vars: Map<string, SessionVar<T>>,
): T | undefined {
  return vars.get(key)?.value
}
