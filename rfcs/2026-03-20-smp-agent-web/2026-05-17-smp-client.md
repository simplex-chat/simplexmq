# SMP Client for Browser

**Parent**: [SMP Agent Web Spike](./2026-03-20-smp-agent-web-spike.md)
**Depends on**: Spike 1 (merged) — transport, ratchet, encoding, per-queue E2E

## Context

The encoding spike proved all four encryption layers work cross-language. The next implementable and testable piece is the SMP client — the layer that sends commands, correlates responses by CorrId, authenticates with entity keys, and exposes typed async functions.

Faithful transpilation of `Simplex.Messaging.Client` (Client.hs). Transport is WebSocket (already working), protocol logic is identical to Haskell.

## Encoding path (per command)

Traced from `sendSMPMessage` through every function call:

```
1. encodeTransmission_(v, (corrId, entityId, command))
   → smpEncode(corrId, entityId) <> encodeProtocol(v, cmd)
   Already have as encodeTransmission() in protocol.ts — update in place

2. encodeTransmissionForAuth(thParams, transmission)
   → tForAuth = smpEncode(sessionId) <> encodeTransmission_(...)
   → tToSend = encodeTransmission_(...)  [when implySessId=true, which is always true for v>=7]
   Note: implySessId means tToSend omits sessionId, but tForAuth includes it (for signing)

3. authTransmission(thAuth, serviceAuth=false, maybePrivKey, nonce, tForAuth)
   → thAuth contains serverPubKey (X25519) from handshake
   → maybePrivKey is Nothing for unauthenticated commands (LGET, SEND without key)
   → Nothing privKey: no auth, encode empty ByteString
   → Just X25519 privKey: TAAuthenticator(cbAuthenticate(serverPubKey, privKey, nonce, tForAuth))
   → Just Ed25519 privKey: TASignature(sign(privKey, tForAuth))
   Note: nonce IS the CorrId (same 24 bytes used for both)
   Note: serviceAuth is always false for browser client (no service certificates)

4. tEncodeAuth(serviceAuth=false, maybeAuth)
   → Nothing: smpEncode("")  [1-byte 0x00]
   → Just (TAAuthenticator s, _): smpEncode(s)  [1-byte len + 80 bytes]
   → Just (TASignature sig, _): smpEncode(signatureBytes sig)  [1-byte len + 64 bytes]
   Note: TAuthorizations = (TransmissionAuth, Maybe serviceSig) — serviceSig always Nothing for us

5. tEncode(serviceAuth, (auth, tToSend))
   → tEncodeAuth(auth) <> tToSend

6. tEncodeBatch1(serviceAuth, sentRawTransmission)
   → lenEncode(1) + smpEncode(Large(tEncode(...)))
   Single-command batch. Always used when batch=true (v7+).

7. batchTransmissions_(blockSize, transmissions)
   → Pack multiple Large-wrapped transmissions into ≤blockSize blocks
   → Count byte prefix, up to 255 per block
   → blockSize' = blockSize - 19 (2 pad + 1 count + 16 auth tag)
```

## Parsing path (per received block)

```
1. tParse(thParams, blockBytes)
   → batch=true: parse count byte, then N Large-wrapped transmissions
   → Each: transmissionP(thParams) parses:
     - authenticator (ByteString, 1-byte len + data) — ignored by client
     - rest = authorized bytes
     - re-parse authorized: corrId (ByteString) + entityId (ByteString) + command (rest)
     - if implySessId=true: sessionId not in wire format, prepended from thParams for verification
   → Returns RawTransmission{authenticator, corrId, entityId, command}

2. tDecodeClient(thParams, rawTransmission)
   → Verify sessId matches (skipped when implySessId=true)
   → parseProtocol(v, command) → Either ErrorType BrokerMsg
   → Return (corrId, entityId, Right msg | Left err)

3. clientResp classification (Client.hs:708-712):
   → Left err (parse error) → PCEResponseError
   → Right msg, protocolError msg = Just err → PCEProtocolError (ERR response)
   → Right msg, protocolError msg = Nothing → Right msg (success)

4. Process: lookup corrId in pendingCommands
   → Found: resolve Promise with clientResp
   → Not found (empty corrId = server push): deliver to event callback
```

