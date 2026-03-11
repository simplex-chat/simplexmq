# Simplex.Messaging.Transport

> SMP transport layer: TLS connection management, SMP handshake protocol, block encryption, version negotiation.

**Source**: [`Transport.hs`](../../../../src/Simplex/Messaging/Transport.hs)

**Protocol spec**: [`protocol/simplex-messaging.md` — Transport connection](../../../../protocol/simplex-messaging.md#transport-connection-with-the-smp-router) — SMP encrypted transport, handshake syntax, certificate chain requirements.

## Overview

This is the core transport module. It defines:
- The `Transport` typeclass abstracting over TLS and WebSocket connections
- The SMP handshake protocol (server and client sides)
- Optional block encryption using HKDF-derived symmetric key chains (v11+)
- Version negotiation with backward-compatible extensions

Per the protocol spec: "Each transport block has a fixed size of 16384 bytes for traffic uniformity." The `sessionIdentifier` field uses tls-unique channel binding (RFC 5929) — "it should be included in authorized part of all SMP transmissions sent in this transport connection."

## SMP version 13 is missing

The version history jumps from 12 (`blockedEntitySMPVersion`) to 14 (`proxyServerHandshakeSMPVersion`). Version 13 was skipped.

## proxiedSMPRelayVersion — anti-fingerprinting cap

`proxiedSMPRelayVersion = 18`, one below `currentClientSMPRelayVersion = 19`. The code comment states: "SMP proxy sets it to lower than its current version to prevent client version fingerprinting by the destination relays when clients upgrade at different times."

In practice (Server.hs), the SMP proxy uses `proxiedSMPRelayVRange` to cap the destination relay's version range in the `PKEY` response sent to the client, so the client sees a capped version range rather than the relay's actual range.

## withTlsUnique — different API calls yield same value

`withTlsUnique` extracts the tls-unique channel binding (RFC 5929) using a type-level dispatch:
- **Server** (`STServer`): `T.getPeerFinished` — the peer's (client's) Finished message
- **Client** (`STClient`): `T.getFinished` — own (client's) Finished message

Both calls yield the client's Finished message. If the result is `Nothing`, the connection is closed immediately (`closeTLS cxt >> ioe_EOF`).

## defaultSupportedParams vs defaultSupportedParamsHTTPS

Two TLS parameter sets:

- **`defaultSupportedParams`**: ChaCha20-Poly1305 ciphers only, Ed448/Ed25519 signatures only, X448/X25519 groups. Per the protocol spec: "TLS_CHACHA20_POLY1305_SHA256 cipher suite, ed25519 EdDSA algorithms for signatures, x25519 ECDHE groups for key exchange."
- **`defaultSupportedParamsHTTPS`**: extends `defaultSupportedParams` with `ciphersuite_strong`, additional groups, and additional hash/signature combinations. The source comment says: "A selection of extra parameters to accomodate browser chains."

In the SMP server (Server.hs), when HTTP credentials are configured, `defaultSupportedParamsHTTPS` is used for all connections on that port (not selected per-connection). When no HTTP credentials are configured, `defaultSupportedParams` is used.

## SMP handshake flow

Per the [protocol spec](../../../../protocol/simplex-messaging.md#transport-handshake), the handshake is a two-message exchange (three if service certs are used):

1. **Server → Client**: `paddedRouterHello` containing `smpVersionRange`, `sessionIdentifier` (tls-unique), and `routerCertKey` (certificate chain + X25519 key signed by the server's certificate)
2. **Client → Server**: `paddedClientHello` containing agreed `smpVersion`, `keyHash` (router identity — CA certificate fingerprint), optional `clientKey`, `proxyRouter` flag, and optional `clientService`
3. **Server → Client** (service only): `paddedRouterHandshakeResponse` containing assigned `serviceId` or `handshakeError`

The client verifies `sessionIdentifier` matches its own tls-unique (`when (sessionId /= sessId) $ throwE TEBadSession`). The server verifies `keyHash` matches its CA fingerprint (`when (keyHash /= kh) $ throwE $ TEHandshake IDENTITY`).

Per the protocol spec: "For TLS transport client should assert that sessionIdentifier is equal to tls-unique channel binding defined in RFC 5929."

### legacyServerSMPRelayVRange when no ALPN

If ALPN is not negotiated (`getSessionALPN c` returns `Nothing`), the server offers `legacyServerSMPRelayVRange` (v6 only) instead of the full version range. Per the protocol spec: "If the client does not confirm this protocol name, the router would fall back to v6 of SMP protocol." The spec notes: "This is added to allow support of older clients without breaking backward compatibility and to extend or modify handshake syntax."

### Service certificate handshake extension

When `clientService` is present in the client handshake, the server performs additional verification:
- The TLS client certificate chain must exactly match the certificate chain in the handshake message (`getPeerCertChain c == cc`)
- The signed X25519 public key is verified against the leaf certificate's key (`getCertVerifyKey leafCert` then `C.verifyX509`)
- On success, the server sends `SMPServerHandshakeResponse` with a `serviceId`
- On failure, the server sends `SMPServerHandshakeError` before raising the error

Per the protocol spec (v16+): "`clientService` provides long-term service client certificate for high-volume services using SMP router (chat relays, notification routers, high traffic bots). The router responds with a third handshake message containing the assigned service ID."

The client only includes service credentials when `v >= serviceCertsSMPVersion && certificateSent c` (the TLS client certificate was actually sent).

## tPutBlock / tGetBlock — optional block encryption

When `encryptBlock` is set, transport blocks are encrypted before being sent over TLS:

- **Send**: `atomically $ stateTVar sndKey C.sbcHkdf` advances the chain key and returns `(SbKey, CbNonce)`; the block is encrypted with `C.sbEncrypt`
- **Receive**: same pattern with `rcvKey` and `C.sbDecrypt`

The chain keys are initialized from `C.sbcInit sessionId secret` where `sessionId` is the tls-unique value and `secret` is the session DH shared secret.

The code comment on `proxyServer` flag states: "This property, if True, disables additional transport encrytion inside TLS. (Proxy server connection already has additional encryption, so this layer is not needed there)." The protocol spec confirms: "`proxyRouter` flag (v14+) disables additional transport encryption inside TLS for proxy connections, since proxy router connection already has additional encryption."

The protocol spec version history (v11) describes this as "additional encryption of transport blocks with forward secrecy."

## smpTHandleClient — chain key swap

`smpTHandleClient` applies `swap` to the chain key pair before creating `TSbChainKeys`. The code comment states: "swap is needed to use client's sndKey as server's rcvKey and vice versa."

## Proxy version downgrade logic

When the proxy connects to a destination relay older than v14 (`proxyServerHandshakeSMPVersion`), the client-side handshake caps the version range:

```
if proxyServer && maxVersion smpVersionRange < proxyServerHandshakeSMPVersion
  then vRange {maxVersion = max (minVersion vRange) deletedEventSMPVersion}
```

The code comment explains: "Transport encryption between proxy and destination breaks clients with version 10 or earlier, because of a larger message size (see maxMessageLength)." The cap at `deletedEventSMPVersion` (v10) ensures transport encryption (v11+) is not negotiated with older relays.

The comment also notes: "Prior to version v6.3 the version between proxy and destination was capped at 8, by mistake, which also disables transport encryption and the latest features."

## forceCertChain

`forceCertChain` forces evaluation of the certificate chain and signed key via `length (show cc) `seq` show signedKey `seq` cert`. Introduced in commit 9e7e0d10 ("smp-server: conserve resources"), sub-bullet "transport: force auth params, remove async wrapper" — part of a commit that adds strictness annotations throughout (`bang more thunks`, `strict`).

## smpTHandle — version 0 bootstrap

`smpTHandle` creates a `THandle` with version 0, no auth, and no block encryption. This handle is used for the handshake exchange itself (`sendHandshake`/`getHandshake`). After the handshake completes, `smpTHandle_` creates the real handle with the negotiated version, auth, and encryption parameters.

## getHandshake — forward-compatible parsing

The code comment states: "ignores tail bytes to allow future extensions." The protocol spec confirms: "`ignoredPart` in handshake allows to add additional parameters in handshake without changing protocol version — the client and routers must ignore any extra bytes within the original block length."
