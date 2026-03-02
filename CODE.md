# simplexmq — LLM Navigation Guide

This file is the entry point for LLMs working on simplexmq. Read it before making any code changes.

## Three-Layer Architecture

simplexmq maintains three documentation layers alongside source code:

| Layer | Directory | Answers | Audience |
|-------|-----------|---------|----------|
| **Product** | `product/` | What does this do? Who uses it? What must never break? | Anyone reasoning about behavior, privacy, security |
| **Spec** | `spec/` | How does the code work? What does each function do? What are the security invariants? | LLMs and developers modifying code |
| **Protocol** | `protocol/` | What is the wire protocol? What are the message formats and state machines? | Protocol implementors, formal verification |

Additionally:
- `rfcs/` — Protocol evolution: each RFC describes a delta to a protocol spec
- `product/threat-model.md` — Comprehensive threat model across all protocols
- `spec/security-invariants.md` — Every security invariant with enforcement and test coverage

## Navigation Workflow

When modifying code, follow this sequence:

1. **Identify scope** — Find the relevant component in `product/concepts.md`
2. **Load product context** — Read the component file in `product/components/` to understand what users depend on
3. **Load spec context** — Read the relevant `spec/` file(s) for implementation details and call graphs
4. **Check security** — Read `spec/security-invariants.md` for any invariants enforced by the code you're changing
5. **Load source** — Read the actual source files referenced in spec/
6. **Identify impact** — Trace the call graph to understand what your change affects
7. **Implement** — Make the change
8. **Update all layers** — Update spec/, product/, and protocol/ (if wire protocol changed) to stay coherent

## Protocol Specifications

Consolidated protocol specs live in `protocol/`. These describe the wire protocols as originally specified. Code has advanced beyond these versions — Phase 2 of this project will synchronize them.

| File | Protocol | Spec version | Code version |
|------|----------|-------------|--------------|
| `simplex-messaging.md` | SMP (simplex messaging) | v9 | SMP relay v18, SMP client v4 |
| `agent-protocol.md` | Agent (duplex connections) | v5 | Agent v7 |
| `xftp.md` | XFTP (file transfer) | v2 | XFTP v3 |
| `xrcp.md` | XRCP (remote control) | v1 | RCP v1 |
| `push-notifications.md` | Push notifications | v2 | NTF v3 |
| `pqdr.md` | PQDR (post-quantum double ratchet) | v1 | E2E v3 |
| `overview-tjr.md` | Cross-protocol overview | — | — |

Note: SMP has multiple version axes — `VersionSMP` (relay/transport, currently 18), `VersionSMPC` (client protocol, currently 4), and `VersionSMPA` (agent, currently 7). These are negotiated independently.

Protocol specs are amended in place when implementation changes. RFCs in `rfcs/` track the evolution history.

## Source Structure

