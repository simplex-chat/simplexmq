# Simplex.RemoteControl.Discovery

> Network discovery: local address enumeration, multicast group management, and TLS server startup.

**Source**: [`RemoteControl/Discovery.hs`](../../../../../../src/Simplex/RemoteControl/Discovery.hs)

## getLocalAddress — filtered interface enumeration

Enumerates network interfaces and filters out non-routable addresses (0.0.0.0, broadcast, link-local 169.254.x.x). Results are sorted: `mkLastLocalHost` moves localhost (127.x.x.x) to the end. If a preferred address is provided, `preferAddress` moves the matching entry to the front — matches by address first, falling back to interface name.

## Multicast subscriber counting

`joinMulticast` / `partMulticast` use a shared `TMVar Int` counter to track active listeners. Multicast group membership is per-host (not per-process — see comment in Multicast.hsc), so the counter ensures `IP_ADD_MEMBERSHIP` is called only when transitioning from 0→1 listeners and `IP_DROP_MEMBERSHIP` only when transitioning from 1→0. If `setMembership` fails, the counter is restored to its previous value and the error is logged (not thrown).

**TMVar hazard**: Both functions take the counter from the TMVar unconditionally but only put it back in the 0-or-1 branches. If `joinMulticast` is called when the counter is already >0, or `partMulticast` when >1, the TMVar is left empty and subsequent accesses will deadlock. In practice this is safe because `withListener` serializes access through a single `TMVar Int`, but the abstraction does not protect against concurrent use.

## startTLSServer — ephemeral port support

When `port_` is `Nothing`, passes `"0"` to `startTCPServer`, which causes the OS to assign an ephemeral port. The assigned port is read via `socketPort` and communicated back through the `startedOnPort` TMVar. On any startup error, `setPort Nothing` is signalled so callers don't block indefinitely on the TMVar.

The TLS server requires client certificates (`serverWantClientCert = True`) and delegates certificate validation to the caller-provided `TLS.ServerHooks`.

## withListener — bracket with subscriber tracking

`openListener` increments the multicast subscriber counter; `closeListener` decrements it in a `finally` block (ensuring cleanup even on exception). The `UDP.stop` call that closes the socket runs after the multicast part — if `partMulticast` fails, the socket is still closed.
