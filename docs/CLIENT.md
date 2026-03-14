# SimpleX Client Libraries

SimpleX client libraries provide low-level protocol access to SimpleX routers. They implement the wire protocols ([SMP](../protocol/simplex-messaging.md), [XFTP](../protocol/xftp.md), [NTF](../protocol/push-notifications.md)) and handle connection lifecycle, but leave encryption, identity management, and connection orchestration to the application.

This is **Layer 2** of the [SimpleX Network architecture](../protocol/overview-tjr.md). Layer 1 is the routers themselves; Layer 3 is the [Agent](AGENT.md), which builds duplex encrypted connections on top of these libraries. For internal architecture diagrams (thread topology, command processing flows), see [`spec/clients.md`](../spec/clients.md).

## SMP Client

**Source**: [`Simplex.Messaging.Client`](../src/Simplex/Messaging/Client.hs). For architecture and module specs, see [SMP Client](../spec/clients.md#smp-client-protocolclient).

The SMP client connects to SMP routers and manages simplex messaging queues — the fundamental addressing primitive of the SimpleX Network. Each simplex queue is a unidirectional, ordered sequence of fixed-size packets (16,384 bytes) with separate cryptographic credentials for sending and receiving. The queue model and command set are defined in the [SMP protocol](../protocol/simplex-messaging.md).

### Capabilities

- **Queue management**: create, secure, subscribe to, and delete queues on any SMP router. Queue operations use the [SMP command set](../protocol/simplex-messaging.md) (NEW, KEY, SUB, DEL, etc.).
- **Message sending and receiving**: send messages to a queue's sender address; receive messages from a queue's recipient address
- **Command authentication**: each queue operation is authenticated with per-queue cryptographic keys (Ed25519, Ed448, or X25519). See the [SMP protocol security model](../protocol/simplex-messaging.md) for key roles.
- **Keep-alive**: automatic ping loop detects and recovers from half-open connections
- **Proxy forwarding**: send messages through a proxy router via 2-hop onion routing (PRXY/PFWD/RFWD commands), protecting the sender's IP address from the destination router. See [proxy forwarding details](../spec/modules/Simplex/Messaging/Client.md) in the module spec.
- **Batched commands**: multiple commands can be sent in a single transmission for efficiency

### API model

The client uses a functional Haskell API with STM queues for asynchronous event delivery:

- **Commands** are sent via `sendProtocolCommand` (single) or `sendBatch` (multiple). Each returns a result synchronously or via timeout.
- **Router events** (incoming messages, subscription notifications) arrive on `msgQ`, an STM `TBQueue` that the application reads from its own thread.
- **Connection lifecycle** is managed automatically: the client maintains send, receive, process, and monitor threads internally. When any thread fails, all are torn down and the `disconnected` callback fires.

### Router identity

Routers are identified by the SHA-256 hash of their CA certificate fingerprint, not by hostname. The client validates the full X.509 certificate chain on every TLS connection and compares the CA fingerprint against the expected hash from the queue address. This means a DNS or IP-level attacker who cannot produce the correct certificate is detected at connection time.

## XFTP Client

**Source**: [`Simplex.FileTransfer.Client`](../src/Simplex/FileTransfer/Client.hs). For architecture and module specs, see [XFTP Client](../spec/clients.md#xftp-client).

The XFTP client connects to XFTP routers and manages data packets — individually addressed blocks used for larger payload delivery. Data packets come in fixed sizes (64KB, 256KB, 1MB, 4MB), hiding the actual payload size. The XFTP protocol runs over HTTP/2, simplifying browser integration. The data packet lifecycle and command set are defined in the [XFTP protocol](../protocol/xftp.md).

### Capabilities

- **Data packet creation**: create data packets on routers with sender, recipient, and optional additional recipient credentials. See the [XFTP protocol](../protocol/xftp.md) for credential roles and packet lifecycle.
- **Send** (FPUT): send encrypted data to the router in a single HTTP/2 streaming request (command + body)
- **Receive** (FGET): receive data packets with per-request ephemeral Diffie-Hellman key exchange, providing forward secrecy — compromising one DH key does not reveal other received data packets
- **Acknowledgment and deletion**: recipients acknowledge receipt; senders delete data packets after delivery

## NTF Client

**Source**: [`Simplex.Messaging.Notifications.Client`](../src/Simplex/Messaging/Notifications/Client.hs). For architecture and module specs, see [NTF Client](../spec/clients.md#ntf-client).

The NTF client connects to NTF (notification) routers and manages push notification tokens and subscriptions. It implements the [Push Notifications protocol](../protocol/push-notifications.md).

### Capabilities

- **Token management**: register, verify, replace, and delete push notification tokens on NTF routers
- **Subscription management**: create, check, and delete notification subscriptions that link SMP queues to push tokens
- **Batch operations**: create or check multiple subscriptions in a single request, with per-item error handling for partial success

## Use cases

These libraries are appropriate when the application manages its own encryption and connection logic:

- **IoT sensor data collection**: a sensor creates an SMP queue and sends readings; a collector subscribes and receives them. The queue address (router + queue ID + keys) is provisioned once, out-of-band.
- **Device control**: a controller sends commands to an actuator's queue. Separate queues for commands and telemetry provide unidirectional isolation.
- **Bulk data delivery**: an application encrypts and chunks a file, sends data packets to XFTP routers, and shares the packet addresses with the recipient out-of-band.
- **Custom protocols**: any application that needs unidirectional, router-mediated packet delivery without the overhead of the Agent's connection management.

## What this layer does NOT provide

The following capabilities require the [Agent](AGENT.md) (Layer 3):

- **Duplex connections** — the Agent pairs two simplex queues into a duplex connection
- **End-to-end encryption** — the Agent manages double ratchet with post-quantum extensions
- **File transfer** — the Agent handles chunking, encryption, padding, multi-router distribution, and reassembly
- **Queue rotation** — the Agent transparently rotates queues to limit metadata correlation
- **Connection discovery** — connection links, short links, and contact addresses are Agent-level abstractions
- **Push notifications** — notification token management and subscription is Agent-level

## Protocol references

- [SimpleX Messaging Protocol](../protocol/simplex-messaging.md) — SMP wire format, commands, and security properties
- [XFTP Protocol](../protocol/xftp.md) — XFTP wire format, data packet lifecycle
- [SimpleX Network overview](../protocol/overview-tjr.md) — architecture, trust model, and design rationale
