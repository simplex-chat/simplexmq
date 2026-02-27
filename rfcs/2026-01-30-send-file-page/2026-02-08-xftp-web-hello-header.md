# XFTP Web Hello Header — Session Re-handshake for Browser Connection Reuse

## 1. Problem Statement

Browser HTTP/2 connection pooling reuses TLS connections across page navigations (same origin = same connection pool). The XFTP server maintains per-TLS-connection session state in `TMap SessionId Handshake` keyed by `tlsUniq tls`. When a browser navigates from the upload page to the download page (or reloads), the new page sends a fresh ClientHello on the reused HTTP/2 connection. The server is already in `HandshakeAccepted` state for that connection, so it routes the request to `processRequest`, which expects a 16384-byte command block but receives a 34-byte ClientHello → `ERR BLOCK`.

**Root cause**: The server cannot distinguish a ClientHello from a command on an already-handshaked connection because both arrive on the same HTTP/2 connection (same `tlsUniq`), and there is no content-level discriminator (ClientHello is unpadded, but the server never gets to parse it — the size check in `processRequest` rejects it first).

**Browser limitation**: `fetch()` provides zero control over HTTP/2 connection pooling. There is no browser API to force a new connection or detect connection reuse before a request is sent.

## 2. Solution Summary

Add an HTTP header `xftp-web-hello` to web ClientHello requests. When the server sees this header on an already-handshaked connection (`HandshakeAccepted` state), it re-runs `processHello` **reusing the existing session keys** (same X25519 key pair from the original handshake). The client then completes the normal handshake flow (sends ClientHandshake, receives ack) and proceeds with commands.

Key properties:
- Server reuses existing `serverPrivKey` — no new key material generated on re-handshake, so `thAuth` remains consistent with any in-flight commands on concurrent HTTP/2 streams.
- Header is only checked when `sniUsed` is true (web/browser connections). Native XFTP clients are unaffected.
- CORS preflight already allows all headers (`Access-Control-Allow-Headers: *`).
- Web clients always send this header on ClientHello — it's harmless on first connection (`Nothing` state) and enables re-handshake on reused connections (`HandshakeAccepted` state).

## 3. Detailed Technical Design

### 3.1 Server change: parameterize `processHello` (`src/Simplex/FileTransfer/Server.hs`)

The entire server change is parameterizing the existing `processHello` with `Maybe C.PrivateKeyX25519`. Zero new functions.

#### Current code (lines 165-191):

```haskell
xftpServerHandshakeV1 chain serverSignKey sessions
  XFTPTransportRequest {thParams = thParams0@THandleParams {sessionId}, reqBody = HTTP2Body {bodyHead}, sendResponse, sniUsed, addCORS} = do
    s <- atomically $ TM.lookup sessionId sessions
    r <- runExceptT $ case s of
      Nothing -> processHello
      Just (HandshakeSent pk) -> processClientHandshake pk
      Just (HandshakeAccepted thParams) -> pure $ Just thParams
    either sendError pure r
    where
      processHello = do
        challenge_ <-
          if
            | B.null bodyHead -> pure Nothing
            | sniUsed -> do
                XFTPClientHello {webChallenge} <- liftHS $ smpDecode bodyHead
                pure webChallenge
            | otherwise -> throwE HANDSHAKE
        (k, pk) <- atomically . C.generateKeyPair =<< asks random
        atomically $ TM.insert sessionId (HandshakeSent pk) sessions
        -- ...build and send ServerHandshake...
        pure Nothing
```

#### After (diff is ~10 lines):

```haskell
xftpServerHandshakeV1 chain serverSignKey sessions
  XFTPTransportRequest {thParams = thParams0@THandleParams {sessionId}, request, reqBody = HTTP2Body {bodyHead}, sendResponse, sniUsed, addCORS} = do
--                                                                      ^^^^^^^ bind request
    s <- atomically $ TM.lookup sessionId sessions
    r <- runExceptT $ case s of
      Nothing -> processHello Nothing
      Just (HandshakeSent pk) -> processClientHandshake pk
      Just (HandshakeAccepted thParams)
        | webHello -> processHello (serverPrivKey <$> thAuth thParams)
        | otherwise -> pure $ Just thParams
    either sendError pure r
    where
      webHello = sniUsed && any (\(t, _) -> tokenKey t == "xftp-web-hello") (fst $ H.requestHeaders request)
      processHello pk_ = do
        challenge_ <-
          if
            | B.null bodyHead -> pure Nothing
            | sniUsed -> do
                XFTPClientHello {webChallenge} <- liftHS $ smpDecode bodyHead
                pure webChallenge
            | otherwise -> throwE HANDSHAKE
        (k, pk) <- maybe
          (atomically . C.generateKeyPair =<< asks random)
          (\pk -> pure (C.publicKey pk, pk))
          pk_
        atomically $ TM.insert sessionId (HandshakeSent pk) sessions
        -- ...rest unchanged...
        pure Nothing
```

