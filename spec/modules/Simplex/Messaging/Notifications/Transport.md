# Simplex.Messaging.Notifications.Transport

> NTF protocol version negotiation, TLS handshake, and transport handle setup.

**Source**: [`Notifications/Transport.hs`](../../../../../src/Simplex/Messaging/Notifications/Transport.hs)

## Non-obvious behavior

### 1. ALPN-dependent version range

`ntfServerHandshake` advertises `legacyServerNTFVRange` (v1 only) when ALPN is not available (`getSessionALPN` returns `Nothing`). When ALPN is present, it advertises the full `supportedServerNTFVRange`. This is the backward-compatibility mechanism for pre-ALPN clients that cannot negotiate newer protocol features.

### 2. Version-gated features

Two feature gates exist in the NTF protocol:

| Version | Feature | Effect |
|---------|---------|--------|
| v2 (`authBatchCmdsNTFVersion`) | Auth key exchange + batching | `authPubKey` sent in handshake, `implySessId` and `batch` enabled |
| v3 (`invalidReasonNTFVersion`) | Token invalid reasons | `NTInvalid` responses include the reason enum |

Pre-v2 connections have no command encryption or batching — commands are sent in plaintext within TLS.

### 3. Unused Protocol typeclass parameters

`ntfClientHandshake` accepts `_proxyServer` and `_serviceKeys` parameters that are ignored. These exist because the `Protocol` typeclass (shared with SMP) requires `protocolClientHandshake` to accept them. The NTF protocol does not support proxy routing or service authentication.

### 4. Block size

NTF uses a 512-byte block size (`ntfBlockSize`), significantly smaller than SMP. Notification commands and responses are short — the main payload is the `PNMessageData` which contains encrypted message metadata.
