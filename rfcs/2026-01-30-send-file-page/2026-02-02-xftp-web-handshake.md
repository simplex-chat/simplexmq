# Web Handshake — Challenge-Response Identity Proof

RFC §6.3: Server proves XFTP identity to web clients independently of TLS CA infrastructure.

## 1. Protocol

**Standard handshake** (unchanged):
```
Client → empty POST                                        → Server
Server → padded {vRange, sessionId, authPubKey, Nothing}    → Client
Client → padded {version, keyHash, Nothing}                 → Server
Server → empty                                              → Client
```

**Web handshake** (SNI connection, non-empty hello):
```
Client → padded {32 random bytes}                                → Server
Server → padded {vRange, sessionId, authPubKey, Just sigBytes}   → Client
  sigBytes = signatureBytes(sign(identityLeafKey, challenge <> sessionId))
Client validates:
  1. chainIdCaCerts(authPubKey.certChain) → CCValid {leafCert, idCert}
  2. SHA-256(idCert) == keyHash   (server identity)
  3. verify(leafCert.pubKey, sigBytes, challenge <> sessionId)  (challenge-response)
  4. verify(leafCert.pubKey, signedPubKey.signature, signedPubKey.objectDer)  (DH key auth)
Client → padded {version, keyHash, Just challenge}               → Server
Server verifies: echoed challenge == stored challenge from step 1
Server → empty                                                   → Client
```

**Detection**: `sniUsed` per-connection flag. Non-empty hello allowed only when `sniUsed`. Empty hello with SNI → standard handshake.

**Why both steps 3 and 4**: Native clients verify `signedPubKey` using the TLS peer certificate (`serverKey` from `getServerVerifyKey`), which is the XFTP identity cert in non-SNI connections — TLS provides this binding. Web clients cannot access TLS peer certificate data (browser API limitation; TLS presents the web CA cert but provides no API to extract it). So web clients must verify at the application layer using `authPubKey.certChain`, which always contains the XFTP identity chain regardless of which cert TLS used. Step 3 proves the server holds its identity key *right now* (freshness via random challenge). Step 4 proves the DH session key was signed by the identity key holder (prevents MITM key substitution). Together they give web clients some assurance native clients get from TLS, except channel binding for commands.

## 2. Type Changes — `src/Simplex/FileTransfer/Transport.hs`

### `XFTPServerHandshake` (line 114)

Add field: `webIdentityProof :: Maybe ByteString` — raw Ed448 signature bytes (114 bytes), or `Nothing` for standard handshake. No record needed — the cert chain is already in `authPubKey.certChain`.

### `Encoding XFTPServerHandshake` (line 136)

- `smpEncode`: append `smpEncode webIdentityProof`
- `smpP`: `Tail compat`, if non-empty `eitherToMaybe $ smpDecode compat`

Backward compat: old clients ignore via `Tail _compat`; new client + old server → empty compat → `Nothing`.

### `XFTPClientHandshake` (line 121)

Add field: `webChallenge :: Maybe ByteString`

### `Encoding XFTPClientHandshake` (line 128)

Same `Tail compat` pattern as server handshake.

### Export list

Both types use `(..)` export — new fields auto-exported.

## 3. Server Changes — `src/Simplex/FileTransfer/Server.hs`

### `XFTPTransportRequest` (line 88)

Add field: `sniUsed :: SNICredentialUsed` (`Bool` from `Transport.Server`). Add import.

### `Handshake` (line 117)

`HandshakeSent C.PrivateKeyX25519` → `HandshakeSent C.PrivateKeyX25519 (Maybe ByteString)` — stores 32-byte web challenge or `Nothing`.

### `runServer` handler (line 145–161)

- Pass `sniUsed` into request construction (line 154)
- SNI-first routing: when `sniUsed`, always route to `xftpServerHandshakeV1` (web ALPN `h2` would otherwise fall to `_` catch-all)

### `xftpServerHandshakeV1` (line 162)

- Destructure `sniUsed` from request
- Match `HandshakeSent pk challenge_` → `processClientHandshake pk challenge_`

### `processHello` (line 171)