## Functions to implement

### Crypto (`src/crypto.ts` — extend)

| Function | Haskell | Implementation |
|---|---|---|
| `sha512Hash(msg)` | `Crypto.hs:1016` | `sha512(msg)` from `@noble/hashes/sha512` |
| `cbAuthenticator(serverPubKey, entityPrivKey, nonce, msg)` | `Crypto.hs:1367` | `cryptoBox(dh(serverPubKey, privKey), nonce, sha512Hash(msg))` → 80 bytes (16 tag + 64 hash) |
`cryptoBox` and `dh` already available from xftp-web. `sha512` from `@noble/hashes`.

Not needed in spike: `cbDecryptNoPad` (only used by `cbVerify` and proxy commands).

Ed25519 signing: `crypto_sign_detached` from libsodium (already loaded and initialized via xftp-web for secretbox — no second implementation needed).

Not needed: `cbVerify` (server-side only).

### Transport update (`src/transport/websockets.ts` — update)

**Gap: `connectSMP` must return `serverPubKey`** (raw X25519 public key bytes from the handshake). Currently it computes the DH secret and derives block keys, but discards the server's raw public key. The client needs it for `cbAuthenticate` on every command.

Update `SMPConnection` to include:
```typescript
interface SMPConnection {
  ws: WebSocket
  sessionId: Uint8Array
  smpVersion: number
  sndKey: Uint8Array | null
  rcvKey: Uint8Array | null
  serverPubKey: Uint8Array | null  // raw X25519 public key — needed for command auth
}
```

### Protocol encoding (`src/protocol.ts` — update existing)

Update `encodeTransmission`, `encodeBatch`, `decodeTransmission` in place — these were spike throwaway. Replace with auth-aware versions and update existing tests accordingly.

