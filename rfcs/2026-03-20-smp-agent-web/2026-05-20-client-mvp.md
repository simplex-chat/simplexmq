# SMP Client MVP: Proxy + Batching — Transpilation Plan

**Parent**: [SMP Client Spike](./2026-05-17-smp-client.md)

## Rule

Every TypeScript function is a faithful transpilation of a specific Haskell function at specific lines. Same name, same steps, same call chain. No inferences, no approximations. Each entry below gives the exact source to transpile from.

## Crypto functions

### `reverseNonce` → transpile `Crypto.hs:1409-1410`
```haskell
reverseNonce (CryptoBoxNonce s) = CryptoBoxNonce (B.reverse s)
```
TS: `function reverseNonce(nonce: Uint8Array): Uint8Array` — reverse the 24 bytes.

### `cbDecryptNoPad` → transpile `Crypto.hs:1330-1331`
```haskell
cbDecryptNoPad (DhSecretX25519 secret) = sbDecryptNoPad_ secret
```
Which is `sbDecryptNoPad_` from secretbox. xftp-web's `cbDecrypt` does decrypt+unpad. Need decrypt without unpad — extract tag(16) + cipher, decrypt, verify tag, return raw (no unpad). Use xftp-web's `sbInit`/`sbDecryptChunk`/`sbAuth` directly.

## Protocol encoding functions

### `encodeProtocolServer` → transpile `Protocol.hs:1264-1266`
```haskell
smpEncode ProtocolServer {host, port, keyHash} = smpEncode (host, port, keyHash)
```
Where:
- `host :: NonEmpty TransportHost` → `smpEncodeList` (1-byte count + items)
- Each `TransportHost` → `smpEncode (strEncode host)` → `encodeBytes(ascii(hostname))` (`Transport/Client.hs:77-78`)
- `port :: ServiceName` = ByteString → `encodeBytes(port)`
- `keyHash :: KeyHash` = ByteString → `encodeBytes(keyHash)`

File: `src/protocol.ts`

### `encodePRXY` → transpile `Protocol.hs:1710`
```haskell
PRXY host auth_ -> e (PRXY_, ' ', host, auth_)
```
= `"PRXY " + smpEncode(server) + smpEncode(Maybe BasicAuth)`

Where `Maybe BasicAuth` = `encodeMaybe(encodeBytes, auth)`.

### `encodePFWD` → transpile `Protocol.hs:1711`
```haskell
PFWD fwdV pubKey (EncTransmission s) -> e (PFWD_, ' ', fwdV, pubKey, Tail s)
```
= `"PFWD " + encodeWord16(version) + encodeBytes(pubKeyDer) + encTransmission` (Tail = no length prefix)

### `decodePKEY` → transpile `Protocol.hs:1894`
```haskell
PKEY_ -> PKEY <$> _smpP <*> smpP <*> smpP
```
= space + `decodeBytes(d)` (sessionId) + `decodeVersionRange(d)` + `decodeCertChainPubKey(d)`

`VersionRange` encoding (`Version.hs`): `smpEncode (minVersion, maxVersion)` = two Word16.

`CertChainPubKey` encoding (`Transport.hs:663-667`): `smpEncode (encodeCertChain chain, SignedObject signedPubKey)` — `encodeCertChain` is `Large`-encoded DER bytes, `SignedObject` is `Large`-encoded DER bytes.

### `decodePRES` → transpile `Protocol.hs:1896`
```haskell
PRES_ -> PRES <$> (EncResponse . unTail <$> _smpP)
```
= space + rest of bytes (Tail) → `EncResponse`

### Add to `decodeResponse`: `PKEY` and `PRES` cases.

## Client functions

### `sendProtocolCommands` → transpile `Client.hs:1262-1278`

Call chain:
1. `mapM (mkTransmission c) cs` — for each command: generate corrId, encode, auth, register pending request
2. `batchTransmissions' thParams` — pack into blocks
3. `mapM (sendBatch c nm) bs` — send each block, collect responses
4. `validate` — verify response count matches command count

In TS: `mkTransmission` = the existing `sendCommand` logic (corrId generation, `encodeTransmissionForAuth`, `authTransmission`) but separated into encode+register vs send+await. Need to refactor `sendCommand` to split these.

### `batchTransmissions'` → transpile `Protocol.hs:2135-2148`

Already have `batchTransmissions` in protocol.ts that does `batchTransmissions_`. Need `batchTransmissions'` which wraps with `tEncodeForBatch` before batching. Currently the TS `batchTransmissions` takes pre-encoded Large-wrapped bytes. Need to match the Haskell call chain exactly:

```haskell
batchTransmissions' params ts
  | batch = batchTransmissions_ bSize $ L.map (first $ fmap $ tEncodeForBatch serviceAuth) ts
```

### `sendBatch` → transpile `Client.hs:1285-1298`

Three cases:
- `TBError`: return error response
- `TBTransmissions s n rs`: send block `s`, await all `n` responses concurrently
- `TBTransmission s r`: send block `s`, await one response

In browser: "concurrently" = all promises pending simultaneously, resolved by `onBlock` handler as responses arrive.

### `subscribeSMPQueues` → transpile `Client.hs:840-845`
```haskell
subscribeSMPQueues c qs = do
  liftIO $ enablePings c
  sendProtocolCommands c NRMBackground cs >>= mapM (processSUBResponse c)
  where
    cs = L.map (\(rId, rpKey) -> (rId, Just rpKey, Cmd SRecipient SUB)) qs
```

### `processSUBResponse` → transpile `Client.hs:854-862`
```haskell
processSUBResponse c (Response rId r) = pure r $>>= processSUBResponse_ c rId
processSUBResponse_ c rId = \case
  OK -> pure $ Right Nothing
  SOK serviceId_ -> pure $ Right serviceId_
  cmd@MSG {} -> writeSMPMessage c rId cmd $> Right Nothing
  r' -> pure . Left $ unexpectedResponse r'
```
MSG → push to `onMessage`, return success. Same pattern as single subscribe.

### `deleteSMPQueues` → transpile `Client.hs:1062-1065`
```haskell
deleteSMPQueues = okSMPCommands DEL
```
Uses `okSMPCommands` (`Client.hs:1245-1253`) which calls `sendProtocolCommands` and checks each response is OK.

### `connectSMPProxiedRelay` → transpile `Client.hs:1069-1093`

Call chain:
1. Send `PRXY relayServ proxyAuth` to proxy (via `sendProtocolCommand_`, entityId = NoEntity)
2. Receive `PKEY sessionId versionRange certChainPubKey`
3. Check version compatibility
4. `validateRelay chain key` — validate cert chain against relay's keyHash, extract X25519 key
5. Return `ProxiedRelay {sessionId, version, auth, relayKey}`

`validateRelay` (`Client.hs:1085-1093`):
1. `chainIdCaCerts chain` → extract leaf, id, ca certs
2. Check `Fingerprint kh == getFingerprint idCert SHA256`
3. `x509validate caCert (hostName, port) chain`
4. Extract server key from leaf cert
5. Verify signed key against server key

In browser: we already have `verifyIdentityProof` and `extractSignedKey` from xftp-web. Need to adapt for relay validation where we receive the cert chain in the PKEY response (DER-encoded, not from TLS handshake).

### `proxySMPCommand` → transpile `Client.hs:1157-1206`

Call chain:
1. Construct `serverThParams` = `smpTHParamsSetVersion v proxyThParams {sessionId, thAuth = serverThAuth}`
   - `serverThAuth = thAuth proxyThParams with peerServerPubKey = relayKey`
2. Generate ephemeral X25519 keypair: `(cmdPubKey, cmdPrivKey)`
3. `cmdSecret = dh(relayKey, cmdPrivKey)`
4. Generate random nonce (also used as corrId)
5. `encodeTransmissionForAuth serverThParams (CorrId corrId, sId, Cmd sParty command)` — encode as if sending to relay
6. `authTransmission serverThAuth False spKey nonce tForAuth` — authenticate with entity key against relay
7. `batchTransmissions serverThParams [Right (auth, tToSend)]` — batch into single block
8. `cbEncrypt cmdSecret nonce batchBlock paddedProxiedTLength` → `EncTransmission`
9. Send `PFWD version cmdPubKey encTransmission` to proxy (entityId = sessionId)
10. Receive `PRES (EncResponse encResponse)`
11. `cbDecrypt cmdSecret (reverseNonce nonce) encResponse` — decrypt relay's response
12. `tParse serverThParams decrypted` — parse as relay's response
13. `tDecodeClient serverThParams parsed` — decode command
14. Classify: `Right (ERR e)` → throw PCEProtocolError, `Right r` → return Right r, `Left e` → throw PCEResponseError

Error wrapping (`Client.hs:1200-1206`): proxy-level errors (from PFWD response itself) → `ProxyClientError` returned as `Left`. Relay-level errors (inside PRES) → `PCEProtocolError` thrown.

### `paddedProxiedTLength` → `Protocol.hs:306-307` = 16226

## Constants

```
paddedProxiedTLength = 16226  -- Protocol.hs:306
serviceCertsSMPVersion = 16   -- Transport.hs:213
```

## Testing

