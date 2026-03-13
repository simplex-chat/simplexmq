# Agent Module Documentation Notes

> Working notes for documenting Agent/Client.hs and Agent.hs. Not a spec doc — will be deleted after both docs are written.

## Documentation approach

**Bottom-up**: Client.hs first, then Agent.hs.

**Client.hs** documents reusable infrastructure with contracts (what callers must provide, what guarantees they get), listing known consumers. Stands alone as "here's the framework."

**Agent.hs** references Client.hs for infrastructure, focuses on what it passes into those frameworks — specific worker bodies, task queries, handler logic, and the orchestration policies (handshake, rotation, ratchet sync). Stands alone as "here's how the agent uses that framework."

Coupling captured by cross-references, not duplication.

## Module roles

**Client.hs — infrastructure layer (~2868 lines):**
- `AgentClient`: central state container (TVars, TMaps, worker pools, locks, operation states)
- Protocol client lifecycle: lazy singleton for SMP/NTF/XFTP connections, disconnect callbacks, reconnection via sub workers
- Subscription state machine: active/pending/removed, session-aware cleanup on disconnect
- Worker framework: `getAgentWorker` (lifecycle, restart rate limiting, crash recovery) + `withWork`/`withWork_`/`withWorkItems` (task retrieval pattern with doWork flag atomics)
- Operation suspension cascade: RcvNetwork → MsgDelivery → SndNetwork → Database
- Queue creation (`newRcvQueue`) and protocol-level operations
- Concurrency primitives: per-connection locks, session vars with monotonic IDs, batching by transport session
- Encryption helpers, server selection, statistics

**Agent.hs — orchestration/policy layer (~3868 lines):**
- Public API: createConnection, joinConnection, allowConnection, sendMessage, ackMessage, switchConnection, etc.
- Subscriber loop: reads `msgQ`, dispatches to per-connection handlers via `processSMP`
- Duplex handshake: confirmation processing, HELLO exchange, CON notification
- Queue rotation protocol: QADD → QKEY → QUSE → QTEST
- Ratchet synchronization: AgentRatchetKey exchange, hash-ordering to break symmetry
- Async command processing: `runCommandProcessing` worker body using `withWork` + `getPendingServerCommand`
- Message delivery: `runSmpQueueMsgDelivery` worker body per SndQueue
- Message integrity: sequential ID + hash chain validation

## Worker framework details

Defined in Client.hs, consumed by Agent.hs, NtfSubSupervisor.hs, FileTransfer/Agent.hs, and simplex-chat.

Two separable parts:
1. **`getAgentWorker`**: lifecycle — create-or-reuse worker for a key, fork async, handle restart rate limiting (max per minute, delete after max). `getAgentWorker'` is generic version with custom worker wrapper (e.g., adding a retryLock TMVar for delivery workers).
2. **`withWork` / `withWork_` / `withWorkItems`**: task retrieval pattern — takes `getWork` (fetch next task) and `action` (process it) as separate parameters. Clears doWork flag BEFORE querying (prevents race where another thread sets flag after query returns empty). Re-sets flag if work was found. On work item error vs store error: work item errors stop the worker (CRITICAL), store errors re-set flag and log.

Worker body (in consumer module) loops: `waitForWork doWork` → `withWork doWork getTask handleTask`.

## Key non-obvious patterns to document

### Client.hs — DONE (see Agent/Client.md)

### Agent.hs
- Subscriber loop is the main event processor
- Duplex handshake role asymmetry: initiator expects AgentConnInfoReply, acceptor expects AgentConnInfo
- Queue rotation is 4 agent messages on top of SMP commands
- Ratchet sync hash-ordering: lower hash initializes receive ratchet
- Message integrity validation: external sender ID sequential + hash chain
- Split-phase connection creation (prepareConnectionLink + createConnectionForLink) prevents race
- ACK is NOT automatic for A_MSG (user must call ackMessage), IS automatic for control messages
- Connection upgrade: RcvConnection → DuplexConnection when reply queue created