#### What changes:

1. **Bind `request`** in the `XFTPTransportRequest` pattern (+1 field)
2. **Add `webHello`** binding in `where` clause (1 line) — checks header only when `sniUsed`
3. **Add `pk_` parameter** to `processHello` (change signature)
4. **Replace key generation** with `maybe` that generates fresh keys when `pk_ = Nothing`, or derives public from existing private when `pk_ = Just pk` (3 lines replace 1 line)
5. **Add guard** in `HandshakeAccepted` branch (2 lines replace 1 line)
6. **Call site** `Nothing -> processHello Nothing` (+1 word)
7. **One import** added: `Network.HPACK.Token (tokenKey)`

#### Imports to add:

```haskell
import Network.HPACK.Token (tokenKey)
```

`OverloadedStrings` (already enabled in Server.hs) provides the `IsString` instance for `CI ByteString`, so `tokenKey t == "xftp-web-hello"` works without importing `Data.CaseInsensitive`. Verified on Hackage: `requestHeaders :: Request -> HeaderTable`, `tokenKey :: Token -> CI ByteString`.

### 3.2 Re-handshake flow

When `webHello` is true in `HandshakeAccepted` state:

1. `processHello (serverPrivKey <$> thAuth thParams)` is called with `Just pk` (existing private key)
2. `(k, pk) <- pure (C.publicKey pk, pk)` — reuses same key pair, no generation
3. `TM.insert sessionId (HandshakeSent pk) sessions` — transitions state back to `HandshakeSent` with same `pk`
4. Server sends `ServerHandshake` response (same format as initial handshake)
5. Client sends `ClientHandshake` on next stream → enters `Just (HandshakeSent pk) -> processClientHandshake pk` → normal flow
6. `processClientHandshake` stores `HandshakeAccepted thParams` with same `serverPrivKey = pk`

### 3.3 Web client change (`xftp-web/src/client.ts`)

Add optional `headers?` parameter to `Transport.post()`, thread it through `fetch()` and `session.request()`, and pass `{"xftp-web-hello": "1"}` in the ClientHello call in `connectXFTP`.

### 3.4 What does NOT change

- **CORS**: Already has `Access-Control-Allow-Headers: *` (Server.hs:106).
- **Native Haskell client**: Uses `[]` headers. No header = existing behavior.
- **Protocol wire format**: ClientHello, ServerHandshake, ClientHandshake, commands — all unchanged.
- **`processRequest`**, **`processClientHandshake`**, **`sendError`**, **`encodeXftp`** — unchanged.

### 3.5 Haskell test (`tests/XFTPServerTests.hs`)

Add `testWebReHandshake` next to the existing `testWebHandshake` (line 504). It reuses the same SNI + HTTP/2 setup pattern, performs a full handshake, then sends a second ClientHello with the `xftp-web-hello` header on the same connection and verifies the server responds with a valid ServerHandshake (same `sessionId`), then completes the second handshake.