- Branch `(sniUsed, B.null bodyHead)`:
  - `(_, True)` → standard: `challenge_ = Nothing`
  - `(True, False)` → web: unpad, verify 32 bytes, `challenge_ = Just`
  - `(False, False)` → `throwE HANDSHAKE`
- Store: `HandshakeSent pk challenge_`
- Compute: `webIdentityProof = C.signatureBytes . C.sign serverSignKey . (<> sessionId) <$> challenge_`
- Construct `XFTPServerHandshake` with `webIdentityProof`

### `processClientHandshake` (line 183)

- Accept `challenge_` parameter
- Decode `webChallenge` from `XFTPClientHandshake`
- Add: `unless (challenge_ == webChallenge) $ throwE HANDSHAKE`
  (standard: both `Nothing` → passes)

## 4. Native Client — `src/Simplex/FileTransfer/Client.hs`

### `xftpClientHandshakeV1` (line 142)

Add `webChallenge = Nothing` in `sendClientHandshake` call.

No other changes — parser handles new fields via `Tail`, native client ignores `webIdentityProof`.

## 5. TypeScript Changes (DONE except Ed448)

Sections 5.1 and 5.2 are implemented. Section 5.3 needs Ed448 support.

## 10. Ed448 Support via `@noble/curves`

**Problem**: Production servers use Ed448 certificates (default). `identity.ts` only supports Ed25519 via libsodium. libsodium has no Ed448 support and never will.

**Solution**: Add `@noble/curves` dependency for Ed448 verification only. All other crypto stays with libsodium.

### 10.1 `xftp-web/package.json` — Add dependency

```json
"dependencies": {
  "libsodium-wrappers-sumo": "^0.7.13",
  "@noble/curves": "^1.9.7"
}
```

Use v1.x (supports both CJS and ESM). v2.x is ESM-only with `.js` extension requirement.

### 10.2 `xftp-web/src/crypto/keys.ts` — Ed448 DER constants and decode

Add Ed448 SPKI DER prefix (12 bytes, same prefix length as Ed25519):
```
30 43 30 05 06 03 2b 65 71 03 3a 00
```

| Property | Ed25519 | Ed448 |
|----------|---------|-------|
| OID | `2b 65 70` | `2b 65 71` |
| SPKI prefix | `30 2a ...` | `30 43 ...` |
| Raw key size | 32 bytes | 57 bytes |
| SPKI total | 44 bytes | 69 bytes |
| Signature size | 64 bytes | 114 bytes |

New functions:
- `decodePubKeyEd448(der: Uint8Array): Uint8Array` — 69 bytes → 57 bytes raw
- `encodePubKeyEd448(raw: Uint8Array): Uint8Array` — 57 bytes → 69 bytes DER
- `verifyEd448(publicKey: Uint8Array, sig: Uint8Array, msg: Uint8Array): boolean` — uses `ed448.verify(sig, msg, publicKey)` from `@noble/curves/ed448`

Note: `@noble/curves` parameter order is `(signature, message, publicKey)`, not `(publicKey, signature, message)`.

### 10.3 `xftp-web/src/crypto/identity.ts` — Algorithm-agnostic verification

Replace `extractCertEd25519Key` + hardcoded Ed25519 `verify` with algorithm detection:

1. `extractCertPublicKeyInfo(certDer)` → SPKI DER (already exists, works for any algorithm)
2. Detect algorithm from SPKI: byte at offset 8 is `0x70` (Ed25519) or `0x71` (Ed448)
3. Extract raw key with appropriate decoder
4. Verify signatures with appropriate function

```typescript
type CertKeyAlgorithm = 'ed25519' | 'ed448'

function detectKeyAlgorithm(spki: Uint8Array): CertKeyAlgorithm {
  if (spki.length === 44 && spki[8] === 0x70) return 'ed25519'
  if (spki.length === 69 && spki[8] === 0x71) return 'ed448'
  throw new Error("unsupported certificate key algorithm")
}
```

`verifyIdentityProof` changes:
- Extract SPKI from leaf cert
- Detect algorithm → choose `decodePubKeyEd25519`/`decodePubKeyEd448` and `verify`/`verifyEd448`
- Both challenge signature and DH key signature use the same leaf key + algorithm

