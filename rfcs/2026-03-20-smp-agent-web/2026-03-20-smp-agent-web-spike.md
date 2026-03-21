# SMP Agent Web: Spike Plan

Revision 4, 2026-03-20

Parent RFC: [2026-03-20-smp-agent-web.md](../2026-03-20-smp-agent-web.md)

## Revision History

- **Rev 4**: Aligned with RFC. Restructured as bottom-up build plan with per-function Haskell tests. Router WebSocket support done. File structure mirrors Haskell modules.
- **Rev 3**: Fixed multiple encoding errors discovered during audit (see encoding details below).

## Objective

Fetch and display business/contact profile from a SimpleX short link URI, via WebSocket to SMP router. This is the first milestone of the SMP agent web implementation — it proves the protocol encoding, transport, crypto, and data parsing layers work end-to-end.

The spike is not throwaway code. It is the beginning of the `smp-web/` TypeScript library, built bottom-up with each function tested against its Haskell counterpart.

## What This Proves

- WebSocket transport to SMP router works from browser
- SMP protocol encoding is correct (binary format, not ASCII)
- SMP handshake works (version negotiation, server certificate parsing)
- Crypto is compatible (HKDF-SHA512, XSalsa20-Poly1305)
- Short link data parsing matches Haskell (FixedLinkData, ConnLinkData, profile)

## Success Criteria

Haskell test creates a short link, TypeScript fetches and decodes it via WebSocket, profile data matches.

## Protocol Flow

```
1. Parse short link URI
   https://simplex.chat/c#<linkKey>?h=hosts&p=port&c=keyHash
   → server, linkKey

2. Derive keys (HKDF-SHA512)
   linkKey → (linkId, sbKey)

3. WebSocket connect
   wss://server:443 (TLS handled by browser)

4. SMP handshake
   ← SMPServerHandshake {sessionId, smpVersionRange, authPubKey}
   → SMPClientHandshake {smpVersion, keyHash, authPubKey=Nothing, proxyServer=False, clientService=Nothing}

5. Send LGET
   → [empty auth][corrId][linkId]["LGET"]

6. Receive LNK
   ← [auth][corrId][linkId]["LNK" space senderId encFixedData encUserData]

7. Decrypt
   XSalsa20-Poly1305 with sbKey
   → FixedLinkData, ConnLinkData (with profile JSON)

8. Display profile
```

Note: spike sends `authPubKey=Nothing` so block encryption is not used (blocks are padded only). Block encryption is added in steps 12-13.


## Build Approach

Bottom-up, function-by-function. Each TypeScript function tested against its Haskell counterpart via `callNode` — the same pattern used in xftp-web (see `XFTPWebTests.hs`).

**Project location**: `simplexmq-2/smp-web/`
**Tests**: `simplexmq-2/tests/SMPWebTests.hs` — reuses `callNode`/`jsOut`/`jsUint8` from XFTPWebTests (generalized, not copied)
**xftp-web**: npm dependency (encoding, crypto, padding imported directly)
**File structure**: mirrors Haskell module hierarchy (see RFC section 2)

**Pattern for each function**:
1. Check if xftp-web already implements it (or something close). If so, import and reuse — export from xftp-web if not yet exported. Only write new code when no existing implementation covers the need.
2. Implement in TypeScript, in the file corresponding to its Haskell module
3. Write Haskell test that calls it via `callNode`
4. Compare output byte-for-byte with Haskell reference
5. Cross-language: Haskell encodes → TypeScript decodes, and vice versa

### Parsing Approach

All binary parsing uses xftp-web's `Decoder` class — the same class, not a copy. `Decoder` tracks position over a `Uint8Array`, throws on malformed input, returns subarray views (zero-copy).

SMP command parsing follows the same pattern as xftp-web's `decodeResponse` in `commands.ts`: `readTag` reads bytes until space or end, switch dispatches on the tag string, fields are parsed sequentially with `Decoder` methods (`decodeBytes`, `decodeLarge`, `decodeBool`, etc.).

**Prerequisite xftp-web change**: `readTag` and `readSpace` in xftp-web's `commands.ts` need to be exported so smp-web can import them.

