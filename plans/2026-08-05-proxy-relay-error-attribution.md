## Root cause: PRXY errors are attributed to the forwarding server instead of the destination relay

When private routing is enabled and the destination relay is unreachable, the client reports
**"Error connecting to forwarding server smp5.simplex.im"** — naming a preset server that the client
connected to successfully. Retrying rotates to the next proxy (`getNextServer`, `Agent/Client.hs:689`)
and produces the same message with a different preset server, so the destination server is never named
and the failure looks like an outage of our own infrastructure.

### Reproduction

Connecting to a contact address on an unresolvable host (`simplex.server.home`, no DNS record):

```
-- private routing off (correct)
BROKER {brokerAddress = "smp://VvXX…@simplex.server.home:5223",
        brokerErr = NETWORK {networkError = NEConnectError {connectError = "…does not exist (Name or service not known)"}}}

-- private routing on (misattributed)
SMP {serverAddress = "smp://…@smp5.simplex.im,…onion",
     smpErr = PROXY {proxyErr = BROKER {brokerErr = NETWORK {networkError = NEFailedError}}}}
```

### The asymmetry between the two proxied paths

A server returns `PROXY (BROKER …)` only from `smpProxyError` (`Client.hs:804-815`), which is called
exclusively where the proxy failed to reach the relay — `PRXY` (`Server.hs:1444`) and `PFWD`
(`Server.hs:1466`). The error therefore *always* describes the proxy→relay hop. The two paths then
diverge in how the agent wraps it:

**PFWD — keeps both addresses** (`Agent/Client.hs:1183-1189`): the proxy's error arrives as
`Left ProxyClientError` and is thrown as `PROXY {proxyServer, relayServer, proxyErr}`.

**PRXY — drops the relay** (`Agent/Client.hs:713`): `connectSMPProxiedRelay` has no `Either` layer, so
the error arrives as `PCEProtocolError` and `liftClient SMP` maps it to `SMP <proxyAddr> (PROXY …)`
(`Agent/Client.hs:1244`). The destination address is discarded.

Both clients read the second shape as a client→proxy failure and word it accordingly
(`SimpleXAPI.kt:2692`, `ErrorAlert.swift:117`), which is never what it means.

### Fix

In `newProxiedRelay`, map proxy-reported `PROXY (BROKER …)` errors to the same shape `PFWD` already
produces:

```haskell
proxyRelayError :: HostName -> ErrorType -> AgentErrorType
proxyRelayError proxyHost = \case
  e@(SMP.PROXY (SMP.BROKER _)) -> PROXY {proxyServer = protocolClientServer smp, relayServer = …destSrv, proxyErr = ProxyProtocolError e}
  e -> SMP proxyHost e
```

`liftClient` applies this only to `PCEProtocolError`, so genuine client↔proxy failures (response
timeout, network error, proxy transport version) still map to `BROKER <proxy> …` and remain attributed
to the proxy. Both apps already render the resulting shape correctly, with no client change:
*"Forwarding server smp5.simplex.im failed to connect to destination server simplex.server.home."*

The guard is `BROKER` rather than every `ProxyError`, so the remap covers exactly the misattributed
class and nothing else. `BASIC_AUTH` is deliberately excluded — the proxy returns it when proxying is
disabled or the basic auth does not match (`Server.hs:1416-1420`), which is a client↔proxy fact and is
correctly attributed today. `NO_SESSION` is returned only for `PFWD`. `PROTOCOL` describes the relay
but is not rendered as a proxy-connection error by either client, so leaving it unchanged keeps the
diff to the errors that actually produce a wrong message.

### Blast radius

- `temporaryAgentError` (`Agent/Client.hs:1572-1580`) and `serverHostError` (`:1594-1596`) already match
  both shapes with the same helpers — retry and proxy-fallback behaviour is unchanged.
- `clientServiceError` (`:1268-1273`) has no `PROXY`-shape twin for `BROKER NO_SERVICE`, but both ends
  document that case as unreachable (`Client.hs:812`); left as is.
- simplex-chat `Subscriber.hs:1819-1820` handles both shapes; send failures move from `SndErrProxy` to
  `SndErrProxyRelay`, i.e. "Destination server error" rather than "Error" — also more accurate.
- `SMP _ (PROXY _)` becomes unreachable, making `smpProxyErrorAlert` in both clients dead code. Removing
  it is a follow-up in simplex-chat, not required by this change.

### Verification

- Reproduced before/after with a CLI built against this branch: the error now carries
  `relayServer = "smp://VvXX…@simplex.server.home:5223"`, and the direct (non-proxied) path is
  byte-identical to before.
- `SMPProxyTests`: 45 examples, 0 failures — including `fails when fallback is prohibited` and both
  retry tests, which exercise `newProxiedRelay` and the error classification.
