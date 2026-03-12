# Simplex.Messaging.Protocol

> SMP protocol types, commands, responses, encoding/decoding, and transport functions.

**Source**: [`Protocol.hs`](../../../../src/Simplex/Messaging/Protocol.hs)

**Protocol spec**: [`protocol/simplex-messaging.md`](../../../../protocol/simplex-messaging.md) — SimpleX Messaging Protocol.

## Overview

This module defines the SMP protocol's type-level structure, wire encoding, and transport batching. It does not implement the router or client — those are in [Server.hs](./Server.md) and [Client.hs](./Client.md). The protocol spec governs the command semantics; this doc focuses on non-obvious implementation choices.

## Two separate version scopes

SMP client protocol version (`SMPClientVersion`, 4 versions) is separate from SMP relay protocol version (`SMPVersion`, up to version 19, defined in [Transport.hs](./Transport.md)). The client version governs client-to-client concerns (binary encoding, multi-host addresses, SKEY command, short links). The relay version governs client-to-router wire format, transport encryption, and command availability. See comment above `SMPClientVersion` data declaration for version history.

## maxMessageLength — version-dependent

`maxMessageLength` returns three different sizes depending on the relay version:
- v11+ (`encryptedBlockSMPVersion`): 16048
- v9+ (`sendingProxySMPVersion`): 16064
- older: 16088

The source has `TODO v6.0 remove dependency on version`. The type-level `MaxMessageLen` is fixed at 16088 with `TODO v7.0 change to 16048`.

## Type-level party system

10 `Party` constructors with `SParty` singletons, `PartyI` typeclass, and three constraint type families (`QueueParty`, `BatchParty`, `ServiceParty`). Invalid party usage produces compile-time errors via the `(Int ~ Bool, TypeError ...)` trick — the unsatisfiable `Int ~ Bool` constraint forces GHC to emit the `TypeError` message.

## IdsHash — reversible XOR for state drift monitoring

`IdsHash` uses `BS.zipWith xor` as its `Semigroup`. `queueIdHash` computes MD5 of the queue ID (16 bytes). `mempty` is 16 zero bytes. See comment on `subtractServiceSubs` for the reversibility property. `mconcat` is optimized to avoid repeated pack/unpack per step.

## TransmissionAuth — size-based type discrimination

`decodeTAuthBytes` distinguishes authenticator from signature by checking `B.length s == C.cbAuthenticatorSize`. This is a trap: if `cbAuthenticatorSize` ever coincides with a valid signature encoding size, the discrimination breaks. See comment on `tEncodeAuth` for the backward compatibility note (the encoding is backwards compatible with v6 that used `Maybe C.ASignature`).

## Service signature — state-dependent parser contract

In `transmissionP`, the service signature is only parsed when `serviceAuth` is true AND the authenticator is non-empty (`not (B.null authenticator)`). This means the parser's behavior depends on earlier parsed state — the service signature field is conditionally present on the wire. If a future change makes the authenticator always non-empty (or always empty), it silently changes whether service signatures are parsed.

## transmissionP / implySessId

When `implySessId` is `True`, the session ID is not transmitted on the wire — `transmissionP` sets `sessId` to `""` and prepends the local `sessionId` to the `authorized` bytes for verification. In `tDecodeServer`/`tDecodeClient`, session ID check is bypassed when `implySessId` is `True`.

## batchTransmissions_ — constraints and ordering

See comment for the 19-byte overhead calculation (pad size + transmission count + auth tag). Maximum 255 transmissions per batch (single-byte count). Uses `foldr` with `(:)` accumulation, which preserves original transmission order within each batch.

## ClientMsgEnvelope — two-layer message format

`ClientMsgEnvelope` has a `PubHeader` (client protocol version + optional X25519 DH key) and an encrypted body. The decrypted body is a `ClientMessage` containing a `PrivHeader` with prefix-based type discrimination: `"K"` for `PHConfirmation` (includes public auth key), `"_"` for `PHEmpty`.

## MsgFlags — forward-compatible parsing

The `MsgFlags` parser consumes the `notification` Bool then calls `A.takeTill (== ' ')` to swallow any remaining flag data. See comment on `MsgFlags` encoding for the 7-byte size constraint. Future flags added after `notification` are silently consumed and discarded by old clients.

## BrokerErrorType NETWORK — detail loss

The `NETWORK` variant of `BrokerErrorType` encodes as just `"NETWORK"` (detail dropped), with `TODO once all upgrade` comment. The parser falls back to `NEFailedError` when the `NetworkError` detail can't be parsed (`_smpP <|> pure NEFailedError`). This means a newer router's detailed network error is seen as `NEFailedError` by older clients.

## Version-dependent encoding — scope

`encodeProtocol` for both `Command` and `BrokerMsg` uses extensive version-conditional encoding. `NEW` has four encoding paths, `IDS` has five. All encoding paths for `IDS` must maintain the same field ordering — this is an implicit contract between encoder and decoder with no compile-time enforcement.

## SUBS/NSUBS — asymmetric defaulting

When the router parses `SUBS`/`NSUBS` from a client using a version older than `rcvServiceSMPVersion`, both count and hash default (`-1` and `mempty`). For the response side (`SOKS`/`ENDS` via `serviceRespP`), count is still parsed from the wire — only hash defaults to `mempty`. This asymmetry means command-side and response-side parsing have different fallback behavior for the same version boundary.