### WebSocket Transport Approach

WebSocket transport follows the simplexmq-js `WSTransport` pattern:

- `WebSocket` connects to `wss://` URL with `binaryType = 'arraybuffer'`
- `onmessage` enqueues received frames into an `ABQueue` (async bounded queue with backpressure)
- `onclose` closes the queue (sentinel-based)
- `readBlock()` dequeues one frame, validates it is exactly 16384 bytes
- `sendBlock(data)` sends one 16384-byte binary frame

The `ABQueue` class from simplexmq-js provides backpressure via semaphores and clean async iteration. It can be included in smp-web or extracted as a shared utility.

The SMP transport layer wraps WebSocket transport:
- Receives raw blocks → unpad → parse transmission
- Encodes transmission → pad → send as block
- After handshake, if block encryption is active: decrypt before unpad, encrypt after pad


## Encoding Reference

Binary encoding rules (from `Simplex.Messaging.Encoding`):

| Type | Format |
|------|--------|
| `Word16` | 2 bytes big-endian |
| `Word32` | 4 bytes big-endian |
| `ByteString` | 1-byte length + bytes (max 255) |
| `Large` | 2-byte length (BE) + bytes (max 65535) |
| `Bool` | 'T' (0x54) or 'F' (0x46) |
| `Maybe a` | '0' (0x30) for Nothing, '1' (0x31) + value for Just |
| `smpEncodeList` | 1-byte count + items |
| `UserLinkData` | ByteString if ≤254 bytes, else 0xFF + Large |

**Critical**: `encodeAuthEncryptCmds Nothing` = empty (0 bytes), NOT 'F' or '0'.

**Transmission format** (binary, NOT ASCII with spaces):
```
[auth ByteString][corrId ByteString][entityId ByteString][command bytes]
```

For v7+ (`implySessId = True`): sessionId is NOT sent on wire, but is prepended to the `authorized` data for signature verification. For unauthenticated commands (LGET), this doesn't apply.

**Block framing**: `pad(transmission, 16384)` = `[2-byte BE length][message][padding with '#' (0x23)]`


## Server Changes — DONE

WebSocket support on the same port as native TLS is implemented and tested.

- `attachStaticAndWS` — unified HTTP + WebSocket handler via `wai-websockets`
- SNI routing: browser (SNI) → Warp → WebSocket upgrade → SMP over WS
- `acceptWSConnection` — constructs `WS 'TServer` from `TLS 'TServer` + PendingConnection
- Test: `testWebSocketAndTLS` in `ServerTests.hs`

**Remaining**: CORS headers for cross-origin widget embedding.


## Implementation Steps

Each step produces working, tested code. Steps 1-11 work without block encryption. Steps 12-13 add it.

### Step 1: Project Setup + xftp-web Changes

**smp-web setup**:
- Create `smp-web/` with `package.json` (xftp-web + `@noble/hashes` as dependencies), `tsconfig.json` (ES2022, strict, same as xftp-web)
- Build: `tsc` → `dist/`

**xftp-web change**:
- Export `readTag` and `readSpace` from `commands.ts` (currently unexported) so smp-web can import them

**Test infrastructure**:
- Create `SMPWebTests.hs`, reusing `callNode`/`jsOut`/`jsUint8` from XFTPWebTests (generalize shared utilities into a common test module, not copy)
- First test: import `decodeBytes` from xftp-web, encode a ByteString, verify output matches Haskell `smpEncode`

### Step 2: SMP Transmission Encode/Decode

**File**: `protocol.ts`
**Haskell reference**: `Simplex.Messaging.Protocol` — `encodeTransmission_`, `transmissionP`

**Implementation**:
- `encodeTransmission(corrId, entityId, command)`: `concatBytes(encodeBytes(emptyAuth), encodeBytes(corrId), encodeBytes(entityId), command)` — unsigned, empty auth byte (0x00)
- `decodeTransmission(data)`: sequential Decoder — `decodeBytes` for auth, corrId, entityId, then `takeAll` for command bytes
- Pad/unpad: reuse xftp-web `blockPad`/`blockUnpad` (same 2-byte length prefix + '#' padding, same 16384 block size)

