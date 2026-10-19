# Agent: choose another proxy when the chosen proxy keeps failing

## Problem

With private routing, a connection can stay at "connecting…", or a join can fail on every "Retry", until the app restarts. The sending agent picks one proxy for each destination relay and keeps it. If that proxy can't forward to the relay, every retry goes through the same proxy. Restarting the app picks a proxy again, and the connection then completes in seconds.

Seen on 2026-10-14 with public servers: smp4 → smp10 forwarding timed out repeatedly for ~10 minutes, and connections whose sender had picked smp4 as proxy for smp10 stalled for the whole time, in all app and CLI versions tried (simplex-chat 7.0.0.9, 7.1.0.10).

## Cause

`smpProxiedRelays` in `Agent/Client.hs` maps the destination session to the chosen proxy. `getSMPProxyClient` reuses the entry when it exists; otherwise it uses the server from `getNextServer`, or the proxy it was given (the #1178 retry, see below). The entry is removed when creating the proxied relay session (PRXY) fails with an error other than a host error (`newProxiedRelay`), when the proxy connection is closed (`smpClientDisconnected`), and when the agent is closed.

Two failures keep it:

1. Connecting to the proxy itself fails (proxy offline or unreachable). There is no proxy connection to close, so the entry stays, and retries use this proxy until it is reachable again or the app restarts.
2. A forwarded command (PFWD) fails with `PROXY (BROKER e)` other than a host error, e.g. `PROXY (BROKER TIMEOUT)`: the proxy has a session to the relay but can't reach it, or gets a broken response from it. `sendViaProxy` only handles `PROXY NO_SESSION`; the proxy connection stays up, so the entry stays until it is closed.

The existing delayed resets don't get off such a proxy:
- A failed connection's error is kept for `persistErrorInterval` (3 s), then the agent connects again, to the same remembered proxy.
- The client's connection monitor drops a connection after 3 timed-out commands in a row and at least 15 minutes since the last response. A proxy that answers PFWD with errors keeps the connection alive, so this never fires in case 2.
- The proxy's own connection to the relay is dropped by the same monitor on the proxy, which also deletes its sessions to that relay. The client's next PFWD then gets `PROXY NO_SESSION` and, by design (#1178), creates a new session through the same proxy, which reconnects to the relay. The proxy is changed only if that PRXY fails (e.g. the proxy can't reconnect; it then keeps the connect error for 30 s). If the proxy reconnects but forwarding keeps failing, the stall continues.

## Fix

Forget the chosen proxy for this destination, so that the next attempt chooses again:

- `getSMPProxyClient`, case 1: at once, when getting a connection to the proxy fails. The agent connects to a proxy only when it has no live connection to it, and a disconnect already deletes the choices for the destinations it had sessions to, so this proxy normally has not received this destination under the current choice: choosing again is just another random draw: no more proxies learn the destination than with the first choice. This also holds when the client's own network is down: the old connection is dropped and the choice deleted, as before. A request that only waits for a connection started by another request (e.g. another send via this proxy, or a subscription to the proxy's server) doesn't forget the proxy when its wait times out (`BROKER _ TIMEOUT`, which only a wait produces; a connection's own connect timeout is `BROKER _ NETWORK`). If the connection fails while the request waits, the request gets the connection's error and forgets the proxy.
- `sendViaProxy`, case 2: when the proxy keeps failing. A `ProxyProtocolError (PROXY (BROKER e))` where `e` is not a host error records when the current streak of failures started, if none is recorded. A forwarded command that succeeds, or that gets an error from the destination relay back through the proxy (e.g. `AUTH`, `QUOTA` in the relay's response, or `PROXY (PROTOCOL _)`, the relay's error to the proxy), clears it: all show that the proxy reaches the relay. A failure that comes at least `proxyFailureInterval` (new `AgentConfig` field, 30 s) after the start of the streak forgets the proxy. Here the proxy has already received the destination, and a new one would too, so one timeout, or a burst of failures within 30 s (e.g. all requests in flight when the relay restarts), does not move the destination to another proxy as long as a later forward reaches the relay.

