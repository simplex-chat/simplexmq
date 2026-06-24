# Simplex.Messaging.Notifications.Transport

> NTF protocol version negotiation, TLS handshake, and transport handle setup.

**Source**: [`Notifications/Transport.hs`](../../../../../src/Simplex/Messaging/Notifications/Transport.hs)

## Non-obvious behavior

### 1. ALPN-dependent version range

`ntfServerHandshake` advertises `legacyServerNTFVRange` (v1 only) when ALPN is not available (`getSessionALPN` returns `Nothing`). When ALPN is present, it advertises the caller-provided `ntfVRange`. This is the backward-compatibility mechanism for pre-ALPN clients that cannot negotiate newer protocol features.

### 2. Version-gated features

Two feature gates exist in the NTF protocol:

| Version | Feature | Effect |
|---------|---------|--------|
| v2 (`authBatchCmdsNTFVersion`) | Auth key exchange + batching | `authPubKey` sent in handshake, `implySessId` and `batch` enabled |
| v3 (`invalidReasonNTFVersion`) | Token invalid reasons | `NTInvalid` results include the reason enum |

Pre-v2 connections have no command encryption or batching — commands are sent in plaintext within TLS.

### 3. Unused Protocol typeclass parameters

`ntfClientHandshake` accepts `_proxyServer` and `_serviceKeys` parameters that are ignored. These are passed through from the `Protocol` typeclass's `protocolClientHandshake` method for consistency with SMP. A third parameter (`Maybe C.KeyPairX25519` for key agreement) is discarded at the Protocol instance wrapper level. The NTF protocol does not support proxy routing or service authentication.

### 4. Block size

NTF uses a 512-byte block size (`ntfBlockSize`), significantly smaller than SMP. This is sufficient because NTF protocol commands (TNEW, SNEW, TCHK, etc.) and their results are short. `PNMessageData` (which contains encrypted message metadata) is not sent over the NTF transport — it is delivered via APNS push notifications.

### 5. Initial THandle has version 0

`ntfTHandle` creates a THandle with `thVersion = VersionNTF 0` — a version that no real protocol supports. This is a placeholder value that gets overwritten during version negotiation. All feature gates check `v >= authBatchCmdsNTFVersion` (v2), so the v0 placeholder disables all optional features.

### 6. Router handshake always sends authPubKey

`ntfServerHandshake` always includes `authPubKey = Just sk` in the router handshake, regardless of the advertised version range. The encoding functions (`encodeAuthEncryptCmds`) then decide whether to actually serialize it based on the max version. This means the key is computed even when it won't be sent.