```
src/Simplex/
  Messaging/
    Protocol.hs, Protocol/Types.hs      — SMP wire protocol types + encoding
    Client.hs                            — SMP client (protocol operations, proxy relay)
    Client/Agent.hs                      — Low-level async SMP agent
    Server.hs                            — SMP server request handling
    Server/Env/STM.hs                    — Server environment + STM state
    Server/Main.hs, Server/Main/Init.hs  — Server CLI + initialization
    Server/QueueStore/                   — Queue storage (STM, Postgres)
    Server/MsgStore/                     — Message storage (STM, Journal, Postgres)
    Server/MsgStore/Journal.hs           — Journal message store (1000 lines)
    Server/StoreLog/                     — Store log (append-only write, read-compact-rewrite restore)
    Server/NtfStore.hs                   — Message notification store
    Server/Control.hs, Server/CLI.hs     — Control protocol + CLI utilities
    Server/Stats.hs, Server/Prometheus.hs — Metrics
    Server/Information.hs                — Server public information / metadata
    Agent.hs                             — SMP agent: duplex connections, queue rotation
    Agent/Client.hs                      — Agent's SMP/XFTP/NTF client management
    Agent/Protocol.hs                    — Agent wire protocol types + encoding (2200 lines)
    Agent/Store.hs                       — Agent storage types (queues, connections, messages)
    Agent/Store/AgentStore.hs              — Agent storage implementation (3500 lines)
    Agent/Store/                          — Agent storage backends (SQLite, Postgres)
    Agent/Env/SQLite.hs                  — Agent environment + configuration
    Agent/NtfSubSupervisor.hs            — Notification subscription management
    Agent/TSessionSubs.hs                — Transport session subscriptions
    Agent/Stats.hs                       — Agent statistics
    Agent/RetryInterval.hs               — Retry interval logic
    Agent/Lock.hs                        — Named locks
    Agent/QueryString.hs                 — Query string parsing
    Transport.hs                         — TLS transport abstraction + handshake
    Transport/Client.hs, Transport/Server.hs — TLS client + server
    Transport/HTTP2.hs                   — HTTP/2 transport setup
    Transport/HTTP2/Client.hs            — HTTP/2 client
    Transport/HTTP2/Server.hs            — HTTP/2 server
    Transport/HTTP2/File.hs              — HTTP/2 file streaming
    Transport/WebSockets.hs              — WebSocket adapter
    Transport/Buffer.hs                  — Transport buffering
    Transport/KeepAlive.hs               — TCP keepalive
    Transport/Shared.hs                  — Certificate chain validation
    Transport/Credentials.hs             — TLS credential generation
    Crypto.hs                            — All cryptographic primitives
    Crypto/File.hs                       — File encryption (NaCl secret box + lazy)
    Crypto/Lazy.hs                       — Lazy hashing + encryption
    Crypto/Ratchet.hs                    — Double ratchet + PQDR
    Crypto/ShortLink.hs                  — Short link key derivation
    Crypto/SNTRUP761.hs                  — Post-quantum KEM hybrid secret
    Crypto/SNTRUP761/Bindings.hs         — sntrup761 C FFI bindings
    Notifications/Protocol.hs            — NTF wire protocol types + encoding
    Notifications/Types.hs               — NTF agent types (tokens, subscriptions)
    Notifications/Transport.hs           — NTF transport handshake
    Notifications/Client.hs              — NTF client operations
    Notifications/Server.hs              — NTF server
    Notifications/Server/Env.hs          — NTF server environment + config
    Notifications/Server/Store.hs        — NTF server storage (STM)
    Notifications/Server/Store/Postgres.hs — NTF server storage (Postgres)
    Notifications/Server/Push/APNS.hs    — Apple push notification integration
    Notifications/Server/Push/APNS/Internal.hs — APNS HTTP/2 client
    Notifications/Server/Main.hs         — NTF server CLI
    Notifications/Server/Stats.hs        — NTF server metrics
    Notifications/Server/Prometheus.hs   — NTF Prometheus metrics
    Notifications/Server/Control.hs      — NTF server control
    Encoding.hs, Encoding/String.hs      — Binary + string encoding
    Version.hs, Version/Internal.hs      — Version ranges + negotiation
    Util.hs                              — Utilities (error handling, STM, grouping)
    Parsers.hs                           — Attoparsec parser combinators
    TMap.hs                              — Transactional map (STM)
    Compression.hs                       — Zstd compression
    ServiceScheme.hs                     — Service scheme + server location types
    Session.hs                           — Session variables (TVar-based)
    SystemTime.hs                        — Rounded system time types
  FileTransfer/
    Protocol.hs                          — XFTP wire protocol types + encoding
    Client.hs                            — XFTP client operations
    Client/Agent.hs                      — XFTP client agent (connection pooling)
    Client/Main.hs                       — XFTP CLI client implementation
    Client/Presets.hs                    — Default XFTP servers
    Server.hs                            — XFTP server request handling
    Server/Env.hs                        — XFTP server environment + config
    Server/Store.hs                      — XFTP server storage
    Server/StoreLog.hs                   — XFTP server store log
    Server/Main.hs                       — XFTP server CLI
    Server/Stats.hs                      — XFTP server metrics
    Server/Prometheus.hs                 — XFTP Prometheus metrics
    Server/Control.hs                    — XFTP server control
    Agent.hs                             — XFTP agent operations
    Description.hs                       — File description format
    Transport.hs                         — XFTP transport
    Crypto.hs                            — File encryption for transfer
    Types.hs                             — File transfer types
    Chunks.hs                            — Chunk sizing
  RemoteControl/
    Client.hs                            — XRCP client (ctrl device)
    Invitation.hs                        — XRCP invitation handling
    Discovery.hs                         — Local network discovery
    Discovery/Multicast.hsc              — Multicast discovery (C FFI)
    Types.hs                             — XRCP types + version

apps/
  smp-server/Main.hs                    — SMP server executable
  smp-server/web/Static.hs              — SMP server web static files
  xftp-server/Main.hs                   — XFTP server executable
  xftp/Main.hs                          — XFTP CLI executable
  ntf-server/Main.hs                    — Notification server executable
  smp-agent/Main.hs                     — SMP agent (experimental, not in cabal)
```

## Linking Conventions

### spec → src
Fully qualified exported function names inline in prose: `Simplex.Messaging.Client.connectSMPProxiedRelay`. Use Grep/Glob to locate in source. For app targets: `xftp/Main.main`.

### src → spec
Comment above function:
```haskell
-- spec/crypto-tls.md#certificate-chain-validation
-- Validates relay certificate chain to prevent proxy MITM (SI-XX)
connectSMPProxiedRelay :: ...
```

### spec ↔ spec
Named markdown heading anchors: `spec/crypto.md#ed25519-signing`

### spec ↔ product
Cross-references: `product/rules.md#pr-05`, `spec/security-invariants.md#si-01`

### protocol/ references
`protocol/simplex-messaging.md` with section name

## Build Flags

simplexmq builds with several flag combinations:

| Flag | Effect |
|------|--------|
| (none) | Default: SQLite storage, all executables |
| `-fserver_postgres` | Postgres backend for SMP server |
| `-fclient_postgres` | Postgres backend for agent storage |
| `-fclient_library` | Library-only build (no server executables) |
| `-fswift` | Swift JSON format for mobile bindings |
| `-fuse_crypton` | Use crypton in cryptostore |

All flag combinations must compile with `--enable-tests`. Verify with:
```
cabal build all --ghc-options="-O0" [-flags] [--enable-tests]
```

## Change Protocol

Every code change must maintain coherence across all three layers:

1. **Code change** — Implement in src/
2. **Spec update** — Update the relevant spec/ file(s): types, call graphs, security notes
3. **Product update** — If user-visible behavior changed, update product/ files
4. **Protocol update** — If wire protocol changed, amend protocol/ spec (requires user approval)
5. **Security check** — If the change touches a trust boundary, update spec/security-invariants.md

Protocol spec amendments require explicit user approval before committing.
