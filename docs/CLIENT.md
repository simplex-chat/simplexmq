# SimpleX Client Libraries

SimpleX client libraries provide low-level protocol access to SimpleX routers. They implement the wire protocols ([SMP](../protocol/simplex-messaging.md), [XFTP](../protocol/xftp.md)) and handle connection lifecycle, but leave encryption, identity management, and connection orchestration to the application.

This is **Layer 2** of the [SimpleX Network architecture](../protocol/overview-tjr.md). Layer 1 is the routers themselves; Layer 3 is the [Agent](AGENT.md), which builds bidirectional encrypted connections on top of these libraries.

## SMP Client

**Source**: [`Simplex.Messaging.Client`](../src/Simplex/Messaging/Client.hs)

The SMP client connects to SMP routers and manages messaging queues — the fundamental addressing primitive of the SimpleX Network. Each queue is a unidirectional, ordered sequence of fixed-size packets (16,384 bytes) with separate cryptographic credentials for sending and receiving.

### Capabilities

- **Queue management**: create, secure, subscribe to, and delete queues on any SMP router
- **Message sending and receiving**: send messages to a queue's sender address; receive messages from a queue's recipient address
- **Command authentication**: each queue operation is authenticated with per-queue cryptographic keys (Ed25519, Ed448, or X25519)
- **Keep-alive**: automatic ping loop detects and recovers from half-open connections
- **Proxy forwarding**: send messages through a proxy router via 2-hop onion routing (PRXY/PFWD/RFWD commands), protecting the sender's IP address from the destination router
- **Batched commands**: multiple commands can be sent in a single transmission for efficiency

### API model

The client uses a functional Haskell API with STM queues for asynchronous event delivery:

- **Commands** are sent via `sendProtocolCommand` (single) or `sendBatch` (multiple). Each returns a result synchronously or via timeout.
- **Router events** (incoming messages, subscription notifications) arrive on `msgQ`, an STM `TBQueue` that the application reads from its own thread.
- **Connection lifecycle** is managed automatically: the client maintains send, receive, process, and monitor threads internally. When any thread fails, all are torn down and the `disconnected` callback fires.

### Router identity

Routers are identified by the SHA-256 hash of their CA certificate fingerprint, not by hostname. The client validates the full X.509 certificate chain on every TLS connection and compares the CA fingerprint against the expected hash from the queue address. This means a DNS or IP-level attacker who cannot produce the correct certificate is detected at connection time.

## XFTP Client

**Source**: [`Simplex.FileTransfer.Client`](../src/Simplex/FileTransfer/Client.hs)

The XFTP client connects to XFTP routers and manages data packets — individually addressed blocks used for larger payload delivery. Data packets come in fixed sizes (64KB, 256KB, 1MB, 4MB), hiding the actual payload size.

### Capabilities

- **Data packet creation**: create data packets on routers with sender, recipient, and optional additional recipient credentials
- **Upload**: send encrypted data in a single HTTP/2 streaming request (command + body)
- **Download**: retrieve data packets with per-download ephemeral Diffie-Hellman key exchange, providing forward secrecy — compromising one download key does not reveal other downloads
- **Acknowledgment and deletion**: recipients acknowledge receipt; senders delete data packets after delivery

### Size selection

`prepareChunkSizes` selects data packet sizes using a threshold algorithm: if the remaining payload exceeds 75% of the next larger size, it uses the larger size. This balances storage efficiency against the number of round trips. Single-chunk payloads (e.g., redirect descriptors) can use `singleChunkSize` to verify they fit in one data packet.

## Use cases

These libraries are appropriate when the application manages its own encryption and connection logic:

- **IoT sensor data collection**: a sensor creates an SMP queue and sends readings; a collector subscribes and receives them. The queue address (router + queue ID + keys) is provisioned once, out-of-band.
- **Device control**: a controller sends commands to an actuator's queue. Separate queues for commands and telemetry provide unidirectional isolation.
- **Bulk data delivery**: an application encrypts and chunks a file, uploads data packets to XFTP routers, and shares the packet addresses with the recipient out-of-band.
- **Custom protocols**: any application that needs unidirectional, router-mediated packet delivery without the overhead of the Agent's connection management.

## What this layer does NOT provide

The following capabilities require the [Agent](AGENT.md) (Layer 3):

- **Bidirectional connections** — the Agent pairs two unidirectional queues into a duplex connection
- **End-to-end encryption** — the Agent manages double ratchet with post-quantum extensions
- **File transfer** — the Agent handles chunking, encryption, padding, multi-router upload, and reassembly
- **Queue rotation** — the Agent transparently rotates queues to limit metadata correlation
- **Connection discovery** — connection links, short links, and contact addresses are Agent-level abstractions
- **Push notifications** — notification token management and subscription is Agent-level

## Protocol references

- [SimpleX Messaging Protocol](../protocol/simplex-messaging.md) — SMP wire format, commands, and security properties
- [XFTP Protocol](../protocol/xftp.md) — XFTP wire format, data packet lifecycle
- [SimpleX Network overview](../protocol/overview-tjr.md) — architecture, trust model, and design rationale
