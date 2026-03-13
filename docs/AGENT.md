# SimpleX Agent

The SimpleX Agent builds bidirectional encrypted connections on top of [SimpleX client libraries](CLIENT.md). It manages the full lifecycle of secure communication: connection establishment, end-to-end encryption, queue rotation, file transfer, and push notifications.

This is **Layer 3** of the [SimpleX Network architecture](../protocol/overview-tjr.md). Layer 1 is the routers; Layer 2 is the [client libraries](CLIENT.md) that speak the wire protocols. The Agent adds the connection semantics that applications need.

**Source**: [`Simplex.Messaging.Agent`](../src/Simplex/Messaging/Agent.hs)

## Connections

The Agent turns unidirectional SMP queues into bidirectional connections:

- **Duplex connections**: each connection uses a pair of SMP queues — one for each direction. The queues can be on different routers chosen independently by each party.
- **Connection establishment**: one party creates a connection and generates an invitation (containing router address, queue ID, and public keys). The invitation is passed out-of-band (QR code, link, etc.). The other party joins by creating a reverse queue and completing the handshake.
- **Connection links**: the Agent supports connection links (long and short) for sharing connection invitations via URLs. Short links use a separate SMP queue to store the full invitation, allowing compact QR codes.
- **Queue rotation**: the Agent periodically rotates the underlying SMP queues, limiting the window for metadata correlation. Rotation is transparent to the application — the connection identity is stable while the underlying queues change.
- **Redundant queues**: connections can use multiple queues for reliability. If one router becomes unreachable, messages flow through the remaining queues.

## Encryption

The Agent provides end-to-end encryption with forward secrecy and break-in recovery:

- **Double ratchet**: messages are encrypted using a double ratchet protocol derived from the Signal protocol. Each message uses a unique key; compromising one key does not reveal past or future messages.
- **Post-quantum extensions**: the ratchet supports hybrid key exchange using SNTRUP761 (a lattice-based KEM) combined with X25519 DH. This provides protection against future quantum computers that could break classical DH.
- **Ratchet synchronization**: if the ratchet state becomes desynchronized (e.g., due to message loss or device restore), the Agent detects this and can negotiate resynchronization with the peer.
- **Per-queue encryption**: in addition to end-to-end encryption, each queue has a separate encryption layer between sender and router, preventing traffic correlation even if TLS is compromised.

## File Transfer

The Agent handles file transfer over [XFTP](../protocol/xftp.md) routers:

- **Chunking**: files are split into chunks, each stored as a data packet on an XFTP router. Chunk sizes are fixed powers of 2 (64KB to 4MB), hiding the actual file size.
- **Client-side encryption**: files are encrypted and padded before upload. The recipient decrypts after downloading all chunks. The encryption key and file metadata are sent through the SMP connection, not through XFTP.
- **Multi-router distribution**: chunks can be uploaded to different XFTP routers, and each chunk can have multiple replicas on different routers for redundancy.
- **Redirect chains**: for metadata privacy, file descriptors can be stored as XFTP data packets themselves, creating an indirection layer between the SMP message and the actual file location.

## Notifications

The Agent manages push notification subscriptions for mobile devices:

- **Token registration**: registers device push tokens with NTF (notification) routers, which bridge to platform push services (APNS).
- **Notification subscriptions**: creates NTF subscriptions for SMP queues so that incoming messages trigger push notifications without requiring persistent connections.
- **Privacy preservation**: push notifications contain only a notification ID, not message content. The device wakes, connects to the SMP router, and retrieves the actual message.

## Integration

The Agent is designed to be embedded as a Haskell library:

- **STM queues**: the application communicates with the Agent via STM queues. Commands go in (`ACommand`), events come out (`AEvent`). No serialization or parsing — direct Haskell values.
- **Async operation**: all network operations are asynchronous. The Agent manages internal worker threads for each router connection, message processing, and background tasks (cleanup, statistics, notification supervision).
- **Background mode**: on mobile platforms, the Agent can run in a reduced mode with only the message receiver active, minimizing resource usage when the app is backgrounded.
- **Dual database backends**: the Agent supports both SQLite (for mobile/desktop) and PostgreSQL (for server deployments) as persistence backends, selected at compile time.

## Use cases

- **Chat applications**: [SimpleX Chat](https://github.com/simplex-chat/simplex-chat) is the reference application, using the full Agent API for messaging, file sharing, groups, and calls.
- **Bots and automated services**: services that need bidirectional encrypted communication with SimpleX Chat users or other Agent-based applications.
- **Any application needing secure bidirectional communication** over the SimpleX Network without implementing the connection management, encryption, and queue rotation logic directly.

## What this layer adds over client libraries

| Capability | Client (Layer 2) | Agent (Layer 3) |
|---|---|---|
| Queue operations | Direct | Managed transparently |
| Connection model | Unidirectional queues | Bidirectional connections |
| Encryption | Application's responsibility | Double ratchet with PQ extensions |
| File transfer | Raw data packet upload/download | Chunking, encryption, reassembly |
| Identity | Per-queue keys | Per-connection, rotatable |
| Notifications | Not available | NTF router integration |

## Protocol references

- [Agent Protocol](../protocol/agent-protocol.md) — duplex connection procedure, message format
- [SimpleX Network overview](../protocol/overview-tjr.md) — architecture, trust model
- [PQDR](../protocol/pqdr.md) — post-quantum double ratchet specification