**Tests**: encode in TypeScript → decode in Haskell (`transmissionP`), encode in Haskell (`encodeTransmission_`) → decode in TypeScript. Byte-for-byte match.

### Step 3: SMP Handshake Parse/Encode

**File**: `transport.ts`
**Haskell reference**: `Simplex.Messaging.Transport` — `SMPServerHandshake`, `SMPClientHandshake`

**Implementation**:
- `parseSMPServerHandshake(d: Decoder)`: `decodeWord16` × 2 for versionRange, `decodeBytes` for sessionId. For authPubKey: if `maxVersion >= 7` and bytes remaining, parse `CertChainPubKey` (reuse xftp-web `identity.ts` for X.509 cert chain parsing and signature extraction). If no bytes remain, authPubKey is absent (encodeAuthEncryptCmds encoded Nothing as empty).
- `encodeSMPClientHandshake(...)`: `concatBytes(encodeWord16(version), encodeBytes(keyHash), authPubKeyBytes, encodeBool(proxyServer), encodeMaybe(encodeService, clientService))`. Where authPubKey: empty bytes for Nothing, `encodeBytes(pubkey)` for Just. proxyServer only for v14+, clientService only for v16+.

**Tests**: Haskell encodes `SMPServerHandshake` → TypeScript parses, all fields match. TypeScript encodes `SMPClientHandshake` → Haskell parses via `smpP`.

### Step 4: LGET Command Encode

**File**: `protocol.ts`
**Haskell reference**: `Simplex.Messaging.Protocol` — `LGET` command encoding

**Implementation**:
- `encodeLGET()`: returns `ascii("LGET")` — 4 bytes, no parameters. The LinkId is carried as entityId in the transmission (step 2), not in the command body.
- Full LGET block: `blockPad(encodeTransmission(corrId, linkId, encodeLGET()), 16384)`

**Tests**: encode full LGET block in TypeScript, Haskell unpad + `transmissionP` + `parseProtocol` decodes as `LGET` with correct corrId and linkId.

### Step 5: LNK Response Parse

**File**: `protocol.ts`
**Haskell reference**: `Simplex.Messaging.Protocol` — `LNK` response encoding (line 1834)

**Implementation**:
- `decodeResponse(d: Decoder)`: `readTag(d)` → switch dispatch (same pattern as xftp-web `decodeResponse`)
- For `"LNK"`: `readSpace(d)`, `decodeBytes(d)` for senderId, `decodeLarge(d)` for encFixedData, `decodeLarge(d)` for encUserData
- Also handle `"ERR"` responses for error reporting

**Tests**: Haskell encodes `LNK senderId (encFixed, encUser)` → TypeScript `decodeResponse` parses. All fields match byte-for-byte.

### Step 6: Short Link URI Parse

**File**: `agent/protocol.ts`
**Haskell reference**: `Simplex.Messaging.Agent.Protocol` — `ConnShortLink` StrEncoding instance (lines 1599-1612)

**Implementation**:
- `parseShortLink(uri)`: regex to extract scheme (https/simplex), type char (c/g/a), linkKey (base64url, 43 chars → 32 bytes), query params (h=hosts, p=port, c=keyHash)
- `base64UrlDecode(s)`: pad to multiple of 4, replace `-`→`+`, `_`→`/`, decode
- Returns `{scheme, connType, server: {hosts, port, keyHash}, linkKey}`

**Tests**: Haskell `strEncode` a `ConnShortLink` → TypeScript `parseShortLink` parses. All fields match. Test multiple formats: with/without query params, different type chars.

### Step 7: HKDF Key Derivation

**File**: `crypto/shortLink.ts`
**Haskell reference**: `Simplex.Messaging.Crypto.ShortLink` — `contactShortLinkKdf` (line 48)

**Implementation**:
- `contactShortLinkKdf(linkKey)`: `hkdf(sha512, linkKey, new Uint8Array(0), "SimpleXContactLink", 56)` using `@noble/hashes/hkdf` + `@noble/hashes/sha512`. Split result: first 24 bytes = linkId, remaining 32 bytes = sbKey.

