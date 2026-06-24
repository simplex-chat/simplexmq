# Simplex.Messaging.Agent.Protocol

> Agent protocol types, wire formats, connection link serialization, and error taxonomy.

**Source**: [`Agent/Protocol.hs`](../../../../../../src/Simplex/Messaging/Agent/Protocol.hs)

**Protocol spec**: [`protocol/agent-protocol.md`](../../../../../protocol/agent-protocol.md) — duplex connection procedure, agent message syntax, connection link formats.

## Overview

This module defines the agent-level protocol: the types exchanged between agents (via SMP routers) and between agent and client application. It contains no IO — purely types, serialization, and validation logic.

The module carries two independent version scopes: `SMPAgentVersion` (agent-to-agent protocol, currently v2–v7) and `SMPClientVersion` (agent-to-router protocol, imported from `Protocol.hs`). These version scopes interact but are negotiated independently — see [Protocol.md](../Protocol.md#two-separate-version-scopes).

## Two-layer message format

Agent messages use a two-layer envelope structure:

1. **Outer envelope** (`AgentMsgEnvelope`): version + single-char type tag (`C`/`M`/`I`/`R`) + type-specific payload. The `C` (confirmation) and `M` (message) variants carry double-ratchet encrypted content. The `I` (invitation) variant is encrypted only with per-queue E2E. The `R` (ratchet key) variant carries ratchet renegotiation parameters.

2. **Inner message** (`AgentMessage`): after double-ratchet decryption, discriminated by tags `I`/`D`/`R`/`M`. The `M` variant contains `APrivHeader` (sequential message ID + previous message hash for integrity) followed by `AMessage` (the actual command: `HELLO`, `A_MSG`, queue rotation, etc).

The tag characters overlap between layers (`I` means confirmation-conninfo in inner, invitation in outer; `M` means message-envelope in outer, agent-message in inner). These are disambiguated by context — outer parsing happens first, then decryption, then inner parsing.

## e2eEncConnInfoLength / e2eEncAgentMsgLength — PQ-dependent size budgets

Connection info and agent message size limits depend on both agent version and PQ support. When PQ is enabled (v5+), the limits are *smaller* — not larger — because the ratchet header and reply link grow with PQ keys (SNTRUP761), consuming space from the fixed SMP message block. The specific reductions (3726 for conninfo, 2222 for messages) are documented in source comments.

## AgentMsgEnvelope — connInfo encryption asymmetry

`AgentInvitation` encrypts `connInfo` only with per-queue E2E (no double ratchet) — see source comment. This is because invitations are sent to contact address queues where no ratchet has been established. `AgentConfirmation` encrypts with double ratchet. `AgentRatchetKey` uses per-queue E2E for the ratchet parameters themselves (bootstrapping problem: can't use ratchet to renegotiate the ratchet).

## AgentMessageType — dual encoding paths

`AgentMessageType` and `AMsgType` encode the same set of message types but serve different purposes: `AgentMessageType` includes the envelope types (`AM_CONN_INFO`, `AM_CONN_INFO_REPLY`, `AM_RATCHET_INFO`) for database storage, while `AMsgType` only covers the inner `AMessage` types. Both share the same wire tags for the overlapping types (`H`, `M`, `V`, `QC`, `QA`, `QK`, `QU`, `QT`, `E`). The `Q`-prefixed types use two-character tags (prefix dispatch), all others use single characters.

## HELLO — sent once after securing

`HELLO` is sent exactly once, when the queue is known to be secured (duplex handshake). Not used at all in fast duplex connection (v9+ SMP). The v1 slow handshake (which sent HELLO multiple times until securing succeeded) is no longer supported — `minSupportedSMPAgentVersion = duplexHandshakeSMPAgentVersion` (v2).

## AEvent entity type system

`AEvent` is a GADT indexed by `AEntity` (phantom type: `AEConn`, `AERcvFile`, `AESndFile`, `AENone`). This prevents the type system from allowing file events on connection entities and vice versa. The existential wrapper `AEvt` erases the entity type for storage in heterogeneous collections — equality comparison (`Eq AEvt`) uses `testEquality` on the singleton witness to recover type information.

`AENone` is used for events that aren't associated with any specific entity (e.g., `DOWN`, `UP`, `SUSPENDED`, `DEL_USER`). These are router-level or agent-level notifications, not connection-level.

## ConnectionMode singleton pattern

`ConnectionMode` / `SConnectionMode` / `ConnectionModeI` implement the singleton pattern: `SConnectionMode` is the type-level witness, `ConnectionModeI` is the typeclass that lets you recover the singleton from a type parameter. Many types are parameterized by `ConnectionMode` (`ConnectionRequestUri m`, `ConnShortLink m`, `ConnectionLink m`, etc.) to prevent mixing invitation and contact types at compile time.

`checkConnMode` is the runtime escape hatch — it uses `testEquality` to cast between mode-parameterized types, returning `Left "bad connection mode"` on mismatch. This is used extensively in parsers where the mode is determined at parse time.

## ConnReqUriData smpP — queueMode patch

The binary parser for `ConnReqUriData` applies `patchQueueMode` to all queues, setting `queueMode = Just QMContact` when it's `Nothing`. See source comment: this compensates for `QMContact` not being included in queue encoding until min SMP client version >= 3. This patch is safe because the binary encoding path was not used before SMP client version 4.

## Connection link URI parsing — version range adjustment

`connReqUriP` adjusts the agent version range for contact links: `adjustAgentVRange` clamps the minimum to `minSupportedSMPAgentVersion`. This preserves compatibility with old contact links published online — they may advertise version ranges starting below the current minimum, and clamping prevents negotiation from failing on an unsupported version.

The semicolon separator for SMP queues in the URI query string is deliberate — commas are used within server addresses to separate hostnames, so semicolons separate queues to avoid ambiguity.

## Short link encoding — contactConnType as URL path character

Short links encode `ContactConnType` as a single lowercase letter in the URL path: `a` (contact), `c` (channel), `g` (group), `r` (relay). Invitation links use `i`. The parser uses `toUpper` before dispatching to `ctTypeP` (which expects uppercase), while the encoder uses `toLower` on `ctTypeChar` output. This case dance happens because the wire format wants lowercase URLs but the internal representation uses uppercase.

## Short link router shortening

`shortenShortLink` strips port and key hash from preset routers, leaving only the hostname (`SMPServerOnlyHost` pattern). This makes short links shorter for well-known routers. `restoreShortLink` reverses this by looking up the full router definition from the preset list. Both functions match on primary hostname only (first in the `NonEmpty` list).

`isPresetServer` has a non-obvious port matching rule: empty port in the preset matches `"443"` or `"5223"` in the link. This handles servers that use default ports without explicitly listing them.

## OwnerAuth — chain-of-trust validation

`OwnerAuth` is double-encoded: the inner fields are `smpEncode`d, then the result is encoded as a `ByteString` (with length prefix). See source comment: "additionally encoded as ByteString to have known length and allow OwnerAuth extension." The parser uses `parseOnly` on the inner bytes, which silently ignores trailing data — providing forward compatibility for future field additions.

`validateLinkOwners` enforces a chain-of-trust: each owner must be signed by either the root key or any *preceding* owner in the list. Order matters — an owner signed by a later owner in the list will fail validation. Duplicate keys or IDs are rejected. An owner key matching the root key is rejected (prevents trivial self-authorization).

## UserLinkData — length-prefix switchover

`UserLinkData` uses a 1-byte length prefix for data ≤ 254 bytes, switching to a `\255` sentinel byte followed by a 2-byte (`Large`) length prefix for longer data. This is a backward-compatible extension of the standard `smpEncode` string format (which uses 1-byte length, capping at 255 bytes).

## FixedLinkData / ConnLinkData — forward-compatible parsing

Both `FixedLinkData` and `ConnLinkData` (invitation variant) consume trailing bytes with `A.takeByteString` after parsing known fields. See source comment: "ignoring tail for forward compatibility with the future link data encoding." This allows newer agents to add fields without breaking older parsers.

## AgentErrorType — BlockedIndefinitely promotion

`fromSomeException` in the `AnyError` instance promotes `BlockedIndefinitelyOnSTM` and `BlockedIndefinitelyOnMVar` to `CRITICAL` errors (with `offerRestart = True`) rather than generic `INTERNAL`. These are thread deadlock signals from the GHC runtime — they indicate a program bug, not a transient error. The `CRITICAL` classification with restart offer means the client application should prompt the user.

## cryptoErrToSyncState — error severity classification

Maps crypto errors to ratchet sync states: `DECRYPT_AES`, `DECRYPT_CB`, and `RATCHET_EARLIER` map to `RSAllowed` (sync is optional, may self-recover). `RATCHET_HEADER`, `RATCHET_SKIPPED`, and `RATCHET_SYNC` map to `RSRequired` (sync must happen before communication can continue). This classification determines whether the agent automatically initiates ratchet resynchronization.

## extraSMPServerHosts — hardcoded onion mappings

Maps clearnet hostnames of preset SMP routers to their `.onion` addresses. `updateSMPServerHosts` adds the onion host as a second hostname when parsing legacy queue URIs that only have one host. This is used for backward compatibility with queue URIs created before multi-host support — modern URIs include all hosts directly.

## Queue rotation state machines

`RcvSwitchStatus` and `SndSwitchStatus` encode the two sides of the queue rotation protocol:

- **Receiver side**: `RSSwitchStarted` → `RSSendingQADD` → `RSSendingQUSE` → `RSReceivedMessage`
- **Sender side**: `SSSendingQKEY` → `SSSendingQTEST`

The asymmetry reflects the protocol: the receiver initiates rotation and sends more messages (QADD, QUSE), while the sender responds (QKEY, QTEST). These states are persisted to the database — the `StrEncoding` instances use snake_case strings as the canonical serialization format. See [agent-protocol.md — Rotating messaging queue](../../../../../protocol/agent-protocol.md#rotating-messaging-queue).

## SMPQueueInfo / SMPQueueUri — version duality

`SMPQueueInfo` (single version) and `SMPQueueUri` (version range) represent the same queue address but in different contexts. `VersionI` / `VersionRangeI` typeclasses convert between them — `toVersionT` pins a version range to a specific version, `toVersionRangeT` wraps a versioned type in a range. See source comment on `VersionI SMPClientVersion SMPQueueInfo`: the current conversion is trivial (just swapping the version/range field) but the typeclass exists so that future field additions can have version-dependent conversion logic.

`SMPQueueInfo` encoding has four version-conditional paths: v1 (legacy server encoding), v2+ (standard encoding), v3+ with secure sender (appends `sndSecure` bool), v4+ (appends `queueMode`). The parser uses `clientVersion` to select between `legacyServerP` and standard `smpP` for the server field, and `updateSMPServerHosts` backfills onion addresses for legacy URIs.

## ACommand — binary body parsing

`commandP` takes a custom body parser. `dbCommandP` uses `A.take =<< A.decimal <* "\n"` — length-prefixed binary read. This is for commands stored in the database where the body must be fully parsed (not left as unparsed trailing bytes). The standard command parser uses `A.takeByteString` for bodies, consuming remaining input.

`pqIKP` defaults to `IKLinkPQ PQSupportOff` when PQ support is not specified, and `pqSupP` defaults to `PQSupportOff`. These defaults maintain backward compatibility with commands serialized before PQ support was added.
