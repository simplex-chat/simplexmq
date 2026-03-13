# SimpleX Agent

The SimpleX Agent builds duplex encrypted connections on top of [SimpleX client libraries](CLIENT.md). It manages the full lifecycle of secure communication: connection establishment, end-to-end encryption, queue rotation, file transfer, and push notifications.

This is **Layer 3** of the [SimpleX Network architecture](../protocol/overview-tjr.md). Layer 1 is the routers; Layer 2 is the [client libraries](CLIENT.md) that speak the wire protocols. The Agent adds the connection semantics that applications need.

**Source**: [`Simplex.Messaging.Agent`](../src/Simplex/Messaging/Agent.hs) — **Module spec**: [`spec/modules/Simplex/Messaging/Agent.md`](../spec/modules/Simplex/Messaging/Agent.md)

## Connections

The Agent turns simplex (unidirectional) SMP queues into duplex connections, implementing the [Agent protocol](../protocol/agent-protocol.md):

- **Duplex connections**: each connection uses a pair of SMP queues — one for each direction. The queues can be on different routers chosen independently by each party. See the [duplex connection procedure](../protocol/agent-protocol.md) for the full handshake.
- **Connection establishment**: one party creates a connection and generates an invitation (containing router address, queue ID, and public keys). The invitation is passed out-of-band (QR code, link, etc.). The other party joins by creating a reverse queue and completing the handshake.
- **Connection links**: the Agent supports connection links (long and short) for sharing connection invitations via URLs. Short links use a separate SMP queue to store the full invitation, allowing compact QR codes.
- **Queue rotation**: the Agent periodically rotates the underlying SMP queues, limiting the window for metadata correlation. Rotation is transparent to the application — the connection identity is stable while the underlying queues change.
- **Redundant queues**: connections can use multiple queues for reliability. If one router becomes unreachable, messages flow through the remaining queues.

## Encryption

The Agent provides end-to-end encryption with forward secrecy and break-in recovery, specified in the [Post-Quantum Double Ratchet protocol](../protocol/pqdr.md):

- **Double ratchet**: messages are encrypted using a double ratchet protocol. Each message uses a unique key; compromising one key does not reveal past or future messages. See the [PQDR specification](../protocol/pqdr.md) for the full ratchet state machine.
- **Post-quantum extensions**: the ratchet supports hybrid key exchange using SNTRUP761 (a lattice-based KEM) combined with X25519 DH. This provides protection against future quantum computers that could break classical DH. See the [SNTRUP761 module spec](../spec/modules/Simplex/Messaging/Crypto/SNTRUP761.md) and [Ratchet module spec](../spec/modules/Simplex/Messaging/Crypto/Ratchet.md) for implementation details.
- **Ratchet synchronization**: if the ratchet state becomes desynchronized (e.g., due to message loss or device restore), the Agent detects this and can negotiate resynchronization with the peer.
- **Per-queue encryption**: in addition to end-to-end encryption, the [SMP protocol](../protocol/simplex-messaging.md) provides a separate encryption layer on each queue between sender and router, preventing traffic correlation even if TLS is compromised.

## File Transfer

The Agent handles file transfer over [XFTP](../protocol/xftp.md) routers. File transfer orchestration is implemented in the [XFTP Agent module](../spec/modules/Simplex/FileTransfer/Agent.md):

- **Chunking**: files are split into chunks, each sent as a data packet to an XFTP router. Chunk sizes are fixed powers of 2 (64KB to 4MB), hiding the actual file size. See the [file description module spec](../spec/modules/Simplex/FileTransfer/Description.md) for chunk size selection and file descriptor format.
- **Client-side encryption**: files are encrypted and padded before being sent to XFTP routers. The recipient decrypts after receiving all chunks. The encryption key and file metadata are sent through the SMP connection, not through XFTP. See [file crypto module spec](../spec/modules/Simplex/FileTransfer/Crypto.md).
- **Multi-router distribution**: chunks can be sent to different XFTP routers, and each chunk can have multiple replicas on different routers for redundancy.
- **Redirect chains**: for metadata privacy, file descriptors can be sent as XFTP data packets themselves, creating an indirection layer between the SMP message and the actual file location.

## Notifications

The Agent manages push notification subscriptions for mobile devices, using the [Push Notifications protocol](../protocol/push-notifications.md). Notification supervision is handled by the [NtfSubSupervisor](../spec/modules/Simplex/Messaging/Agent/NtfSubSupervisor.md):

