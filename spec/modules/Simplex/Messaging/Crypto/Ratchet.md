# Simplex.Messaging.Crypto.Ratchet

> Double ratchet with post-quantum KEM extension (PQ X3DH + header encryption).

**Source**: [`Crypto/Ratchet.hs`](../../../../../src/Simplex/Messaging/Crypto/Ratchet.hs)

## Overview

Implements the Signal double ratchet protocol extended with:
- **Header encryption** (HE variant): message headers are encrypted with separate header keys, hiding the ratchet public key and message counters from observers.
- **Post-quantum KEM** (PQ variant): SNTRUP761 key encapsulation is folded into each ratchet step, providing PQ-resistance alongside X448 DH.

The ratchet uses X448 (not X25519) for DH operations — `type RatchetX448 = Ratchet 'X448`.

**Protocol spec**: [`protocol/pqdr.md`](../../../../protocol/pqdr.md) — Post-quantum resistant augmented double ratchet algorithm.

## PQ X3DH key agreement

`pqX3dhSnd` / `pqX3dhRcv` perform the extended X3DH:
- Standard triple DH: `DH(rk1, spk2)`, `DH(rk2, spk1)`, `DH(rk2, spk2)`
- Optional KEM shared secret from SNTRUP761 encapsulation
- Combined via `HKDF(salt=64_zeroes, DHs || KEMss, "SimpleXX3DH", 96)` → root key, header key, next-header key

The roles (who is "Alice" vs "Bob") are **reversed from the double ratchet spec**: the party initiating the connection is Bob (`generateRcvE2EParams`, `initRcvRatchet`), and the party accepting is Alice (`generateSndE2EParams`, `initSndRatchet`). Comments in the source explicitly note this.

## KDF functions

- **rootKdf**: `HKDF(rootKey, DH(pubKey, privKey) || KEMss, "SimpleXRootRatchet", 96)` → new root key (32), chain key (32), next header key (32)
- **chainKdf**: `HKDF("", chainKey, "SimpleXChainRatchet", 96)` → new chain key (32), message key (32), two IVs (16 + 16)

All use HKDF-SHA512 via [Simplex.Messaging.Crypto.hkdf](../Crypto.md).

## Header encryption and padding

Headers are encrypted with AEAD-GCM using the header key. The padded header length depends on whether PQ is supported:
- **Without PQ**: 88 bytes (fits DH key + counters)
- **With PQ**: 2310 bytes (fits DH key + KEM params + counters, with reserve for future extension)

The actual header is ~69 bytes without PQ, ~2288 with PQ. The padding ensures all messages have identical header sizes regardless of content.

## Version negotiation in headers