Remove `extractCertEd25519Key` (replaced by generic path). Keep `extractCertPublicKeyInfo` (already generic).

### 10.4 `xftp-web/src/protocol/handshake.ts` — Comment update

`SignedKey.signature` comment: "raw Ed25519 signature bytes (64 bytes)" → "raw signature bytes (Ed25519: 64, Ed448: 114)"

### 10.5 Tests — `tests/XFTPWebTests.hs`

**Integration test**: Switch from `withXFTPServerEd25519SNI` (Ed25519 fixtures) to `withXFTPServerSNI` (default Ed448 fixtures). Update fingerprint source from `tests/fixtures/ed25519/ca.crt` to `tests/fixtures/ca.crt`.

Optionally add a second integration test with Ed25519 to cover both paths, or rely on existing unit tests for Ed25519 coverage.

### 10.6 Implementation order

1. `npm install @noble/curves` in `xftp-web/`
2. `keys.ts` — Ed448 constants, decode, encode, verifyEd448
3. `identity.ts` — algorithm detection, generic verification
4. `handshake.ts` — comment fix
5. `XFTPWebTests.hs` — switch integration test to Ed448
6. Build TS + run all tests

## 6. Haskell Integration Test — `tests/XFTPServerTests.hs`

Add `testWebHandshake` to "XFTP SNI and CORS" describe block.

1. `withXFTPServerSNI` — server with web credentials
2. Connect with SNI + `h2` ALPN
3. Send padded 32-byte challenge
4. Decode `XFTPServerHandshake`, assert `webIdentityProof` is `Just`
5. `chainIdCaCerts` on `authPubKey.certChain` → `CCValid {leafCert, idCert}`
6. Verify `SHA-256(idCert) == keyHash`
7. Extract `leafCert` public key, verify challenge signature
8. Verify `signedPubKey` signature using `leafCert` key (DH key auth)
9. Send `XFTPClientHandshake` with `webChallenge = Just challenge`
10. Assert empty response

Imports: `XFTPServerHandshake (..)`, `XFTPClientHandshake (..)`, `ChainCertificates (..)`, `chainIdCaCerts`.

## 7. TS Tests — `tests/XFTPWebTests.hs`

### Unit tests

- **`decodeServerHandshake` with proof**: Haskell-encode with `Just sigBytes`, TS-decode, verify bytes match.
- **`encodeClientHandshake` with challenge**: TS-encode, compare with Haskell-encoded.
- **`chainIdCaCerts`**: 2/3/4-cert chains return correct positions.
- **`caFingerprint` (fixed)**: matches `sha256(idCert)` for 2 and 3-cert chains.

### Integration test

Node.js inline script against `withXFTPServerSNI`:
1. Connect with SNI via `http2.connect`
2. Send padded challenge, decode `XFTPServerHandshake` with TS
3. `verifyIdentityProof` — full chain validation + challenge sig + DH key sig
4. Send client handshake with echoed challenge
5. Assert empty response

## 8. Implementation Order

1. `Transport.hs` — `Maybe` fields + encoding instances
2. `Server.hs` — `sniUsed`, challenge in `Handshake`, `processHello`, `processClientHandshake`, SNI routing
3. `Client.hs` — `webChallenge = Nothing`
4. Build: `cabal build --ghc-options -O0`
5. Run existing SNI/CORS tests
6. `XFTPServerTests.hs` — `testWebHandshake`
7. `handshake.ts` — types, decoding, `chainIdCaCerts`, fix `caFingerprint`
8. `crypto/identity.ts` — Node.js verification functions
9. `XFTPWebTests.hs` — unit + integration tests
10. Build TS + run all tests

## 9. Verification

```bash
cd xftp-web && npm install && npm run build && cd ..
cabal test --ghc-options=-O0 --test-option='--match=/XFTP/XFTP server/XFTP SNI and CORS/' --test-show-details=streaming
cabal test --ghc-options=-O0 --test-option='--match=/XFTP Web Client/' --test-show-details=streaming
```