- **Token registration**: registers device push tokens with NTF (notification) routers, which bridge to platform push services (APNS). See the [NTF client module spec](../spec/modules/Simplex/Messaging/Notifications/Client.md).
- **Notification subscriptions**: creates NTF subscriptions for SMP queues so that incoming messages trigger push notifications without requiring persistent connections.
- **Privacy preservation**: push notifications contain only a notification ID, not message content. The device wakes, connects to the SMP router, and retrieves the actual message. See the [Push Notifications protocol](../protocol/push-notifications.md) for the full flow.

## Integration

The Agent is designed to be embedded as a Haskell library:

- **STM queues**: the application communicates with the Agent via STM queues. Commands go in (`ACommand`), events come out (`AEvent`). No serialization or parsing — direct Haskell values. The command/event types are defined in the [Agent Protocol module](../spec/modules/Simplex/Messaging/Agent/Protocol.md).
- **Async operation**: all network operations are asynchronous. The Agent manages internal worker threads for each router connection, message processing, and background tasks (cleanup, statistics, notification supervision). See the [Agent Client module spec](../spec/modules/Simplex/Messaging/Agent/Client.md) for worker architecture.
- **Background mode**: on mobile platforms, the Agent can run in a reduced mode with only the message receiver active, minimizing resource usage when the app is backgrounded.
- **Dual database backends**: the Agent supports both SQLite (for mobile/desktop) and PostgreSQL (for server deployments) as persistence backends, selected at compile time. See [Agent Store Interface](../spec/modules/Simplex/Messaging/Agent/Store/Interface.md) and [Agent Store Postgres](../spec/modules/Simplex/Messaging/Agent/Store/Postgres.md).

## Use cases

- **Chat applications**: [SimpleX Chat](https://github.com/simplex-chat/simplex-chat) is the reference application, using the full Agent API for messaging, file sharing, groups, and calls.
- **Bots and automated services**: services that need duplex encrypted communication with SimpleX Chat users or other Agent-based applications.
- **Any application needing secure duplex communication** over the SimpleX Network without implementing the connection management, encryption, and queue rotation logic directly.

## What this layer adds over client libraries

| Capability | Client (Layer 2) | Agent (Layer 3) |
|---|---|---|
| Queue operations | Direct | Managed transparently |
| Connection model | Simplex (unidirectional) queues | Duplex connections |
| Encryption | Application's responsibility | Double ratchet with PQ extensions |
| File transfer | Raw data packet send/receive | Chunking, encryption, reassembly |
| Identity | Per-queue keys | Per-connection, rotatable |
| Notifications | Direct NTF protocol operations | Automated subscription supervision |

## Protocol references

- [Agent Protocol](../protocol/agent-protocol.md) — duplex connection procedure, message format
- [SimpleX Network overview](../protocol/overview-tjr.md) — architecture, trust model
- [PQDR](../protocol/pqdr.md) — post-quantum double ratchet specification
- [SimpleX Messaging Protocol](../protocol/simplex-messaging.md) — SMP queue operations used by the Agent
- [XFTP Protocol](../protocol/xftp.md) — data packet operations for file transfer
- [Push Notifications Protocol](../protocol/push-notifications.md) — NTF token and subscription management
## Peer library: Remote Control

The Agent exposes the [XRCP protocol](../protocol/xrcp.md) API for cross-device remote control (e.g., controlling a mobile app from a desktop). The actual logic is in the standalone [`Simplex.RemoteControl.Client`](../src/Simplex/RemoteControl/Client.hs) library — the Agent provides thin wrappers that pass through its random and multicast state. XRCP is not a managed Agent capability (no workers, persistence, or background supervision). See the [RemoteControl module specs](../spec/modules/Simplex/RemoteControl/Types.md).

## Module specs

- [Agent](../spec/modules/Simplex/Messaging/Agent.md) — main Agent module, connection lifecycle, message processing
- [Agent Client](../spec/modules/Simplex/Messaging/Agent/Client.md) — worker threads, router connections, subscription management
- [Agent Protocol](../spec/modules/Simplex/Messaging/Agent/Protocol.md) — ACommand/AEvent types, connection invitations
- [Agent Store Interface](../spec/modules/Simplex/Messaging/Agent/Store/Interface.md) — database abstraction for SQLite/Postgres
- [Agent Store (AgentStore)](../spec/modules/Simplex/Messaging/Agent/Store/AgentStore.md) — connection, queue, and message persistence
- [NtfSubSupervisor](../spec/modules/Simplex/Messaging/Agent/NtfSubSupervisor.md) — notification subscription management
- [XFTP Agent](../spec/modules/Simplex/FileTransfer/Agent.md) — file transfer orchestration
- [Ratchet](../spec/modules/Simplex/Messaging/Crypto/Ratchet.md) — double ratchet implementation
- [SNTRUP761](../spec/modules/Simplex/Messaging/Crypto/SNTRUP761.md) — post-quantum KEM
