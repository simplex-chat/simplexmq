# Transport

How data moves over the wire: TLS infrastructure, protocol handshake family, block framing, transmission encoding, version negotiation, and connection management. This is the cross-cutting view spanning TLS setup, protocol-specific handshakes, block-level framing, and the protocol client's thread architecture.

For service certificate handshake extensions, see [client-services.md](client-services.md). For the protocol client's role in subscription flow, see [subscriptions.md](subscriptions.md). For the SMP protocol specification, see [simplex-messaging.md](../../protocol/simplex-messaging.md).

- [TLS infrastructure](#tls-infrastructure)
- [Handshake protocol family](#handshake-protocol-family)
- [Block framing](#block-framing)
- [Transmission encoding and signing](#transmission-encoding-and-signing)
- [Version negotiation](#version-negotiation)
- [Connection management](#connection-management)

---

## TLS infrastructure

**Source**: [Transport.hs](../../src/Simplex/Messaging/Transport.hs), [Transport/Credentials.hs](../../src/Simplex/Messaging/Transport/Credentials.hs), [Transport/Client.hs](../../src/Simplex/Messaging/Transport/Client.hs)

### Certificate generation

`genCredentials` generates Ed25519 key pairs and self-signed (or parent-signed) X.509 v3 certificates. Validity periods use an `Hours` offset type. The certificate serial number is always 1; nanoseconds are stripped from timestamps during encoding.

For CA + leaf chains (used by routers), a root CA certificate signs a leaf certificate. The leaf's private key is used for per-session signing. For self-signed certificates (used by service clients), a single certificate serves both purposes.

### TLS parameters

`defaultSupportedParams` configures a minimal, high-security cipher suite:

| Parameter | Value |
|-----------|-------|
| TLS versions | TLS 1.3, TLS 1.2 |
| TLS 1.3 cipher | CHACHA20-POLY1305-SHA256 |
| TLS 1.2 cipher | ECDHE-ECDSA-CHACHA20-POLY1305-SHA256 |
| Hash-signature pairs | Ed448, Ed25519 (both HashIntrinsic) |
| DH groups | X448, X25519 |
| Secure renegotiation | Disabled |

`defaultSupportedParamsHTTPS` extends this with browser-compatible ciphers (RSA, ECDSA with SHA256/384/512, FFDHE groups, P521) for XFTP web clients.

### Session identity

Both sides derive `sessionId` from the TLS-unique channel binding value (RFC 5929). The server reads `T.getPeerFinished`; the client reads `T.getFinished`. This `sessionId` is used throughout the session - in handshake validation, transmission signing, and block encryption key derivation.

### Certificate chain semantics

**Source**: [Transport/Shared.hs](../../src/Simplex/Messaging/Transport/Shared.hs)

Routers use variable-length certificate chains. The `chainIdCaCerts` function extracts the identity certificate (`idCert`) based on chain length:

| Chain length | Structure | Identity certificate |
|--------------|-----------|---------------------|
| 0 | `[]` | Rejected as CCEmpty |
| 1 | `[cert]` | Self-signed: `idCert = cert` |
| 2 | `[leaf, ca]` | Current online/offline pattern: `idCert = ca` |
| 3 | `[leaf, id, ca]` | With operator certificate: `idCert = id` (second) |
| 4 | `[leaf, id, net, ca]` | With network certificate: `idCert = id` (second, network cert ignored) |
| 5+ | - | Rejected as CCLong |

The **router identity** is always determined by `idCert` - its SHA256 fingerprint is compared against the `keyHash` the client expects. For 2-cert chains (the common case), `idCert` equals the CA. For 3+ cert chains, `idCert` is always the **second certificate** (index 1).

The client verifies the router identity by computing `XV.getFingerprint idCert X.HashSHA256` and comparing against the expected `keyHash`. This allows operators to rotate leaf certificates without changing the router's public identity.

---

## Handshake protocol family

**Source**: [Transport.hs](../../src/Simplex/Messaging/Transport.hs), [Notifications/Transport.hs](../../src/Simplex/Messaging/Notifications/Transport.hs)

All three protocols (SMP, NTF, XFTP) use the same TLS transport, but their application-level handshakes differ in complexity. SMP and NTF use a block-based handshake over TLS; XFTP uses HTTP/2 POST with a custom handshake.

### SMP handshake - two messages plus optional third

**Message 1 (router to client)**: `SMPServerHandshake` contains:
- `smpVersionRange` - negotiable version range (uses ALPN to select current vs legacy range)
- `sessionId` - TLS-unique channel binding
- `authPubKey` - `CertChainPubKey`: certificate chain plus X25519 public key signed with the certificate's signing key (v7+)

**Message 2 (client to router)**: `SMPClientHandshake` contains:
- `smpVersion` - agreed maximum version from intersection
- `keyHash` - SHA256 of router's identity certificate (`idCert`, see certificate chain semantics above)
- `authPubKey` - client's X25519 public key for DH agreement (v7+)
- `proxyServer` - boolean flag to disable transport block encryption (v14+)
- `clientService` - service credentials with `serviceRole` and `serviceCertKey` (v16+)

**Message 3 (router to client, conditional)**: Sent only when `clientService` is present. The router verifies the TLS peer certificate matches the handshake certificate chain, extracts the fingerprint, creates or retrieves a `ServiceId`, and returns `SMPServerHandshakeResponse {serviceId}` (or `SMPServerHandshakeError` on failure).

### NTF handshake - simplified two messages

The NTF handshake follows the same server-first pattern but is simpler:

| Difference | SMP | NTF |
|-----------|-----|-----|
| Block size | 16384 bytes | 512 bytes |
| Client auth key | X25519 DH public key | None (server sends key, client does not) |
| Service certificates | v16+ | Not supported |
| Block encryption | v11+ | Not supported |
| Batching | v4+ | v2+ |
| Version range | v6 - v19 | v1 - v3 |

`NtfServerHandshake` sends version range, sessionId, and signed X25519 key (present at v2+, absent at v1). `NtfClientHandshake` returns only version and keyHash. No client public key exchange, no service certificates, no block encryption.

### XFTP handshake - HTTP/2 based

**Source**: [FileTransfer/Transport.hs](../../src/Simplex/FileTransfer/Transport.hs), [FileTransfer/Server.hs](../../src/Simplex/FileTransfer/Server.hs), [FileTransfer/Client.hs](../../src/Simplex/FileTransfer/Client.hs)

XFTP does not use the block-based TLS handshake. It uses HTTP/2 POST with ALPN `"xftp/1"`. The handshake has two flows depending on client type.

**Native client handshake** (standard two-step):

1. Client sends POST with no body, server responds with `XFTPServerHandshake`:
   - `xftpVersionRange` - negotiable version range
   - `sessionId` - TLS-unique channel binding
   - `authPubKey` - `CertChainPubKey` (always required, non-optional)
   - `webIdentityProof` - absent for native clients

2. Client sends POST with `XFTPClientHandshake`:
   - `xftpVersion` - agreed version
   - `keyHash` - SHA256 of router's identity certificate

3. Server validates keyHash against `idCert` fingerprint (currently expects exactly 2-cert chain: `[leaf, ca]` where `ca` is identity)

**Web client handshake** (three-step with identity proof):

Web browsers cannot access the TLS certificate chain for verification. The web handshake adds a challenge-response mechanism:

1. Client sends POST with `xftp-web-hello: 1` header and `XFTPClientHello`:
   - `webChallenge` - optional 32-byte random challenge

2. Server responds with `XFTPServerHandshake`:
   - `webIdentityProof` - signature over `(webChallenge || sessionId)` using the router's signing key

3. Client verifies `webIdentityProof` using the public key from `authPubKey`, confirming server identity without needing TLS certificate access

4. Client sends POST with `xftp-handshake: 1` header and `XFTPClientHandshake` (same as native step 2)

The server tracks handshake state per `sessionId` in a `TMap SessionId Handshake`:
- `HandshakeSent pk` - hello received, awaiting client handshake
- `HandshakeAccepted thParams` - handshake complete, ready for commands

Web hello can be re-sent at any state (server reuses existing X25519 key if already generated). Block size is 16384 bytes (same as SMP).

### Block encryption setup (SMP only, v11+)

After the handshake DH agreement, both sides compute a shared `DhSecretX25519`. `blockEncryption` derives chain keys via `sbcInit`:

```
sbcInit sessionId dhSecret
  -> HKDF-SHA512(salt=sessionId, ikm=dhSecret, info="SimpleXSbChainInit", len=64)
  -> split into (sndChainKey, rcvChainKey)
```

Each block encryption advances the chain key:
```
sbcHkdf chainKey
  -> HKDF-SHA512(salt="", ikm=chainKey, info="SimpleXSbChain", len=88)
  -> split into (newChainKey[32], secretBoxKey[32], nonce[24])
```

The keys are used with XSalsa20-Poly1305 (NaCl secret_box), not AES.

This provides per-block forward secrecy - each block uses a different key, and old keys cannot be derived from new ones. The client swaps send/receive keys (its send key = server's receive key).

Block encryption is disabled when `proxyServer == True` (proxy connections already have their own encryption layer), when the version is below v11, or when no DH session secret is available (no `thAuth` or missing `sessSecret`).

---

## Block framing

**Source**: [Transport.hs](../../src/Simplex/Messaging/Transport.hs), [Protocol.hs](../../src/Simplex/Messaging/Protocol.hs)

### Block sizes

| Protocol | Block size | Effective payload |
|----------|-----------|-------------------|
| SMP | 16384 bytes | 16363 (single in batch) or 16382 (unbatched) |
| NTF | 512 bytes | 491 (single in batch) or 510 (unbatched) |
| XFTP | 16384 bytes | Same as SMP |

Batch overhead: 2 (pad) + 1 (count byte) + 16 (auth tag) + 2 (`Large` Word16 prefix per transmission) = 21 bytes for a single-item batch.

### Reading and writing blocks

`tPutBlock` pads the message to exactly `blockSize` bytes:
- **Without block encryption**: `C.pad` writes a 2-byte big-endian length prefix, then the message, then `'#'` characters to fill the block.
- **With block encryption** (v11+): `sbEncrypt` with the chain-derived key and nonce. The available payload is reduced by 16 bytes (Poly1305 auth tag).

`tGetBlock` reads exactly `blockSize` bytes and reverses the process. If the received data is not exactly `blockSize` bytes, an EOF error is raised.

### Batch format

When `batch` is enabled (SMP v4+, NTF v2+), multiple transmissions are packed into a single block:

1. One byte: transmission count (1-255)
2. Each transmission wrapped in `Large` encoding (fixed 2-byte Word16 length prefix + content)
3. Total size of all `Large`-encoded transmissions must fit in `blockSize - 19` bytes (2 pad + 1 count + 16 auth tag)

`batchTransmissions_` packs transmissions left-to-right into batches. When the next transmission would exceed the remaining space (or the count reaches 255), a new batch starts. Transmissions that individually exceed the batch limit produce a `TBError TELargeMsg`.

`tPut` encodes a list of transmissions into batches via `batchTransmissions`, then writes each batch as a separate block via `tPutBlock`. Results are collected per-transmission, not per-block.

---

## Transmission encoding and signing

**Source**: [Protocol.hs](../../src/Simplex/Messaging/Protocol.hs), [Client.hs](../../src/Simplex/Messaging/Client.hs)

### Wire format

`encodeTransmission_` produces the core transmission bytes:

```
corrId || entityId || encodedCommand
```

- `corrId`: variable-length correlation ID (empty for server-initiated pushes)
- `entityId`: queue/entity identifier
- `encodedCommand`: protocol-specific command encoding

### Session ID handling (`implySessId`)

For v7+ (`authCmdsSMPVersion`), `implySessId` is `True`. This affects how `sessionId` is used:

- **`tForAuth`** (what gets signed): always includes `sessionId` prefix
- **`tToSend`** (what goes on the wire): excludes `sessionId` when `implySessId == True`

This saves bandwidth - the session ID is implicit (both sides know it from the TLS handshake) but still covered by the signature, preventing session fixation attacks.

`tForAuth` is lazy (uses `~ByteString`) to avoid computing the signed representation when no signing key is present.

### Dual signature scheme

`authTransmission` produces `TAuthorizations` - a tuple of entity auth plus optional service signature:

**Entity auth** (always present when key provided):
- X25519 keys: `C.cbAuthenticate` using the server's public key, the per-queue private key, correlation nonce, and the signing content (see below)
- Ed25519/Ed448 keys: standard signature over the signing content

**Service auth** (v16+, when `serviceAuth == True` and `clientService` exists):
- The signing content becomes `serviceCertHash || tForAuth` (instead of plain `tForAuth`) - binding the service identity to the queue operation, preventing MITM service substitution within TLS
- Service session key additionally signs over `tForAuth` alone

Without active service auth, the signing content is `tForAuth` directly.

The dual signature ensures that even within a TLS session, an attacker cannot substitute a different service certificate without invalidating the entity key signature.

---

## Version negotiation

**Source**: [Version.hs](../../src/Simplex/Messaging/Version.hs), [Transport.hs](../../src/Simplex/Messaging/Transport.hs)

### Range intersection

`VersionRange` is an inclusive `(min, max)` pair with nominal typing per protocol (SMP, NTF, XFTP use distinct phantom types via `VersionScope`).

`compatibleVRange` computes the intersection of two ranges: `max(min1, min2)` to `min(max1, max2)`. Returns `Nothing` if the intersection is empty (no compatible version exists). The agreed version is the maximum of the intersection range.

`compatibleVRange'` caps a range by a single version (used when the peer advertises a specific maximum rather than a range).

### Version-gated features

Feature availability is controlled by version constants. Key SMP version gates:

| Version | Feature |
|---------|---------|
| v4 | Command batching |
| v7 | Authenticated encryption, implied session ID |
| v9 | SKEY for faster sender handshake |
| v11 | Block encryption with forward secrecy |
| v14 | `proxyServer` handshake property |
| v16 | Service certificates |
| v19 | Service subscriptions (SUBS/NSUBS) |

### Anti-fingerprinting version cap

`proxiedSMPRelayVersion` (v18) is the maximum version an SMP proxy advertises to destination routers. The proxy's actual version may be higher (currently v19), but by capping the proxied connection, clients behind the proxy cannot be fingerprinted by the destination router based on their SMP version. All proxied clients appear as v18 or below.

### Proxy version downgrade logic

When `smpClientHandshake` detects it is acting as a proxy (`proxyServer == True`) and the destination router's maximum version is below v14 (`proxyServerHandshakeSMPVersion`), it caps the negotiated range at v10 (`deletedEventSMPVersion`). This disables transport block encryption between proxy and relay - transport encryption at v11 would increase message size, breaking clients at v10 or earlier.

---

## Connection management

**Source**: [Client.hs](../../src/Simplex/Messaging/Client.hs), [Transport/KeepAlive.hs](../../src/Simplex/Messaging/Transport/KeepAlive.hs)

### Four concurrent threads

Each protocol client connection runs four concurrent threads via `raceAny_` - if any thread exits, all are cancelled and the disconnect handler fires:

**send**: reads `(Maybe Request, ByteString)` tuples from `sndQ` (bounded `TBQueue`). For requests with a `responseVar`, checks the `pending` flag before sending (a cancelled request is silently skipped). Transport errors on write are delivered to the waiting `responseVar`.

**receive**: calls `tGetClient` in a loop to read and parse blocks. Updates `lastReceived` timestamp and resets `timeoutErrorCount` to 0 on each successful read.

**process**: reads parsed transmissions from `rcvQ` and classifies each by correlation ID:
- Empty corrId: server-initiated push - forwarded to `msgQ` as `STEvent` (any response with empty corrId is classified this way; typical types are MSG, END, DELD, ENDS)
- Matching pending command: response - delivered to the command's `responseVar`
- No matching command: forwarded to `msgQ` as `STUnexpectedError`

**monitor** (optional, disabled when `smpPingInterval == 0`): sends application-level PING when the connection is idle for `smpPingInterval` (default 600 seconds / 10 minutes), but only after `sendPings` is explicitly enabled by the caller. Tracks consecutive timeout errors via `timeoutErrorCount`. Drops the client after `smpPingCount` (default 3) consecutive timeouts, but only if at least 15 minutes have passed since the last received response (recovery window).

### TCP keep-alive

`defaultKeepAliveOpts` configures OS-level TCP keep-alive probes:

| Parameter | Value | Socket option |
|-----------|-------|---------------|
| `keepIdle` | 30 seconds | TCP_KEEPIDLE (Linux) / TCP_KEEPALIVE (macOS) |
| `keepIntvl` | 15 seconds | TCP_KEEPINTVL |
| `keepCnt` | 4 probes | TCP_KEEPCNT |

TCP keep-alive detects dead connections at the OS level. The application-level PING/PONG provides a higher-level liveness check that also validates the protocol layer.

### Disconnect and teardown

All four threads run inside `raceAny_` with `E.finally disconnected`. When any thread exits (network error, timeout, or protocol error), the `finally` handler:

1. Fires the `disconnected` callback provided by the caller (e.g., `smpClientDisconnected` in the agent)
2. The agent callback demotes subscriptions, fires DOWN events, and initiates resubscription

The `connected` TVar is set to `True` after the handshake succeeds and before the threads start. Note: in the protocol client, this TVar is not reset on disconnect - disconnect detection relies on thread cancellation via `raceAny_` and the `disconnected` callback, not STM re-evaluation. (The server-side `Client` type has a separate `connected` TVar that is reset in `clientDisconnected`.)
