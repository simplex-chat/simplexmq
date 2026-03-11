# Simplex.Messaging.Session

> Atomic get-or-create session variables with identity-safe removal.

**Source**: [`Session.hs`](../../../../src/Simplex/Messaging/Session.hs)

## getSessVar

Returns `Left newVar` if the key was absent (variable created), `Right existingVar` if already present. The new variable gets an atomically incremented `sessionVarId` from the shared counter, and its `sessionVar` TMVar starts empty.

The caller uses the `Left`/`Right` distinction to decide whether to populate the TMVar (new session) or wait on the existing one.

## removeSessVar

Only removes if the stored variable's `sessionVarId` matches the one being removed. This is a compare-and-swap pattern: between the time a caller obtained a `SessionVar` and the time it tries to remove it, another thread may have replaced it with a new session (via `getSessVar`). Without the ID check, the stale caller would remove the new session.
