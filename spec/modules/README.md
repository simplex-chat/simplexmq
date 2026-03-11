# How to Document a Module

> Read this before writing any module doc. It defines what goes in, what stays out, and why.

## Purpose

Module docs exist for one reason: to capture knowledge that **cannot be obtained by reading the source code**. If reading the `.hs` file tells you everything you need to know, the module doc should be brief or empty.

These docs are an investment — their value compounds over time as multiple people (and LLMs) work on the code. Optimize for long-term value, not for looking thorough today.

## Process

**Read every line of the source file.** The non-obvious filter applies to what you *write*, not to what you *read*. Without reading each line, you will produce documentation from inferences rather than facts. Many non-obvious behaviors only become visible when you see a specific line of code and recognize that its implications would surprise a reader who doesn't have the surrounding context.

## File structure

Module docs mirror `src/Simplex/` exactly. Same subfolder structure, `.hs` replaced with `.md`:

```
src/Simplex/Messaging/Server.hs    →  spec/modules/Simplex/Messaging/Server.md
src/Simplex/Messaging/Crypto.hs    →  spec/modules/Simplex/Messaging/Crypto.md
src/Simplex/FileTransfer/Agent.hs  →  spec/modules/Simplex/FileTransfer/Agent.md
```

## What to include

### 1. Non-obvious behavior
Things that would surprise a competent Haskell developer reading the code for the first time:
- Subtle invariants maintained across function calls
- Ordering dependencies ("must call X before Y because...")
- Concurrency assumptions ("this TVar is only written from thread Z")
- Implicit contracts between caller and callee not captured by types

### 2. Usage considerations
- When to use function X vs function Y
- Common mistakes callers make
- Caller obligations not enforced by the type system
- Performance characteristics that affect usage decisions

### 3. Cross-module relationships
- Dependencies on other modules' behavior not visible from import lists
- Assumptions about how other modules use this one
- Coordination patterns (e.g., "Server.hs reads this TVar, Agent.hs writes it")

### 4. Security notes
- Trust boundaries this module enforces or relies on
- What happens if inputs are malicious
- Which functions are security-critical and why (reference SI-XX invariants)

### 5. Design rationale
- Why the code is structured this way (when not obvious)
- Alternatives considered and rejected
- Known limitations and their justification

## Non-obvious threshold

The guiding principle: **non-obvious state machines and flows require documentation; standard things don't.**

Document:
- Multi-step protocols and negotiation flows (e.g., KEM propose/accept round-trips)
- Monotonic or irreversible state transitions (e.g., PQ support can only be enabled, never disabled)
- Silent error behaviors (e.g., `verify` returns `False` on algorithm mismatch instead of an error)
- Design rationale for non-standard choices (e.g., why byte-reverse a nonce, why hash-then-encrypt for authenticators)

Do NOT document:
- Standard algorithm properties (e.g., Ed25519 public key derivable from private key)
- Well-known protocol mechanics (e.g., HKDF usage per RFC 5869, deterministic nonce derivation in double ratchet)
- Implementation details that follow directly from the type signatures

## What NOT to include

- **Type signatures** — the code has them
- **Code snippets** — if you're pasting code, you're making a stale copy
- **Function-by-function prose that restates the implementation** — "this function takes X and returns Y by doing Z" adds nothing
- **Line numbers** — they're brittle and break on every edit
- **Comments that fit in one line in source** — put those in the source file instead as `-- spec:` comments

## Format

Each module doc has a header, then entries for functions/types that need documentation.

```markdown
# Module.Name

> One-line description of what this module does.

**Source**: [`Path/To/Module.hs`](relative link to source)

## Overview

[Only if the module's purpose or architecture is non-obvious.
Skip for simple modules.]

## functionName

**Purpose**: [What this does that isn't obvious from the name and type]
**Calls**: [Qualified.Name.a](link), [Qualified.Name.b](link)
**Called by**: [Qualified.Name.c](link)
**Invariant**: SI-XX
**Security**: [What this function ensures for the threat model]

[Free-form notes about non-obvious behavior, gotchas, etc.]

## anotherFunction

...
```

**For trivial modules** (< 100 LOC, no non-obvious behavior):

```markdown
# Module.Name

> One-line description.

**Source**: [`Path/To/Module.hs`](relative link to source)

No non-obvious behavior. See source.
```

This is valuable — it confirms someone looked and found nothing to document.

## Linking conventions

### Module doc → protocol docs
When a module implements or is governed by a protocol specification in `protocol/`, link to it near the top of the module doc (after the overview). Do not duplicate protocol content — just reference it:
```markdown
**Protocol spec**: [`protocol/pqdr.md`](../../../../protocol/pqdr.md) — Post-quantum resistant augmented double ratchet algorithm.
```

This is especially important for modules in transport, protocol, client, server, and agent layers where behavior is defined by the protocol spec rather than being self-evident from the code.

### Module doc → other module docs
Use fully qualified names as link text:
```markdown
[Simplex.Messaging.Server.subscribeServiceMessages](./Simplex/Messaging/Server.md#subscribeServiceMessages)
```

### Module doc → topic docs
```markdown
See [rcv-services](../rcv-services.md) for the end-to-end service subscription flow.
```

### Source → module doc

Add `-- spec:` comments as part of the module documentation work — when you document something non-obvious, add the link in source at the same time. Two levels:

**Module-level** (below the module declaration): when the Overview section has value.
```haskell
module Simplex.Messaging.Util (...) where
-- spec: spec/modules/Simplex/Messaging/Util.md
```

**Function-level** (above the function): when that function has a doc entry worth pointing to.
```haskell
-- spec: spec/modules/Simplex/Messaging/Util.md#catchOwn
-- Catches all exceptions except async cancellations (misleading name)
catchOwn :: ...
```

Only add `-- spec:` comments where the module doc actually says something the code doesn't. Don't add links to "No non-obvious behavior" docs or to entries that merely restate the source.

## Topic candidate tracking

While documenting modules, you will notice cross-cutting patterns — behaviors that span multiple modules and can't be understood from any single one. Note these in `spec/TOPICS.md` for later. Don't write the topic doc during module work; just record:

```markdown
- **Queue rotation**: Agent.hs initiates, Client.hs sends commands, Server.hs processes,
  Protocol.hs defines types. End-to-end flow not obvious from any single module.
```

## Quality bar

Before finishing a module doc, ask:
1. Does every entry document something NOT in the source code?
2. Would removing any entry lose information? If not, remove it.
3. Are cross-module relationships captured that imports alone don't reveal?
4. Are security-critical functions flagged with invariant IDs?
5. Is this doc short enough that someone will actually read it?

If any answer reveals a problem, fix it and repeat from question 1. Only finish when a full pass produces no changes.

## Exclusions

- **Individual migration files** (M20XXXXXX_*.hs): Self-describing SQL. No per-migration docs.
- **Auto-generated files** (GitCommit.hs): Skip.
- **Pure boilerplate** (Prometheus.hs metrics, Web/Embedded.hs static files): Document only if non-obvious.