| Function | Haskell ref | Notes |
|---|---|---|
| `encodeTransmission_(v, corrId, entityId, command)` | `Protocol.hs:2194` | Update existing `encodeTransmission`. Also fix `encodeNEW`: QueueReqData should be `Just (QRMessaging Nothing)` not `Nothing`, and rename `sndAuthKey` param to `basicAuth` (it's server auth, not a crypto key) |
| `encodeTransmissionForAuth(sessionId, corrId, entityId, command)` | `Protocol.hs:2186` | Returns `{tForAuth, tToSend}`. `implySessId` always true for v>=7 |
| `authTransmission(serverPubKey, maybePrivKey, nonce, tForAuth)` | `Client.hs:1372` | `maybePrivKey` is `{type: "x25519"|"ed25519", key} | null`. Null for unauthenticated commands. X25519 → cbAuthenticator. Ed25519 → sign. |
| `tEncodeAuth(auth)` | `Protocol.hs:507` | Handles null, authenticator (80 bytes), signature (64 bytes) |
| `tEncode(auth, tToSend)` | `Protocol.hs:2171` | `tEncodeAuth(auth) + tToSend` |
| `tEncodeBatch1(auth, tToSend)` | `Protocol.hs:2179` | `[count=1] + Large(tEncode(...))` |
| `tEncodeForBatch(auth, tToSend)` | `Protocol.hs:2175` | `Large(tEncode(...))` |
| `batchTransmissions(blockSize, transmissions)` | `Protocol.hs:2151` | Pack into ≤(blockSize-19)-byte blocks, count prefix |
| `transmissionP(sessionId, block)` | `Protocol.hs:1629` | Skip auth bytes (1-byte len + data), parse corrId + entityId + command from rest. `implySessId`=true (sessionId not in wire, no need to verify on client side), `serviceAuth`=false (no serviceSig to skip) |
| `tParse(sessionId, block)` | `Protocol.hs:2211` | Parse count, N×Large, each through `transmissionP` |
| `tDecodeClient(sessionId, version, rawTransmission)` | `Protocol.hs:2256` | Parse command bytes → typed BrokerMsg |
| `encodePING()` | | PING command for keepalive |

Update `decodeResponse`:
- Add `SOK` (subscribe response with optional serviceId, returned by SUB in v19)
- Add `INFO` (queue info response, for `getSMPQueueInfo`)
- Improve `ERR` parsing: currently reads just the tag string. Need to parse structured `ErrorType` (at minimum AUTH, QUOTA, NO_MSG, INTERNAL) for proper error handling in the client

### Client (`src/client.ts` — new)

```typescript
interface SMPClient {
  sessionId: Uint8Array
  smpVersion: number
  serverPubKey: Uint8Array  // for cbAuthenticate

  // Core: send pre-encoded command, correlate response
  // Lower-level than Haskell's sendProtocolCommand — takes pre-encoded command bytes
  // privKey: {type: "x25519", key} | {type: "ed25519", key} | null
  // Rejects with PCEProtocolError (ERR response), PCEResponseError (parse fail), PCEResponseTimeout
  sendCommand(privKey: AuthKey | null, entityId: Uint8Array, command: Uint8Array): Promise<BrokerMsg>

  // High-level commands (keys are DER-encoded unless noted)
  // authKeyPair: {publicKey, privateKey, type: "x25519"} — public goes in NEW encoding, private for auth
  createQueue(authKeyPair, dhKey, subMode): Promise<QueueIdsKeys>
  subscribeQueue(privKey, rcvId): Promise<void>  // SUB can return MSG (queued message) → pushed to onMessage
  sendMessage(privKey, sndId, flags, msg): Promise<void>  // privKey can be null (before queue secured)
  ackMessage(privKey, rcvId, msgId): Promise<void>  // ACK can return MSG → pushed to onMessage
  secureQueue(privKey, rcvId, senderKey): Promise<void>
  secureSndQueue(privKey, sndId): Promise<void>
  getQueueLink(linkId): Promise<{senderId, linkData}>
  getQueueInfo(privKey, queueId): Promise<QueueInfo>
  deleteQueue(privKey, rcvId): Promise<void>
  suspendQueue(privKey, rcvId): Promise<void>

  close(): void
}

function createSMPClient(
  url: string,
  keyHash: Uint8Array,
  onMessage: (entityId: Uint8Array, msg: BrokerMsg) => void,
  onDisconnected: () => void,
  wsOptions?: object,
): Promise<SMPClient>
```

Internally:
- `connectSMP` for WebSocket + handshake (existing, updated to return serverPubKey)
- `Map<string, {resolve, reject}>` for hex(corrId) → Promise correlation
- WebSocket `onmessage`: `receiveEncryptedBlock` → `tParse` → for each transmission: `tDecodeClient` → classify via `protocolError` → correlate by corrId or push to `onMessage`
- `sendCommand`: generate random 24-byte corrId/nonce → `encodeTransmissionForAuth` → `authTransmission` → `tEncodeBatch1` → `sendEncryptedBlock` → return Promise resolved by correlator
- `setInterval` ping: send PING, count timeouts, close after N consecutive
- Timeout per command: `setTimeout` on pending Promise, reject with PCEResponseTimeout

**Message delivery model:**

All MSGs reach `onMessage` regardless of how they arrive. Three sources:

1. **Server push** (empty corrId): receive handler calls `onMessage` directly
2. **SUB response**: `sendCommand` resolves with MSG → `subscribeQueue` pushes to `onMessage`, returns success to caller
3. **ACK response**: same — `ackMessage` pushes to `onMessage`, returns success

High-level functions never expose MSG to their callers. This mirrors Haskell's `processSUBResponse_` (Client.hs:858-862) and `ackSMPMessage` (Client.hs:1042-1044) which both call `writeSMPMessage` to forward MSGs to msgQ and return OK-equivalent.

### Client REPL (`smp-web/tests/client-repl.ts` — new, separate from ratchet-repl.ts)

Separate REPL process holding a WebSocket connection + SMP client state. Same stdin/stdout line protocol approach, different state and commands.

**Message queue:** The REPL maintains an internal `Message[]` queue. The SMPClient's `onMessage` callback pushes to this queue. MSGs arrive here from three sources: server pushes (no corrId), SUB responses, and ACK responses — all handled identically by the client internals. The `RECV` command dequeues from this queue (or waits with timeout).

**Concurrency:** Unlike the ratchet REPL (pure, no network), the client REPL receives messages concurrently with stdin. This works because Node's event loop handles WebSocket `onmessage` events between readline callbacks — no explicit threading needed.

```
CONNECT <url> <keyHashHex> [wsOptions]
  → Creates SMPClient, returns "ok"

NEW <rcvAuthKeyHex> <rcvDhKeyHex> [subMode]
  → createQueue (defaults: no basic auth, SMSubscribe, QRMessaging, no ntf creds)
  → returns "ok: <rcvIdHex> <sndIdHex> <srvDhKeyHex>"

SUB <rcvIdHex> <rcvPrivKeyHex>
  → subscribeQueue, returns "ok"

SEND <sndIdHex> <sndPrivKeyHex> <bodyHex>
  → sendMessage, returns "ok"

ACK <rcvIdHex> <rcvPrivKeyHex> <msgIdHex>
  → ackMessage, returns "ok"

KEY <rcvIdHex> <rcvPrivKeyHex> <senderKeyHex>
  → secureQueue, returns "ok"

SKEY <sndIdHex> <sndPrivKeyHex>
  → secureSndQueue, returns "ok"

LGET <linkIdHex>
  → getQueueLink, returns "ok: <senderIdHex> <linkDataHex>"

RECV [timeoutMs]
  → Dequeue next server-pushed MSG, returns "ok: <entityIdHex> <msgIdHex> <bodyHex>"
  → Times out with "error: timeout" if no message arrives
```

### Polymorphic testing

Same pattern as ratchet tests: `TestPeer` sum type with `TestPeerHS` / `TestPeerJS` dispatch. For SMP client tests:

```haskell
data TestSMPClient
  = TestClientHS SMPClient
  | TestClientJS Handle Handle ProcessHandle  -- stdin, stdout, process

-- Dispatch functions
tcCreateQueue :: TestSMPClient -> ... -> IO QueueIdsKeys
tcSubscribe :: TestSMPClient -> ... -> IO ()
tcSendMessage :: TestSMPClient -> ... -> IO ()
tcReceiveMessage :: TestSMPClient -> IO (EntityId, MsgId, ByteString)
tcSecureQueue :: TestSMPClient -> ... -> IO ()
tcAckMessage :: TestSMPClient -> ... -> IO ()
```

Then the same test function runs against HS↔HS, HS↔JS, JS↔HS, JS↔JS peer combinations. The test creates two clients (one receiver, one sender) on the same SMP server, creates a queue, exchanges keys, sends messages — proving protocol compatibility.

## Tests

### Unit tests (callNode, no server)

1. `sha512Hash` — same input → same output as Haskell
2. `cbAuthenticator` — same serverPubKey + entityPrivKey + nonce + message → same 80 bytes as Haskell
3. `encodeTransmissionForAuth` — same sessionId + corrId + entityId + command (encoded at v19) → same `{tForAuth, tToSend}` as Haskell
4. `authTransmission` with X25519 key — same keys + nonce + tForAuth → same authenticated bytes as Haskell
5. `authTransmission` with Ed25519 key — same key + tForAuth → same signature bytes as Haskell
6. `authTransmission` with no key (Nothing) — produces empty auth, matches Haskell
7. `tEncodeBatch1` — same auth + transmission → same block bytes as Haskell
8. `tParse` + `tDecodeClient` — TS parses Haskell-encoded response block, extracts corrId + entityId + typed response
9. `batchTransmissions` — given N transmissions, produces same batch boundaries and block bytes as Haskell

### Integration tests (with SMP server, using REPL)

10. JS client connects, sends PING, receives PONG
11. JS client creates queue (NEW → IDS)
12. JS receiver creates queue + subscribes, JS sender sends message, receiver gets MSG
13. Full handshake: create queue → secure (KEY) → subscribe → send → receive MSG → ack

### Polymorphic integration tests

14. Same test function, peer combinations:
    - HS sender, JS receiver
    - JS sender, HS receiver
    - JS sender, JS receiver

## Implementation order

1. Transport update — `connectSMP` returns `serverPubKey`
2. Crypto additions — `sha512Hash`, `cbAuthenticator`, Ed25519 `sign`
3. Protocol encoding updates — `encodeTransmissionForAuth`, `authTransmission`, `tEncode`, `tEncodeBatch1`, `batchTransmissions`, `encodePING`
4. Protocol parsing updates — `transmissionP`, `tParse`, `tDecodeClient`, update `decodeResponse` (add `SOK`, `INFO`, structured `ERR`)
5. Unit tests for steps 1-4
6. Client core — `createSMPClient`, `sendCommand`, corrId correlation, receive dispatch, ping
7. High-level command functions
8. Client REPL
9. Integration tests with server
10. Polymorphic test wiring

## Files

| File | Action |
|---|---|
| `smp-web/src/transport/websockets.ts` | Update `connectSMP` to return `serverPubKey` |
| `smp-web/src/crypto.ts` | Add `sha512Hash`, `cbAuthenticator`, Ed25519 `sign` |
| `smp-web/src/protocol.ts` | Update transmission encoding/parsing, add auth, batching |
| `smp-web/src/client.ts` | New — SMP client |
| `smp-web/tests/client-repl.ts` | New — SMP client REPL for integration tests |
| `tests/SMPWebTests.hs` | Unit + integration tests |

## Scope

### Client spike (this plan)

Core client: connect, auth, send/receive, correlate, ping. High-level commands: NEW, SUB, KEY, SKEY, SEND, ACK, OFF, DEL, LGET, GET, QUE (getSMPQueueInfo). Single-command path. Tests against real server.

### Client MVP (next, after spike)

- Proxy commands (PRXY, PFWD, PRES) — essential for privacy, users must not connect directly to untrusted servers
- Batch subscribe (subscribeSMPQueues) — needed for groups
- `reverseNonce` — needed for proxy
- Batch delete (deleteSMPQueues)

### Post-MVP

| What | Why |
|---|---|
| Notification commands (NKEY, NDEL, NSUB) | Value only with webpush support |
| Service certificates (serviceAuth, serviceSig) | Browser doesn't use |
| Stream commands (streamSubscribeSMPQueues) | Not used in Haskell client either |
| NetworkConfig, SOCKS, host mode, transport selection | Browser connects via WebSocket directly |
| Queue link management (LSET, LDEL, LKEY) | Only needed to create links, not join them |
| `cbVerify` | Server-side only |

## Haskell references

- `Client.hs:179-200` — ProtocolClient, PClient types
- `Client.hs:248` — `type SMPClient = ProtocolClient SMPVersion ErrorType BrokerMsg`
- `Client.hs:506-512` — Request type
- `Client.hs:628-642` — client connection, handshake, raceAny_ [send, process, receive, monitor]
- `Client.hs:644-658` — send loop, receive loop
- `Client.hs:660-678` — monitor/ping loop
- `Client.hs:680-719` — process loop, processMsg (corrId correlation, clientResp classification)
- `Client.hs:810-828` — createSMPQueue
- `Client.hs:833-836` — subscribeSMPQueue
- `Client.hs:938-939` — secureSMPQueue
- `Client.hs:1027-1031` — sendSMPMessage
- `Client.hs:1040-1045` — ackSMPMessage (note: ACK can return MSG)
- `Client.hs:1239-1243` — okSMPCommand pattern
- `Client.hs:1300-1326` — sendProtocolCommand_, sendRecv, size check, tEncodeBatch1
- `Client.hs:1333-1344` — getResponse, timeout handling
- `Client.hs:1349-1370` — mkTransmission_, CorrId=nonce, encodeTransmissionForAuth, authTransmission
- `Client.hs:1372-1391` — authTransmission, authenticate (X25519 vs Ed25519), service sig
- `Protocol.hs:488-525` — RawTransmission, TransmissionAuth, TAuthorizations, tEncodeAuth
- `Protocol.hs:1629-1643` — transmissionP
- `Protocol.hs:2129-2198` — batching, tEncode, tEncodeBatch1, batchTransmissions_
- `Protocol.hs:2207-2267` — tGetClient, tParse, tDecodeClient
- `Crypto.hs:1016` — sha512Hash
- `Crypto.hs:1296-1298` — cbEncryptNoPad (= cryptoBox without padding)
- `Crypto.hs:1330-1331` — cbDecryptNoPad
- `Crypto.hs:1366-1371` — cbAuthenticate, cbVerify
