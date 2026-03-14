# Agent Architecture

The SimpleX Agent is the Layer 3 connection manager. It builds duplex encrypted connections on top of Layer 2 client libraries. This document shows its internal architecture: component topology and message processing flows.

For usage and API overview, see [docs/AGENT.md](../docs/AGENT.md). For protocol specifications, see [Agent Protocol](../protocol/agent-protocol.md), [PQDR](../protocol/pqdr.md).

---

**Module specs**: [Agent](modules/Simplex/Messaging/Agent.md) · [Agent Client](modules/Simplex/Messaging/Agent/Client.md) · [Agent Protocol](modules/Simplex/Messaging/Agent/Protocol.md) · [Store Interface](modules/Simplex/Messaging/Agent/Store/Interface.md) · [NtfSubSupervisor](modules/Simplex/Messaging/Agent/NtfSubSupervisor.md) · [XFTP Agent](modules/Simplex/FileTransfer/Agent.md) · [Ratchet](modules/Simplex/Messaging/Crypto/Ratchet.md)

### Component topology

![Agent - Component Topology](diagrams/agent.svg)

### Message receive flow

```mermaid
sequenceDiagram
    participant R as SMP Router

    box Agent
        participant SC as smpClients<br>(ProtocolClient pool)
        participant MQ as msgQ<br>(TBQueue)
        participant S as subscriber
        participant St as Store
        participant SQ as subQ<br>(TBQueue)
    end

    participant App as Application

    R->>SC: MSG (encrypted packet)
    SC->>MQ: write batch

    S->>MQ: read batch
    S->>S: withConnLock<br>(serialize per connection)
    S->>St: load ratchet state<br>(lockConnForUpdate)
    S->>S: agentRatchetDecrypt<br>(double ratchet)
    S->>S: checkMsgIntegrity<br>(sequence + hash chain)
    S->>St: store received message,<br>update ratchet
    S->>SQ: write AEvt (MSG + metadata)

    App->>SQ: read event

    Note over App: application processes message

    App->>S: ackMessage (agentMsgId)
    Note over S,R: ACK is async<br>(enqueued as internal command)
    S->>SC: ACK
    SC->>R: ACK
```

### Message send flow

```mermaid
sequenceDiagram
    participant App as Application

    box Agent
        participant API as sendMessage
        participant St as Store
        participant DW as deliveryWorker<br>(per send queue)
        participant SC as smpClients<br>(ProtocolClient pool)
    end

    participant R as SMP Router

    App->>API: sendMessage(connId, body)
    API->>St: agentRatchetEncryptHeader<br>(advance ratchet, store<br>encrypt key + pending message)
    API->>DW: signal doWork (TMVar)
    API->>App: return msgId

    DW->>St: getPendingQueueMsg
    DW->>DW: rcEncryptMsg<br>(encrypt body with stored key)
    DW->>DW: encode AgentMsgEnvelope
    DW->>SC: sendAgentMessage<br>(per-queue encrypt + SEND)
    SC->>R: SEND (encrypted packet)
    R->>SC: OK

    DW->>St: delete pending message
    DW->>App: SENT msgId (via subQ)
```

### Connection establishment flow

```mermaid
sequenceDiagram
    participant A as Alice (initiator)

    box Agent A
        participant AA as Agent
    end

    participant SMP as SMP Router

    box Agent B
        participant AB as Agent
    end

    participant B as Bob (joiner)

    A->>AA: createConnection
    AA->>SMP: NEW (Alice's receive queue)
    SMP->>AA: queue ID + keys
    AA->>A: invitation URI<br>(queue address + DH keys)

    Note over A,B: invitation passed out-of-band<br>(QR code, link)

    B->>AB: joinConnection(invitation)
    AB->>AB: initSndRatchet<br>(PQ X3DH key agreement)
    AB->>SMP: NEW (Bob's receive queue)
    SMP->>AB: queue ID
    AB->>SMP: KEY (secure Alice's queue)
    AB->>SMP: SEND confirmation to<br>Alice's queue (Bob's queue<br>address + ratchet keys)

    SMP->>AA: MSG (confirmation)
    AA->>AA: initRcvRatchet<br>(PQ X3DH key agreement),<br>decrypt confirmation
    AA->>A: CONF (request approval)
    A->>AA: allowConnection(confId)
    AA->>SMP: SKEY (secure Alice's rcv queue)
    AA->>SMP: NEW (Alice's send queue)
    AA->>SMP: SEND reply to Bob's queue<br>(Alice's connection info)

    SMP->>AB: MSG (reply)
    AB->>SMP: SKEY (secure Bob's rcv queue)
    AB->>SMP: SEND HELLO to Alice

    SMP->>AA: MSG (HELLO)
    AA->>SMP: SEND HELLO to Bob
    AA->>A: CON (connected)

    SMP->>AB: MSG (HELLO)
    AB->>B: CON (connected)
```
