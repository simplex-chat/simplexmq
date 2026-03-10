# Spec Layer

> How does the code work? What does each function do? What are the security invariants?

## Conventions

Each spec file documents:
1. **Purpose** — What this component does
2. **Protocol reference** — Link to `protocol/` file (where applicable)
3. **Types** — Key data types with field descriptions
4. **Functions** — Every exported function with call graph
5. **Security notes** — Trust assumptions, validation requirements

Function documentation format:
```
### Module.functionName
**Purpose**: ...
**Calls**: Module.a, Module.b
**Called by**: Module.c
**Invariant**: SI-XX
**Security**: ...
```

## Index

### Protocol Implementation
- [smp-protocol.md](smp-protocol.md) — SMP commands, types, encoding
- [xftp-protocol.md](xftp-protocol.md) — XFTP commands, chunk operations
- [ntf-protocol.md](ntf-protocol.md) — NTF commands, token/subscription lifecycle
- [xrcp-protocol.md](xrcp-protocol.md) — XRCP session handshake, commands
- [agent-protocol.md](agent-protocol.md) — Agent connection procedures, queue rotation

### Cryptography
- [crypto.md](crypto.md) — All primitives: Ed25519, X25519, NaCl, AES-GCM, SHA, HKDF
- [crypto-ratchet.md](crypto-ratchet.md) — Double ratchet + PQDR
- [crypto-tls.md](crypto-tls.md) — TLS setup, certificate chains, validation

### Transport
- [transport.md](transport.md) — Transport abstraction, handshake, block padding
- [transport-http2.md](transport-http2.md) — HTTP/2 framing, file streaming
- [transport-websocket.md](transport-websocket.md) — WebSocket adapter

### Server Implementations
- [smp-server.md](smp-server.md) — SMP server
- [xftp-server.md](xftp-server.md) — XFTP server
- [ntf-server.md](ntf-server.md) — Notification server

### Client Implementations
- [smp-client.md](smp-client.md) — SMP client, proxy relay
- [xftp-client.md](xftp-client.md) — XFTP client
- [agent.md](agent.md) — SMP agent, duplex connections

### Storage
- [storage-server.md](storage-server.md) — Server storage backends
- [storage-agent.md](storage-agent.md) — Agent storage backends

### Auxiliary
- [encoding.md](encoding.md) — Binary and string encoding
- [version.md](version.md) — Version ranges and negotiation
- [remote-control.md](remote-control.md) — XRCP implementation
- [compression.md](compression.md) — Zstd compression

### Cross-cutting Features
- [rcv-services.md](rcv-services.md) — Service certificates for high-volume SMP clients (bulk subscription)

### Security
- [security-invariants.md](security-invariants.md) — All security invariants
