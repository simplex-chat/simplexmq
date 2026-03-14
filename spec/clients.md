# Client Architecture

SimpleX clients are the Layer 2 libraries that connect to routers. This document shows their internal architecture: component topology and command processing flows.

For deployment and usage, see [docs/CLIENT.md](../docs/CLIENT.md). For protocol specifications, see [SMP](../protocol/simplex-messaging.md), [XFTP](../protocol/xftp.md), [Push Notifications](../protocol/push-notifications.md).

---

## SMP Client (ProtocolClient)

**Module specs**: [Client](modules/Simplex/Messaging/Client.md) · [Protocol](modules/Simplex/Messaging/Protocol.md) · [Transport](modules/Simplex/Messaging/Transport.md) · [Crypto](modules/Simplex/Messaging/Crypto.md)

Generic protocol client used for both SMP and NTF connections. Manages a single TLS connection with multiplexed command/response matching via correlation IDs.

### Component topology

![SMP Client - Component Topology](diagrams/smp-client.svg)

### Command/result flow

```mermaid
sequenceDiagram
    participant C as Caller<br>(Agent / router)

    box ProtocolClient
        participant SC as sentCommands<br>(TMap CorrId Request)
        participant SQ as sndQ
        participant S as send thread
        participant R as receive thread
        participant RQ as rcvQ
        participant P as process thread
    end

    participant Router as SMP Router

    C->>SC: mkTransmission<br/>(generate CorrId, create Request<br/>with empty responseVar)
    C->>SQ: write (Request, encoded command)
    S->>SQ: read
    S-->>S: check pending flag (drop if timed out)
    S->>Router: tPutLog (transmit bytes)

    Router->>R: tGetClient (receive batch)
    R->>RQ: write transmissions

    P->>RQ: read
    P->>SC: lookup CorrId
    alt command response (CorrId matches, pending)
        P->>SC: remove CorrId + fill responseVar (TMVar)
    else expired response (CorrId matches, already timed out)
        P->>C: write to msgQ (STResponse)
    else server event (empty CorrId)
        P->>C: write to msgQ (STEvent)
    end

    Note over C: getResponse: takeTMVar with timeout
```

---

## SMPClientAgent

**Module specs**: [Client Agent](modules/Simplex/Messaging/Client/Agent.md)

Connection manager that multiplexes multiple ProtocolClient connections. Tracks subscriptions, handles reconnection with backoff, and forwards server messages and connection events upward. Used by SMP router (proxying) and NTF router (subscriptions).

### Component topology

![SMPClientAgent - Component Topology](diagrams/smp-client-agent.svg)

### Connection lifecycle

```mermaid
sequenceDiagram
    participant C as Consumer<br>(router / app)

    box
        participant A as SMPClientAgent
        participant PC as ProtocolClient
    end

    participant Router as SMP Router

    C->>A: getSMPServerClient'' (server)
    alt client exists in smpClients
        A->>C: return existing client
    else no client
        A->>PC: connectClient (create new ProtocolClient)
        PC->>Router: TLS handshake
        A->>A: register disconnect handler
        A->>C: return new client
    end

    C->>A: subscribeQueuesNtfs (queueIds)
    A->>A: add to pendingQueueSubs
    A->>PC: sendProtocolCommands (SUB batch)
    PC->>Router: SUB commands
    Router->>PC: OK responses
    A->>A: move pending → activeQueueSubs
    A->>C: CASubscribed (via agentQ)

    Note over Router: connection drops

    PC->>A: disconnect handler fires
    A->>A: filter by SessionId (only remove subs matching disconnected session)
    A->>A: move active → pending (queue subs + service subs)
    A->>C: CAServiceDisconnected (via agentQ, if service sub existed)
    A->>C: CADisconnected (via agentQ, if queue subs existed)
    A->>A: spawn smpSubWorker (retry with backoff)
    A->>PC: reconnect + resubscribe pending subs
    A->>C: CAConnected + CASubscribed (via agentQ)
```

---

## XFTP Client

**Module specs**: [Client](modules/Simplex/FileTransfer/Client.md) · [Protocol](modules/Simplex/FileTransfer/Protocol.md) · [HTTP/2 Client](modules/Simplex/Messaging/Transport/HTTP2/Client.md)

Stateless wrapper around HTTP2Client. XFTPClient adds no threads of its own; each operation is a synchronous HTTP/2 request/response. Serialization and multiplexing happen inside HTTP2Client's internal request queue and process thread.

### Component topology

![XFTP Client - Component Topology](diagrams/xftp-client.svg)

### Packet delivery flow

```mermaid
sequenceDiagram
    participant C as Caller<br>(Agent / app)
    participant X as XFTPClient
    participant H as HTTP2Client
    participant Router as XFTP Router

    C->>X: createXFTPChunk (FNEW)
    X->>H: HTTP/2 POST (encoded command)
    H->>Router: request
    Router->>H: response (sender ID + recipient IDs)
    H->>X: decode response
    X->>C: return IDs

    C->>X: uploadXFTPChunk (FPUT + file data)
    X->>H: HTTP/2 POST (streaming body)
    H->>Router: request with file stream
    Router->>H: OK
    H->>X: OK
    X->>C: return OK

    C->>X: downloadXFTPChunk (FGET + ephemeral DH key)
    X->>H: HTTP/2 POST (command)
    H->>Router: request
    Router->>H: streaming response (server DH key + nonce + encrypted data)
    H->>X: streaming body
    X->>X: compute DH secret, decrypt + save to file
    X->>C: return ()
```

---

## NTF Client

**Module specs**: [Client](modules/Simplex/Messaging/Notifications/Client.md) · [Protocol](modules/Simplex/Messaging/Notifications/Protocol.md)

Type alias for ProtocolClient - same architecture as SMP Client:

```haskell
type NtfClient = ProtocolClient NTFVersion ErrorType NtfResponse
```

Same threads (send, receive, process, monitor), same queues (sndQ, rcvQ, sentCommands, msgQ), same command/response flow. Different command types: TNEW, TVFY, TCHK, TRPL, TDEL, TCRN, SNEW, SCHK, SDEL, PING.