Each message header carries `msgMaxVersion` (the sender's max supported ratchet version). On decryption, the receiver upgrades its `current` version to `min(msgMaxVersion, maxSupported)` but never downgrades. The current version determines:
- Whether KEM params are included in headers (v3+)
- Whether 2-byte length prefixes are used for headers (v3+)

## largeP — backward-compatible length prefix parsing

`largeP` detects the length-prefix format by peeking at the first byte: if < 32, it's a 2-byte `Large` prefix (new format); otherwise it's a 1-byte prefix (old format). This allows upgrading the header encoding format in a single message without a version bump.

## maxSkip = 512 — DoS protection

`maxSkip` is a hardcoded constant (not configurable). Messages claiming to be more than 512 positions ahead of the current counter are rejected with `CERatchetTooManySkipped`. This prevents an attacker from forcing the receiver to compute and store an unbounded number of skipped message keys.

## Skipped message keys

When messages arrive out of order, the ratchet computes and stores the message keys for skipped messages (up to `maxSkip`). Skipped keys are stored in a `Map HeaderKey (Map Word32 MessageKey)` — keyed first by header key, then by message number.

The `SkippedMsgDiff` type represents changes to the skipped key store as a diff rather than a full replacement — this is persisted to the database, and the full state is loaded for the next message. `applySMDiff` is only used in tests.

## rcDecrypt flow

Decryption tries three strategies in order:
1. **Skipped message keys**: try all stored header keys to decrypt the header, then look up the message number in skipped keys
2. **Current receiving ratchet**: decrypt header with `rcHKr`
3. **Next header key**: decrypt header with `rcNHKr` (triggers a ratchet advance)

If strategy 1 decrypts the header but the message number isn't in skipped keys, it checks whether this header key corresponds to the current or next ratchet to decide whether to advance.

### decryptSkipped — linear scan through all stored header keys

`decryptSkipped` iterates through ALL `(HeaderKey, SkippedHdrMsgKeys)` pairs, attempting header decryption with each key. When header decryption succeeds but the message number is NOT in the skipped keys for that header, the result is `SMHeader` — which includes whether the key matches the current ratchet (`rcHKr` → `SameRatchet`) or the next ratchet (`rcNHKr` → `AdvanceRatchet`). This falls through to normal decryption processing rather than producing an error.

### decryptMessage — ratchet advances even on failure

`decryptMessage` returns `Either CryptoError ByteString` inside the `ExceptT` monad — a message decryption failure does NOT abort the ratchet state update. The ratchet counter advances (`rcNr + 1`) and chain key updates (`rcCKr'`) regardless of whether the message body decrypts successfully. This preserves ratchet state consistency for retransmission and error recovery.

## rcEncryptHeader — separated from rcEncryptMsg

Encryption is split into two steps: `rcEncryptHeader` produces a `MsgEncryptKey` (containing the encrypted header and message key), then `rcEncryptMsg` uses that key to encrypt the message body. This separation allows the ratchet state to be updated (persisted) before the message is encrypted, which is important for crash recovery — if the process crashes after encrypting but before sending, the ratchet state must already reflect the advanced counter.

## PQ ratchet step

During each ratchet advance (`pqRatchetStep`), the PQ KEM is folded in:
1. Receive: if the header contains a KEM ciphertext and we have the decapsulation key, compute the shared secret
2. Send: generate a new KEM keypair, encapsulate against the received public key, include in the next header
3. The KEM shared secret is concatenated with the DH shared secret before `rootKdf`

PQ can be enabled/disabled per-message via `pqEnc_` parameter. `rcSupportKEM` can only be enabled (never disabled) — once PQ headers are used, the larger header size is permanent.

## PQSupport vs PQEncryption

Two distinct newtypes with identical structure (`Bool` wrapper):
- `PQSupport`: whether PQ **can** be used (determines header padding size, cannot be disabled once enabled)
- `PQEncryption`: whether PQ **is** being used for the current send/receive ratchet

### pqEnableSupport is monotonic

`pqEnableSupport v sup enc = PQSupport $ sup || (v >= pqRatchetE2EEncryptVersion && enc)`. The `||` means once PQ support is `True`, it stays `True` regardless of subsequent messages. PQ encryption (usage) can be toggled per-message; PQ support (capability / header size) only ratchets up. This prevents the larger header format from being downgraded once negotiated.

## replyKEM_ — two-step KEM negotiation

KEM establishment requires two message round-trips, as described in the [PQDR KEM state machine](../../../../protocol/pqdr.md#kem-state-machine):

1. **Propose**: if the sender has no KEM in their header but the replier supports PQ at sufficient version, the replier includes a KEM proposal (`RKParamsProposed` — their encapsulation public key)
2. **Accept**: if the sender proposed KEM, the replier accepts by encapsulating against the proposed key and including the ciphertext + their own new encapsulation key (`RKParamsAccepted`)

After acceptance, both sides have a shared KEM secret that is folded into the root KDF. Subsequent ratchet steps continue the KEM exchange with fresh keypairs on each side.

## Error semantics

- `CERatchetEarlierMessage n`: message number is `n` positions before the next expected (already processed or skipped-and-consumed)
- `CERatchetDuplicateMessage`: message number is the most recently received (exact repeat)
- `CERatchetTooManySkipped n`: would need to skip `n` messages, exceeding `maxSkip`
- `CERatchetHeader`: header decryption failed with all available keys
- `CERatchetState`: no sending chain (ratchet not initialized for sending)
- `CERatchetKEMState`: KEM state mismatch between parties

## InitialKeys

Controls PQ key inclusion in connection establishment:
- `IKUsePQ`: always include PQ keys (used in contact requests and short link data)
- `IKLinkPQ pq`: include PQ keys only in short link data, if `pq` is enabled

`initialPQEncryption` resolves this based on whether it's a short link context.
