# Router Architecture

SimpleX routers are the Layer 1 network infrastructure. This document shows their internal architecture: component topology and command processing flows.

For deployment and configuration, see [docs/ROUTERS.md](../docs/ROUTERS.md). For protocol specifications, see [SMP](../protocol/simplex-messaging.md), [XFTP](../protocol/xftp.md), [Push Notifications](../protocol/push-notifications.md).

---

## SMP Router

**Module specs**: [Server](modules/Simplex/Messaging/Server.md) · [Main](modules/Simplex/Messaging/Server/Main.md) · [QueueStore](modules/Simplex/Messaging/Server/QueueStore.md) · [QueueStore Postgres](modules/Simplex/Messaging/Server/QueueStore/Postgres.md) · [MsgStore](modules/Simplex/Messaging/Server/MsgStore.md) · [StoreLog](modules/Simplex/Messaging/Server/StoreLog.md) · [Control](modules/Simplex/Messaging/Server/Control.md) · [Prometheus](modules/Simplex/Messaging/Server/Prometheus.md) · [Stats](modules/Simplex/Messaging/Server/Stats.md)

### Component topology

![SMP Router - Component Topology](diagrams/smp-router.svg)

### Packet delivery flow

```mermaid
sequenceDiagram
    participant S as Sender

    box SMP Router
        participant auth as Command<br>Authorization
        participant QS as QueueStore
        participant MS as MsgStore
        participant del as Packet<br>Delivery
    end

    participant R as Recipient

    S->>auth: SEND (queue ID + packet)
    auth->>QS: verify sender key (constant-time)
    auth->>MS: store packet
    auth->>S: OK (via sndQ)

    auth->>del: tryDeliverMessage

    alt recipient has active SUB
        del->>R: MSG (via recipient's sndQ)
        R->>auth: ACK
        auth->>MS: delete packet
    else no active subscriber
        Note over MS: packet waits in MsgStore
        R->>auth: SUB (subscribe to queue)
        auth->>MS: fetch pending packets
        del->>R: MSG
    end
```

### Proxy forwarding flow

```mermaid
sequenceDiagram
    participant C as Client
    participant P as Proxy Router
    participant D as Destination Router

    C->>P: PRXY (destination address)
    P->>D: connect (if not already connected)
    P->>C: PKEY (proxy session key)

    C->>P: PFWD (encrypted command for destination)
    P->>D: RFWD (relay forwarded command)
    D->>P: command result
    P->>C: command result
```

---

## XFTP Router

**Module specs**: [Server](modules/Simplex/FileTransfer/Server.md) · [Main](modules/Simplex/FileTransfer/Server/Main.md) · [Store](modules/Simplex/FileTransfer/Server/Store.md) · [StoreLog](modules/Simplex/FileTransfer/Server/StoreLog.md) · [Stats](modules/Simplex/FileTransfer/Server/Stats.md) · [Transport](modules/Simplex/FileTransfer/Transport.md)

### Component topology

![XFTP Router - Component Topology](diagrams/xftp-router.svg)

### Data packet delivery flow

```mermaid
sequenceDiagram
    participant S as Sender

    box XFTP Router
        participant HS as Handshake
        participant CP as Command<br>Processing
        participant FS as FileStore
        participant D as Disk
    end

    participant R as Recipient

    S->>HS: HELLO
    HS->>S: server DH key + version

    S->>CP: FNEW (create data packet)
    CP->>FS: create FileRec
    CP->>S: sender ID + recipient IDs

    S->>CP: FPUT (send encrypted data)
    CP->>FS: reserve quota
    CP->>D: write to disk
    CP->>FS: commit filePath
    CP->>S: OK

    R->>HS: HELLO
    HS->>R: server DH key + version

    R->>CP: FGET (recipient DH key)
    CP->>CP: DH key agreement
    CP->>D: read file
    CP->>R: encrypted data stream

    R->>CP: FACK
    CP->>FS: delete recipient entry
```

---

## NTF Router

**Module specs**: [Server](modules/Simplex/Messaging/Notifications/Server.md) · [Main](modules/Simplex/Messaging/Notifications/Server/Main.md) · [Store Postgres](modules/Simplex/Messaging/Notifications/Server/Store/Postgres.md) · [APNS](modules/Simplex/Messaging/Notifications/Server/Push/APNS.md) · [Control](modules/Simplex/Messaging/Notifications/Server/Control.md) · [Client](modules/Simplex/Messaging/Notifications/Client.md) · [Protocol](modules/Simplex/Messaging/Notifications/Protocol.md)

### Component topology

![NTF Router - Component Topology](diagrams/ntf-router.svg)

### Token registration and notification delivery

```mermaid
sequenceDiagram
    participant App

    box NTF Router
        participant cl as client thread
        participant Store
        participant sub as ntfSubscriber
        participant push as ntfPush
    end

    participant SMP as SMP Router
    participant APNS

    App->>cl: TNEW (push token + DH key)
    cl->>Store: create token (NTRegistered)
    cl->>push: PNVerification (via pushQ)
    push->>APNS: verification push
    APNS-->>App: verification code (encrypted)
    App->>cl: TVFY (code)
    cl->>Store: token -> NTActive

    App->>cl: SNEW (subscribe to SMP queue)
    cl->>Store: create subscription
    cl->>SMP: NKEY (subscribe for notifications)
    SMP->>cl: OK (notifier ID)

    Note over SMP: message arrives on queue
    SMP->>sub: NMSG (via msgQ)
    sub->>Store: update tokenLastNtfs
    sub->>push: PNMessage (via pushQ)
    push->>APNS: push notification
    APNS-->>App: notification (ID only)
    App->>SMP: connect and retrieve message
```