**Note**: Haskell `C.hkdf` uses SHA-512, not SHA3-256.

**Tests**: given known linkKey bytes, TypeScript and Haskell produce identical linkId and sbKey.

### Step 8: Link Data Decrypt

**File**: `crypto/shortLink.ts`
**Haskell reference**: `Simplex.Messaging.Crypto.ShortLink` — `decryptLinkData` (lines 100-120)

**Implementation**:
- `decryptLinkData(sbKey, encFixedData, encUserData)`:
  1. For each EncDataBytes: `Decoder` → `decodeBytes(d)` for nonce (24 bytes), `decodeTail(d)` for ciphertext (includes Poly1305 tag)
  2. `cbDecrypt(sbKey, nonce, ciphertext)` via xftp-web `secretbox.ts`
  3. From decrypted plaintext: `decodeBytes(d)` for signature (1-byte len 0x40 + 64 bytes), `decodeTail(d)` for actual data
  4. Return both plaintext data blobs (signature verification skipped for spike)

**Tests**: Haskell `encodeSignLinkData` + `sbEncrypt` with known key/nonce → TypeScript decrypts → plaintext matches.

### Step 9: FixedLinkData / ConnLinkData Parse

**File**: `agent/protocol.ts`
**Haskell reference**: `Simplex.Messaging.Agent.Protocol` — `FixedLinkData`, `ConnLinkData`, `UserContactData` Encoding instances

**Implementation**:
- `decodeFixedLinkData(d)`: `decodeWord16` × 2 for agentVRange, `decodeBytes` for rootKey (32 bytes Ed25519), `decodeLarge` for linkConnReq, optional `decodeBytes` for linkEntityId (if bytes remaining)
- `decodeConnLinkData(d)`: `anyByte` for connectionMode ('C'=Contact), `decodeWord16` × 2 for agentVRange, then `decodeUserContactData`
- `decodeUserContactData(d)`: `decodeBool` for direct, `decodeList(decodeOwnerAuth, d)` for owners, `decodeList(decodeConnShortLink, d)` for relays, `decodeUserLinkData(d)` for userData
- `decodeUserLinkData(d)`: peek first byte — if 0xFF, skip it and `decodeLarge(d)`; otherwise `decodeBytes(d)`
- `parseProfile(userData)`: check first byte for 'X' (0x58, zstd compressed) — if so, decompress; otherwise `JSON.parse` directly

**Tests**: Haskell encodes full `FixedLinkData` and `ContactLinkData` with known values → TypeScript decodes → all fields match.

### Step 10: WebSocket Transport

**File**: `transport/websockets.ts`
**Pattern reference**: simplexmq-js `WSTransport` + `ABQueue`

**Implementation**:
- `ABQueue<T>` class: semaphore-based async bounded queue (from simplexmq-js `queue.ts` — reimplement or include as utility). `enqueue`/`dequeue`/`close`, sentinel-based close, async iterator.
- `connectWS(url)`: `new WebSocket(url)`, `binaryType = 'arraybuffer'`, `onmessage` enqueues `Uint8Array` frames into ABQueue, `onclose` closes queue, `onerror` closes socket. Returns transport handle on `onopen`.
- `readBlock(transport)`: dequeue one frame, verify `byteLength === 16384`, return `Uint8Array`
- `sendBlock(transport, data)`: `ws.send(data)`, verify `data.length === 16384`
- `smpHandshake(transport, keyHash)`: `readBlock` → `blockUnpad` → `parseSMPServerHandshake` → negotiate version → `encodeSMPClientHandshake` → `blockPad` → `sendBlock`. Returns `{sessionId, version}`.

**Integration test**: spawn test SMP server with web credentials (reuse `cfgWebOn` from SMPClient.hs), connect via WebSocket from Node.js, complete handshake, verify sessionId received.

### Step 11: End-to-End Integration

