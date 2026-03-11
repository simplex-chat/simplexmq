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

### Topics

- [rcv-services.md](rcv-services.md) — Service certificates for high-volume SMP clients (bulk subscription)
- [encoding.md](encoding.md) — Binary and string encoding
- [version.md](version.md) — Version ranges and negotiation
- [compression.md](compression.md) — Zstd compression

### Modules

See `spec/modules/` — mirrors `src/Simplex/` structure.

### Security

- [security-invariants.md](security-invariants.md) — All security invariants