### Unit tests (callNode, no server)
Each encoding function tested byte-for-byte against Haskell:
1. `reverseNonce` — reverse known bytes, compare
2. `encodeProtocolServer` — encode known server, compare with `smpEncode @SMPServer`
3. `encodePRXY` — encode PRXY command, compare with `encodeProtocol v (Cmd SProxiedClient (PRXY srv auth))`
4. `encodePFWD` — encode PFWD command, compare with `encodeProtocol v (Cmd SProxiedClient (PFWD v pk et))`
5. `batchTransmissions` with multiple commands — same batch boundaries as `batchTransmissions_` in Haskell

### Integration tests (with two SMP servers, from SMPProxyTests.hs pattern)
6. `connectProxiedRelay` — JS connects to proxy, sends PRXY for relay, gets PKEY, validates cert, extracts key
7. `proxySMPMessage` — JS sends SEND via proxy to relay, HS receiver gets MSG
8. Full proxy roundtrip — JS creates queue on relay via proxy, sends message via proxy, HS receives

### Batch tests
9. `subscribeSMPQueues` — JS batch-subscribes to N queues, verifies all subscribed
10. `deleteSMPQueues` — JS batch-deletes N queues

## Implementation order

1. `reverseNonce`, `cbDecryptNoPad`
2. `encodeProtocolServer`, `encodePRXY`, `encodePFWD`
3. `decodePKEY`, `decodePRES`, update `decodeResponse`
4. Unit tests for steps 1-3
5. Refactor `sendCommand` → split into `mkTransmission` (encode+register) and send
6. `sendProtocolCommands`, `sendBatch`
7. `subscribeSMPQueues`, `deleteSMPQueues`
8. Batch integration tests
9. `connectSMPProxiedRelay` (cert validation, PRXY/PKEY)
10. `proxySMPCommand`, `proxySMPMessage`
11. Proxy integration tests

## Files

| File | Action |
|---|---|
| `smp-web/src/crypto.ts` | `reverseNonce`, `cbDecryptNoPad` |
| `smp-web/src/protocol.ts` | `encodeProtocolServer`, `encodePRXY`, `encodePFWD`, `decodePKEY`, `decodePRES` |
| `smp-web/src/client.ts` | `sendProtocolCommands`, `sendBatch`, `subscribeSMPQueues`, `deleteSMPQueues`, `connectSMPProxiedRelay`, `proxySMPCommand` |
| `smp-web/tests/client-repl.ts` | Proxy + batch REPL commands |
| `tests/SMPWebTests.hs` | Tests |

## Haskell source — exact lines to transpile

| TS function | Haskell function | File:lines |
|---|---|---|
| `reverseNonce` | `reverseNonce` | `Crypto.hs:1409-1410` |
| `cbDecryptNoPad` | `cbDecryptNoPad` / `sbDecryptNoPad_` | `Crypto.hs:1330-1331` |
| `encodeProtocolServer` | `instance Encoding (ProtocolServer p)` | `Protocol.hs:1264-1266` |
| `encodePRXY` | `encodeProtocol v (PRXY ...)` | `Protocol.hs:1710` |
| `encodePFWD` | `encodeProtocol v (PFWD ...)` | `Protocol.hs:1711` |
| `decodePKEY` | `protocolP v PKEY_` | `Protocol.hs:1894` |
| `decodePRES` | `protocolP v PRES_` | `Protocol.hs:1896` |
| `sendProtocolCommands` | `sendProtocolCommands` | `Client.hs:1262-1278` |
| `sendBatch` | `sendBatch` | `Client.hs:1285-1298` |
| `subscribeSMPQueues` | `subscribeSMPQueues` | `Client.hs:840-845` |
| `processSUBResponse` | `processSUBResponse` + `processSUBResponse_` | `Client.hs:854-862` |
| `deleteSMPQueues` | `deleteSMPQueues` via `okSMPCommands` | `Client.hs:1062-1065, 1245-1253` |
| `connectSMPProxiedRelay` | `connectSMPProxiedRelay` | `Client.hs:1069-1093` |
| `validateRelay` | `validateRelay` (inside `connectSMPProxiedRelay`) | `Client.hs:1085-1093` |
| `proxySMPCommand` | `proxySMPCommand` | `Client.hs:1157-1206` |
| `proxyOKSMPCommand` | `proxyOKSMPCommand` | `Client.hs:1150-1155` |
| `smpTHParamsSetVersion` | `smpTHParamsSetVersion` | `Transport.hs:921-926` |
| `batchTransmissions'` | `batchTransmissions'` | `Protocol.hs:2135-2148` |
| `batchTransmissions_` | `batchTransmissions_` | `Protocol.hs:2150-2169` |
