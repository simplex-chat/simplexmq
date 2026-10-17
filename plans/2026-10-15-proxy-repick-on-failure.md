# Agent: choose another proxy when the chosen proxy fails

## Problem

With private routing, a connection can stay at "connecting…", or a join can fail on every "Retry", until the app restarts. The sending agent picks one proxy for each destination relay and keeps it. If that proxy can't forward to the relay, every retry goes through the same proxy. Restarting the app picks a proxy again, and the connection then completes in seconds.

Seen on 2026-10-14 with public servers: smp4 → smp10 forwarding timed out repeatedly for ~10 minutes, and connections whose sender had picked smp4 as proxy for smp10 stalled for the whole time, in all app and CLI versions tried (simplex-chat 7.0.0.9, 7.1.0.10).

## Cause

`smpProxiedRelays` in `Agent/Client.hs` maps the destination session to the chosen proxy. `getSMPProxyClient` reuses the entry when it exists, and uses the server from `getNextServer` only when it doesn't. The entry is removed when creating the proxied relay session (PRXY) fails with an error other than a host error (`newProxiedRelay`), when the proxy connection is closed (`smpClientDisconnected`), and when the agent is closed.

Two failures keep it:

1. Connecting to the proxy itself fails (proxy offline or unreachable). There is no proxy connection to close, so the entry stays, and retries use this proxy until it is reachable again or the app restarts.
2. A forwarded command (PFWD) fails with `PROXY (BROKER e)` other than a host error, e.g. `PROXY (BROKER TIMEOUT)`: the proxy has a session to the relay but can't reach it, or gets a broken response from it. `sendViaProxy` only handles `PROXY NO_SESSION`; the proxy connection stays up, so the entry stays until it is closed.

## Fix

Forget the chosen proxy for this destination in both cases, so that the next attempt chooses again:

- `getSMPProxyClient`: when getting a connection to the proxy fails. A request that only waits for a connection started by another request (e.g. another send via this proxy, or a subscription to the proxy's server) doesn't forget the proxy when its wait times out (`BROKER _ TIMEOUT`, which only a wait produces; a connection's own connect timeout is `BROKER _ NETWORK`). If the connection fails while the request waits, the request gets the connection's error and forgets the proxy; if it fails later, the next attempt that gets a connection error does.
- `sendViaProxy`: on `ProxyProtocolError (PROXY (BROKER e))` where `e` is not a host error.

`deleteProxiedRelay` deletes the entry only if it still names the proxy that failed. `smpClientDisconnected` and `newProxiedRelay` now use it too: after a re-pick the old proxy can still hold a session to the relay, and its later disconnect or failure must not undo the new choice.

Other PFWD errors keep the entry, e.g. errors of the forwarded command returned by the destination relay, `PROXY (PROTOCOL _)`, unexpected or unparsable responses from the proxy itself, and a timeout in the client. (The relay's unexpected or unparsable responses to the proxy arrive as `PROXY (BROKER _)` and forget it.) The direct-connection fallback is unchanged: it is still decided by `serverHostError` on the returned error. A host error when connecting to the proxy now also forgets it, so the next attempt can use another proxy instead of falling back to direct sending again.

Timing, with the default timeouts: the proxy waits for the relay for 30 s (`forwardSMPTransmission` uses `NRMBackground`). Background delivery waits 60 s for PFWD, so the proxy reports `PROXY (BROKER TIMEOUT)` first and the next automatic retry chooses again. The first attempt of an interactive request such as joining a connection waits only 20 s and fails with a client timeout ("Connection timeout" in the app), which keeps the proxy; the first "Retry" waits 30 s, the same as the proxy's wait, so either the client's timeout or the proxy's report ("Private routing timeout") ends it; if it is the client's, the second Retry (45 s) gets the proxy's report. The Retry after the proxy's report chooses again. If the proxy connection itself stops answering, the proxy is forgotten when that connection is dropped after repeated timeouts (at least 15 minutes without any response), as before.

Not changed: a host error reported by the proxy about the relay (PRXY or PFWD) keeps the entry, as before. E.g. an onion-only relay and a chosen proxy without Tor (`PROXY (BROKER HOST)`) stay together; while direct sending is not allowed, such sends keep failing.

The failed proxy is not excluded from the next pick, which follows the usual rules (another operator and host than the destination's, when possible), so a retry can pick it again, but it no longer keeps it forever.

Privacy: each proxy used for a destination learns the client's IP address and the destination host. A re-pick on these failures can spread one destination over more proxies. That already happens when PRXY fails, and is the price of not staying stuck; but these failures are not always the proxy's fault: an overloaded or restarting relay can cause case 2, and the client's own unreliable network can cause case 1.

## Verification

Tests (`SMPProxyTests`, the agent's server RNG is seeded so that the first pick is the bad proxy):
- "chooses another proxy when the chosen proxy is offline": nothing listens on the first proxy's port.
- "chooses another proxy when the chosen proxy cannot forward to destination relay": the proxy's relay client uses a 1 µs TCP timeout, so PRXY succeeds and every PFWD returns `PROXY (BROKER TIMEOUT)`, the error seen in production.

Before the fix both tests fail in 6/6 runs (the connection never completes within 10 s); with the fix both pass.

Desktop app (simplex-chat with this simplexmq), local servers: destination relay R; proxy P1 that reaches R through a SOCKS relay passing the TLS and SMP handshake and then dropping all bytes (so PRXY succeeds and every command P1 forwards gets no answer from R); good proxy P2; the app uses only P1 and P2 for messages. Trials with this code where the first pick was P1:
- The peer joins the app's 1-time link, so the app sends its confirmation in the background: connected with no user action after 33 s and 95 s (2/2). Master: not connected after 10 minutes (2/2).
- The app joins a link and the user taps "Retry" after each error: connected after 2 to 4 Retries, 52 to 114 s (6/6). In the 4 trials whose errors were logged, the first Retry ended with "Private routing timeout" in 2. Master: not connected after 6 Retries (2/2).

In the two logged trials that needed 4 Retries, P1 reported the failure more than once: the next pick was P1 again, which is possible because the failed proxy is not excluded.