```haskell
-- Register in xftpServerTests (after line 86):
it "should re-handshake on same connection with xftp-web-hello header" testWebReHandshake

-- Test (after testWebHandshake):
testWebReHandshake :: Expectation
testWebReHandshake =
  withXFTPServerSNI $ \_ -> do
    Fingerprint fp <- loadFileFingerprint "tests/fixtures/ca.crt"
    let keyHash = C.KeyHash fp
        cfg = defaultTransportClientConfig {clientALPN = Just ["h2"], useSNI = True}
    runTLSTransportClient defaultSupportedParamsHTTPS Nothing cfg Nothing "localhost" xftpTestPort (Just keyHash) $ \(tls :: TLS 'TClient) -> do
      let h2cfg = HC.defaultHTTP2ClientConfig {HC.bodyHeadSize = 65536}
      h2 <- either (error . show) pure =<< HC.attachHTTP2Client h2cfg (THDomainName "localhost") xftpTestPort mempty 65536 tls
      g <- C.newRandom
      -- First handshake (same as testWebHandshake)
      challenge1 <- atomically $ C.randomBytes 32 g
      let helloReq1 = H2.requestBuilder "POST" "/" [] $ byteString (smpEncode (XFTPClientHello {webChallenge = Just challenge1}))
      resp1 <- either (error . show) pure =<< HC.sendRequest h2 helloReq1 (Just 5000000)
      shs1 <- either error pure $ smpDecode =<< C.unPad (bodyHead (HC.respBody resp1))
      let XFTPServerHandshake {sessionId = sid1} = shs1
      clientHsPadded <- either (error . show) pure $ C.pad (smpEncode (XFTPClientHandshake {xftpVersion = VersionXFTP 1, keyHash})) xftpBlockSize
      resp1b <- either (error . show) pure =<< HC.sendRequest h2 (H2.requestBuilder "POST" "/" [] $ byteString clientHsPadded) (Just 5000000)
      B.length (bodyHead (HC.respBody resp1b)) `shouldBe` 0
      -- Second handshake on same connection with xftp-web-hello header
      challenge2 <- atomically $ C.randomBytes 32 g
      let helloReq2 = H2.requestBuilder "POST" "/" [("xftp-web-hello", "1")] $ byteString (smpEncode (XFTPClientHello {webChallenge = Just challenge2}))
      resp2 <- either (error . show) pure =<< HC.sendRequest h2 helloReq2 (Just 5000000)
      shs2 <- either error pure $ smpDecode =<< C.unPad (bodyHead (HC.respBody resp2))
      let XFTPServerHandshake {sessionId = sid2} = shs2
      sid2 `shouldBe` sid1  -- same TLS connection → same sessionId
      -- Complete second handshake
      resp2b <- either (error . show) pure =<< HC.sendRequest h2 (H2.requestBuilder "POST" "/" [] $ byteString clientHsPadded) (Just 5000000)
      B.length (bodyHead (HC.respBody resp2b)) `shouldBe` 0
```

The only difference from `testWebHandshake`: the second `helloReq2` passes `[("xftp-web-hello", "1")]` instead of `[]`. The test verifies:
1. Server responds with `ServerHandshake` (not `ERR BLOCK`)
2. Same `sessionId` (same TLS connection)
3. Second `ClientHandshake` completes with empty ACK

## 4. Implementation Plan

### Step 1: Server — parameterize `processHello`

Apply the diff from Section 3.1 to `src/Simplex/FileTransfer/Server.hs`.

### Step 2: Test — add `testWebReHandshake`

Add the test from Section 3.5 to `tests/XFTPServerTests.hs`.

### Step 3: Client — add `xftp-web-hello` header

Add optional `headers?` to `Transport.post()`, pass `{"xftp-web-hello": "1"}` on ClientHello in `connectXFTP`.

### Step 4: Test

Run Haskell tests (`cabal test`) and E2E Playwright tests (`npx playwright test` in `xftp-web/`).

## 5. Race Condition Analysis

### Single-tab navigation (the common case)

1. Upload page completes, all fetch() requests finish
2. Browser navigates to download page (or reloads)
3. All upload-page fetches are aborted on page unload
4. Download page sends ClientHello with `xftp-web-hello` header
5. Server is in `HandshakeAccepted` → `processHello (Just pk)` → `HandshakeSent pk` (same key)
6. No concurrent streams → no race

**Safe.**

### Multi-tab (edge case)

Tab A (upload) and Tab B (download) share the same HTTP/2 connection.

1. Tab A has active command streams (e.g., FPUT upload in progress)
2. Tab B sends ClientHello with header
3. Server reads `HandshakeAccepted` atomically for both streams
4. Tab A's stream already has its `thParams` snapshot → proceeds with `processRequest` using old `thParams`
5. Tab B's stream triggers `processHello (Just pk)` → stores `HandshakeSent pk` (same pk!)
6. Tab A's in-progress FPUT continues with snapshot `thParams` → completes normally (same `serverPrivKey`)
7. Tab A's NEXT command reads `HandshakeSent` from TMap → enters `processClientHandshake` → fails (command body ≠ ClientHandshake format) → HANDSHAKE error

**Tab A's in-flight commands succeed. Tab A's subsequent commands fail with HANDSHAKE error.** This is the inherent multi-tab problem — unavoidable with per-connection session state and HTTP/2 connection sharing. The failure is clean (HANDSHAKE error, not silent corruption).

## 6. Security Considerations

- **No new key material**: Re-handshake reuses existing `serverPrivKey`. No opportunity for key confusion or downgrade.
- **Identity re-verification**: Server re-signs the web challenge with its long-term signing key. Client verifies identity again.
- **Header cannot escalate privileges**: The header only triggers re-handshake (which the server was already capable of doing on first connection). It does not bypass any authentication.
- **Timing**: Re-handshake takes the same code path as initial handshake, so timing side-channels are unchanged.