Wire steps 6-10 together: `parseShortLink` → `contactShortLinkKdf` → `connectWS` → `smpHandshake` → encode LGET block → `sendBlock` → `readBlock` → `blockUnpad` → `decodeTransmission` → `decodeResponse` → `decryptLinkData` → `decodeFixedLinkData` + `decodeConnLinkData` → `parseProfile`.

**Test**: Haskell creates a contact address with short link (using agent), TypeScript fetches and decodes it via WebSocket. Profile displayName matches. This is the full spike proof: browser can fetch a SimpleX contact profile via SMP protocol.

### Step 12: Block Encryption (DH + SbChainKeys)

**File**: `transport.ts`
**Haskell reference**: `Simplex.Messaging.Crypto` — `sbcInit`, `sbcHkdf`; `Simplex.Messaging.Transport` — `tPutBlock`, `tGetBlock`

**Implementation**:
- `generateX25519KeyPair()`, `dh(peerPub, ownPriv)` — reuse from xftp-web `keys.ts`
- `sbcInit(sessionId, dhSecret)`: `hkdf(sha512, dhSecret, sessionId, "SimpleXSbChainInit", 64)` → split at 32: `(sndChainKey, rcvChainKey)`. Note client swaps send/receive keys vs server (line 858 Transport.hs).
- `sbcHkdf(chainKey)`: `hkdf(sha512, chainKey, "", "SimpleXSbChain", 88)` → split: 32 bytes new chainKey, 32 bytes sbKey, 24 bytes nonce. Returns `{sbKey, nonce, nextChainKey}`.
- `encryptBlock(state, block)`: `sbcHkdf` → `cryptoBox(sbKey, nonce, pad(block, blockSize - 16))` → 16-byte tag + ciphertext
- `decryptBlock(state, block)`: `sbcHkdf` → split tag (first 16 bytes) + ciphertext → `cryptoBoxOpen` → `unpad`

**Tests**: Haskell and TypeScript DH with same keys → identical chain keys. Haskell encrypts block → TypeScript decrypts (and vice versa). Chain key advances identically after each block.

### Step 13: Full Handshake with Auth

**File**: `transport.ts`
**Haskell reference**: `Simplex.Messaging.Transport` — `smpClientHandshake` (lines 792-842)

**Implementation**:
- Update `smpHandshake` to generate ephemeral X25519 keypair and include public key in `encodeSMPClientHandshake` as authPubKey
- Parse server's `CertChainPubKey` from handshake: extract DH public key, verify X.509 certificate chain (reuse xftp-web `identity.ts` — `verifyIdentityProof`, `extractCertPublicKeyInfo`)
- Compute DH: `dh(serverDhPub, clientPrivKey)` → shared secret
- `sbcInit(sessionId, dhSecret)` → chain keys (with client-side swap)
- All subsequent `readBlock`/`sendBlock` go through `decryptBlock`/`encryptBlock`

**Tests**: full handshake with real server, block encryption active, exchange encrypted commands. Haskell sends encrypted response → TypeScript decrypts correctly.


## Haskell Code References

### Handshake
- `Simplex.Messaging.Transport` — `smpClientHandshake`, `smpServerHandshake`, `SMPServerHandshake`, `SMPClientHandshake`
- `encodeAuthEncryptCmds` — Nothing → empty, Just → raw smpEncode

### Protocol
- `Simplex.Messaging.Protocol` — `LGET`, `LNK`, `encodeTransmission_`, `transmissionP`
- Block: `pad`/`unPad` in `Simplex.Messaging.Crypto`

### Short Links
- `Simplex.Messaging.Crypto.ShortLink` — `contactShortLinkKdf`, `decryptLinkData`
- `Simplex.Messaging.Agent.Protocol` — `ConnShortLink`, `FixedLinkData`, `ConnLinkData`, `UserLinkData`

### Block Encryption
- `Simplex.Messaging.Crypto` — `sbcInit`, `sbcHkdf`, `sbEncrypt`, `sbDecrypt`, `dh'`
- `Simplex.Messaging.Transport` — `blockEncryption`, `TSbChainKeys`, `tPutBlock`, `tGetBlock`
