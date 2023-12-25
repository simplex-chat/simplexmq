# SMP proxy implementation concerns

* SMP proxy traffic should be indistinguishable from ordinary relay operation.
* Proxy servers should be implemented by the same binary to prevent maintenance bloat.

This leads to the proxy functionality added directly to the SMP protocol, raising its version.

## Involved parties

### Client

> Client, from the servers' point of view, means the agent running inside a client app. An app/agent protocol is unchanged.

A client that wants to utilize proxy functionality should request protocol version no lower than adds support for it.

A client should be able to configure its usage of SMP proxies.
Due to proxy/relay integration, there can be some usage patterns (or some blend of them):

1. Single connection for everything. A client uses its only connection for both creating queues for reception and forwarding messages to remote relays. This can be favorable for power-constrained operation or utilizing a TOR hidden service.
2. Multiple bi-directional SMP connections to public SMP servers. A client spreads its queues over multiple relays as it currently does, and pools them for sending too. Good for redundancy and perhaps sending latency, but also reducing active connections esp. for keen group posters.
3. Split providers for ingress and egress. Some users may prefer using relays from Provider A, but proxies from Provider B to minimize risks like collusion and correlation.

Option 3 requires either maintaining a proxy list distinct from the relay list or having a "Relay/Proxy/Both" toggle (assuming a server is configured to provide both types).

Additional concern is possibility of using a proxy to forward messages to a relay operating on the same node.
Can a server refuse to "connect to itself" or should it be client decision entirely?
- Allowing self-connections may be more efficient as proxy can just short-circuit delivery and this is no worse for privacy than issuing SEND command directly on it.
- Enforcing this as a general rule may interfere with the scenario 1 from the above list.

Client agent runs a separate "proxy" worker to deal with safety limitations specific to this channel.

When sending a message, a client should make a routing decision.
Depending on its delivery configuration (`directly`/`only-unknown`/`all`/`force-hop`) and state it may:
- Connect to a relay (`directly`/`only-unknown`) or reuse existing connection and `SEND`.
- Connect to a proxy or pick one from a pool (excluding the same address as the destination relay for `force-hop` mode) and
  * Request a new relay connection.
  * `FORWARD` message to a proxy.

For group traffic a client will have to utilize a pool of proxies since many recipients can be sitting on the same relay, bottlenecking delivery on the user cluster.
An agent can spread delivery to the same relay across multiple proxies, minimizing per-server queue length.
This will also help with protecting the group participation information from servers and makes a case for using multiple SMP providers.
An alternative server-side batching command makes membership correlation trivial for malicious servers.

### Proxy server

Running a proxy service adds another potentially unbounded source of load to a server.
Previously, a client could flood relay with queue creation requests or pump messages through it, generating local load.
With proxy enabled, a client may now ask a server to open connections to arbitrary hosts/ports, which may affect external services, not unlike open access proxies. An SMP proxy, by the virtue of being app-specific, can enforce more guardrails, limiting problems from malicious clients.

- Failed `server` requests may incur a penalty/backpressure to protect external services and proxy.
- Forwarding is blocked until a reply comes back to protect proxy.
- Minimal client response time at ~2 seconds to protect client.
- Forwarding requests are pulled from client queues and handled one by one to protect relay.
- Fair client scheduling towards a relay to protect clients from each other.

Each proxy-to-relay (P2R) connection aggregates traffic from multiple clients and protected by a

A proxy runs a barebones SMP protocol towards each active relay, fronted by an `MVar` which, unlike other concurrency primitives, guarantee fairness. With it, each client "forwarding" worker takes a unit of work and tries to submit it to a relay worker.

A client should not be able to inspect/probe relay connections and distinguish a fresh connection from an existing one. Thus each client gets a `server_id` map with ids distinct from the proxy internal relay map. This also precludes accidental coupling between implementation and protocol format with its (quite severe) limits.

### Relay server

As with notification subscriber "clients" a proxy is just an another client with a special set of commands for setup and forwarding.
The usual SMP precautions apply.

## Failure modes

### Delivery problems

A delivery latency may increase due to:
- Slow client/proxy handshake.
- Slow proxy/relay handshake for new servers.
- Long time waiting for its turn to send due to lots of active clients.
- Long time to deliver to relay due to overloaded server.
This can be mitigated by proxy pool.
A pool may be monitoring proxy latency in general and towards a specific server, then route accordingly.

A message non-delivery may happen due to:
- Proxy misconfiguration. Report error to user.
- Relay stopped operating or proxy lost its connection. Signalled to client by proxy `ERR`. Retry later.
- Proxy stopped operating or client lost its connection. Signalled by connection error. Retry with another proxy or later.

A duplicate delivery may happen due to:
- Client used multiple routes to deliver (e.g. because of apparent non-delivery).
- Proxy replaying messages (maliciously or by misconfiguration).
This is mitigated client side by deduplication. And, optionally, relay side, by using bloom filter with message DH keys.

### Connectivity problems

A proxy may lose connection to a relay.
The protocol lacks proxy notifications, so a client may only be informed of the failure state when it tries to forward a message.
If a client tries to send to a dropped connection it gets an `ERR` and must de-associate the server from the proxy.
The proxy should flush its client queues related to the server and respond with `ERR`.
The proxy should attempt to reconnect if it has pending messages, as the clients have already got their `OK`.
Otherwise the proxy may attempt to reconnect to the relay, expecting future client attempts to restore their connections.

A client may lose connection to a proxy.
It should wipe its `server_id` mapping and reconnect to resume operations.
A pool may down-weight the proxy proportionally to its uptime to prevent latency problems.

### Denial of service attacks

A malicious client can request connections (esp. to a coopted relay) to exhaust proxy resources.
A proxy should use tight timeouts, synchronous delivery and backpressure to limit damage.

A malicious client can request connections to addresses that aren't SMP relays (e.g. for probing or DoSing).
A proxy should rapidly escalate penalties for non-SMP connections, up to reporting client IP to a host firewall.
