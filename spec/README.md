# Spec Layer

> How does the code work? What does each function do? What are the security invariants?

## Structure

Spec has two levels:

### `spec/modules/` — Per-module documentation

Mirrors the `src/Simplex/` directory structure exactly. Each `.hs` file has a corresponding `.md` file at the same relative path. Contains only information that is **not obvious from reading the code** and cannot fit in a one-line source comment:

- Non-obvious behavior (subtle invariants, ordering dependencies, concurrency assumptions)
- Usage considerations (when to use X vs Y, common mistakes, caller obligations)
- Relationships to other modules not visible from imports
- Security notes specific to this module

**Not included**: type signatures, code snippets, function-by-function prose that restates the source. If reading the code tells you everything, the module doc says so briefly.

Function references use fully qualified names with markdown links:
```
[Simplex.Messaging.Server.subscribeServiceMessages](./modules/Simplex/Messaging/Server.md#subscribeServiceMessages)
```

Source code links back via comments:
```haskell
-- spec: spec/modules/Simplex/Messaging/Server.md#subscribeServiceMessages
subscribeServiceMessages :: ...
```

### `spec/` root — Topic documentation

Cross-module documentation that follows a feature, mechanism, or concern across the entire stack. Topics answer "how does X work end-to-end?" rather than "what does this file do?"

Topics reference module docs rather than restating implementation details. They focus on:
- End-to-end data flow across modules
- Cross-cutting security analysis and invariants
- Design rationale, risks, test gaps
- Version gates and compatibility concerns

Some topics may migrate to `product/` if they are primarily about user-visible behavior and guarantees rather than implementation mechanics.

### `spec/security-invariants.md` — All security invariants

Cross-referenced from both module docs and topic docs.

## Conventions

Module doc entry format:
```
## functionName
**Purpose**: ...
**Calls**: [Module.a](./modules/path.md#a), [Module.b](./modules/path.md#b)
**Called by**: [Module.c](./modules/path.md#c)
**Invariant**: SI-XX
**Security**: ...
```

## Index

### Architecture

Component topology and message flow diagrams for each layer:

- [routers.md](routers.md) — Layer 1: SMP, XFTP, NTF routers
- [clients.md](clients.md) — Layer 2: protocol client libraries
- [agent.md](agent.md) — Layer 3: connection manager

### Topics

Cross-cutting concerns that span multiple modules:

- [topics/transport.md](topics/transport.md) — TLS, HTTP/2, WebSocket transport layers
- [topics/patterns.md](topics/patterns.md) — Exception handling, encoding, compression, TMap
- [topics/subscriptions.md](topics/subscriptions.md) — Queue subscriptions and delivery
- [topics/notifications.md](topics/notifications.md) — Push notification flow
- [topics/xftp.md](topics/xftp.md) — File transfer protocol
- [topics/client-services.md](topics/client-services.md) — Service certificates for bulk operations

### Agent internals

- [agent/infrastructure.md](agent/infrastructure.md) — Workers, store, operation suspension
- [agent/connections.md](agent/connections.md) — Connection lifecycle and states
- [agent/xrcp.md](agent/xrcp.md) — Remote control protocol

### Modules

See `spec/modules/` — mirrors `src/Simplex/` structure.

### Security

- [security-invariants.md](security-invariants.md) — All security invariants