The streak start is stored in `smpProxiedRelays` next to the chosen proxy, so it goes away whenever the choice is deleted or replaced. Failures, successes and deletes change the entry only if it still names that proxy (`deleteProxiedRelay` also for `smpClientDisconnected` and `newProxiedRelay`): after a re-pick the old proxy can still hold a session to the relay, and its later disconnect, failure or success must not change the new choice.

When the proxy reports `PROXY NO_SESSION`, `deleteRelaySession` now removes the dead session from the relay sessions of the proxy client that handled the request, instead of looking that client up through `smpProxiedRelays`. Otherwise, after a concurrent request forgot the proxy, the dead session stayed, and the retry through the same proxy (#1178) used it again and failed. That retry passes this proxy explicitly, and an explicit proxy is now used without being recorded as the choice when there is none, so a retry after the proxy was forgotten doesn't put it back; when another proxy is already chosen, the retry uses that one, as before.

A failed PRXY still forgets the proxy at once, as before. Other PFWD errors neither count nor clear the streak, e.g. unexpected or unparsable responses from the proxy itself, a relay response of the wrong type or one that can't be parsed, and a timeout in the client. (The relay's unexpected or unparsable responses to the proxy arrive as `PROXY (BROKER _)` and count.) The direct-connection fallback is unchanged: it is still decided by `serverHostError` on the returned error.

Timing of case 2, with the default timeouts on a fast network (the client's waits are 1.5 times longer on a slow network, so there the proxy's first report can come even earlier; the outcome is the same): the proxy waits for the relay for 30 s (`forwardSMPTransmission` uses `NRMBackground`), while background delivery waits 60 s for PFWD, so the proxy's `PROXY (BROKER TIMEOUT)` arrives first. Retries start 2 s apart, so the second report comes about 32 s after the first and forgets the proxy, and the next retry chooses again, about a minute after the first send. An interactive request such as joining a connection waits 20 s on the first attempt, then 30 s and 45 s on "Retry"; its client timeouts ("Connection timeout" in the app) don't count, so the first proxy report ("Private routing timeout") comes on the first or second Retry, the next Retry's report forgets the proxy, and the Retry after it chooses again. If the proxy connection itself stops answering, the proxy is forgotten when that connection is dropped (at least 15 minutes without any response), as before.

Not changed: a host error reported by the proxy about the relay (PRXY or PFWD) keeps the entry, as before (a host error connecting to the proxy itself forgets it, as in case 1). E.g. an onion-only relay and a chosen proxy without Tor (`PROXY (BROKER HOST)`) stay together; while direct sending is not allowed, such sends keep failing.

The failed proxy is not excluded from the next pick, which follows the usual rules (another operator and host than the destination's, when possible), so a retry can pick it again (half of the time with two proxies), but it no longer keeps it forever.

Privacy: each proxy used for a destination learns the client's IP address and the destination host, so re-picks in case 2 spread one destination over more proxies, as failed PRXYs already do. If the relay itself is unreachable for every proxy, that usually shows as failed PRXYs, which move the destination on every retry, as before; if it is only slow for every proxy, background delivery moves the destination to another proxy about once a minute while that lasts.

## Verification

Tests (`SMPProxyTests`; in the first two the agent's server RNG is seeded so that the first pick is the bad proxy):
- "chooses another proxy when the chosen proxy is offline": nothing listens on the first proxy's port.
- "chooses another proxy when the chosen proxy cannot forward to destination relay": the proxy's relay client uses a 1 µs TCP timeout, so PRXY succeeds and every PFWD returns `PROXY (BROKER TIMEOUT)`, the error seen in production. The test uses `proxyFailureInterval` 0, so the second failure forgets the proxy. A forward that timed out at this proxy can still reach the relay, so each extra attempt through it can add a duplicate command; with many of them the connection may not complete within the test's time.
- "keeps the chosen proxy until it fails for proxyFailureInterval" (1 s): two failures in a row keep the proxy, a success clears the streak, a failure for another proxy changes nothing, and the first failure 1 s after the start of the streak forgets the proxy.

Desktop and Android results are in the PRs.
