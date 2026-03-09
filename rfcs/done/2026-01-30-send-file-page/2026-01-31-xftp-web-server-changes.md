# XFTP Server: SNI, CORS, and Web Support

Implementation details for Phase 3 of `rfcs/2026-01-30-send-file-page.md` (sections 6.1-6.4).

## 1. Overview

The XFTP server is extended to support web browser clients by:

1. **SNI-based TLS certificate switching** — Present a CA-issued web certificate (e.g., Let's Encrypt) to browsers, while continuing to present the self-signed XFTP identity certificate to native clients.
2. **CORS headers** — Add CORS response headers on SNI connections so browsers allow cross-origin XFTP requests.
3. **Configuration** — `[WEB]` INI section for HTTPS cert/key paths; opt-in (commented out by default).

Web handshake (challenge-response identity proof, §6.3 of parent RFC) is not yet implemented and will be added separately.

## 2. SNI Certificate Switching

### 2.1 Reusing the SMP Pattern

The SMP server already implements SNI-based certificate switching via `TLSServerCredential` and `runTransportServerState_` (see `rfcs/2024-09-15-shared-port.md`). The XFTP server applies the same pattern with one key difference: both native and web XFTP clients use HTTP/2 transport, whereas SMP switches between raw SMP protocol and HTTP entirely.

### 2.2 Approach

When `httpServerCreds` is configured, the XFTP server bypasses `runHTTP2Server` and uses `runTransportServerState_` directly to obtain the per-connection `sniUsed` flag. It then sets up HTTP/2 manually on each TLS connection using `withHTTP2` (same internals as `runHTTP2ServerWith_`). The `sniUsed` flag is captured in the closure and shared by all HTTP/2 requests on that connection.

When `httpServerCreds` is absent, the existing `runHTTP2Server` path is unchanged.

```
Native client (no SNI)  ──TLS──> XFTP identity cert ──HTTP/2──> processRequest (no CORS)
Browser client (SNI)    ──TLS──> Web CA cert        ──HTTP/2──> processRequest (+ CORS)
```

### 2.3 Certificate Chain

The web certificate file (e.g., `web.crt`) must contain the full chain: leaf certificate followed by the signing CA certificate. `loadServerCredential` uses `T.credentialLoadX509Chain` which reads all PEM blocks from the file.

The client validates the chain by comparing `idCert` fingerprint (the CA cert, second in the 2-cert chain) against the known `keyHash`. This is the same validation as for XFTP identity certificates — the CA that signed the web cert must match the XFTP server's identity.

## 3. CORS Support

### 3.1 Design

CORS headers are only added when both conditions are true:
- `addCORSHeaders` is `True` in `TransportServerConfig` (set in XFTP `Main.hs`)
- `sniUsed` is `True` for the current TLS connection

This ensures native clients never see CORS headers.

### 3.2 Response Headers

All POST responses on SNI connections include:
```
Access-Control-Allow-Origin: *
Access-Control-Expose-Headers: *
```

### 3.3 OPTIONS Preflight

OPTIONS requests are intercepted at the HTTP/2 dispatch level, before `processRequest`. This is necessary because `processRequest` rejects bodies that don't match `xftpBlockSize`.

Preflight response:
```
HTTP/2 200
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: POST, OPTIONS
Access-Control-Allow-Headers: *
Access-Control-Max-Age: 86400
```

### 3.4 Security

`Access-Control-Allow-Origin: *` is safe because:
- All XFTP commands require Ed25519 authentication (per-chunk keys from file description).
- No cookies or browser credentials are involved.
- File content is end-to-end encrypted.

## 4. Configuration

### 4.1 INI Template

```ini
[WEB]
# cert: /etc/opt/simplex-xftp/web.crt
# key: /etc/opt/simplex-xftp/web.key
```

Commented out by default — web support is opt-in.

### 4.2 Behavior

- `[WEB]` section not configured: silently ignored, server operates normally for native clients only.
- `[WEB]` section configured with valid cert/key paths: SNI + CORS enabled.
- `[WEB]` section configured with missing cert files: warning + continue (non-fatal, unlike SMP where it is fatal).

## 5. Files Modified

### 5.1 `src/Simplex/Messaging/Transport/Server.hs`

Added `addCORSHeaders :: Bool` field to `TransportServerConfig`. Updated `mkTransportServerConfig` to accept the new parameter. All existing SMP call sites pass `False`.

### 5.2 `src/Simplex/Messaging/Transport/HTTP2/Server.hs`

- Extracted `expireInactiveClient` from `runHTTP2ServerWith_`'s `where` clause to a module-level function.
- Parameterized `runHTTP2ServerWith_`: setup type changed from `((TLS p -> IO ()) -> a)` to `(((Bool, TLS p) -> IO ()) -> a)`, callback from `HTTP2ServerFunc` to `Bool -> HTTP2ServerFunc`. The `Bool` is the per-connection `sniUsed` flag, threaded through `H.run` to the callback.
- Extended `runHTTP2Server` with `Maybe T.Credential` parameter for SNI web certificate. Its setup uses `runTransportServerState_` with `TLSServerCredential`, which naturally provides `(sniUsed, tls)` pairs matching the new `runHTTP2ServerWith_` setup type.
- Adapted `runHTTP2ServerWith` (client-side HTTP/2, no SNI): wraps its setup to inject `(False, tls)` and its callback with `const`.
- Updated `getHTTP2Server` (test helper) to pass `Nothing` for httpCreds.

### 5.3 `src/Simplex/FileTransfer/Server/Env.hs`

- Added `httpCredentials :: Maybe ServerCredentials` to `XFTPServerConfig`.
- Added `httpServerCreds :: Maybe T.Credential` to `XFTPEnv`.
- `newXFTPServerEnv` loads HTTP credentials when configured.

### 5.4 `src/Simplex/FileTransfer/Server/Main.hs`

- Added `[WEB]` section to INI template.
- Added `httpCredentials` parsing from INI `[WEB]` section (`cert` and `key` fields).
- Set `addCORSHeaders = isJust httpCredentials_` in transport config (conditional on web cert presence).

### 5.5 `src/Simplex/FileTransfer/Server.hs`

Core server changes:

- `runServer` calls `runHTTP2Server` with `httpCreds_` and a `\sniUsed -> handleRequest (sniUsed && addCORSHeaders transportConfig)` callback. TLS params are `defaultSupportedParamsHTTPS` when web creds present, `defaultSupportedParams` otherwise. SNI routing, HTTP/2 setup, and client expiration are handled inside `runHTTP2Server`.

- `XFTPTransportRequest` carries `addCORS :: Bool` field, threaded through to `sendXFTPResponse`.

- `sendXFTPResponse` conditionally includes CORS headers based on `addCORS`.

- OPTIONS requests on SNI connections return CORS preflight headers before reaching `processRequest`.

- Helper functions: `corsHeaders` (response headers), `corsPreflightHeaders` (preflight headers).

### 5.6 `tests/XFTPClient.hs`

- Added `httpCredentials = Nothing` to `testXFTPServerConfig`.
- Added `testXFTPServerConfigSNI` with web cert config and `addCORSHeaders = True`.
- Added `withXFTPServerSNI` helper.

### 5.7 `tests/XFTPServerTests.hs`

Added SNI and CORS tests as a subsection within `xftpServerTests` (6 tests):

1. **SNI cert selection** — Connect with SNI + `h2` ALPN, verify RSA web certificate is presented.
2. **Non-SNI cert selection** — Connect without SNI + `xftp/1` ALPN, verify Ed448 XFTP certificate is presented.
3. **CORS headers** — SNI POST request includes `Access-Control-Allow-Origin: *` and `Access-Control-Expose-Headers: *`.
4. **OPTIONS preflight** — SNI OPTIONS request returns all CORS preflight headers.
5. **No CORS without SNI** — Non-SNI POST request has no CORS headers.
6. **File chunk delivery** — Full XFTP file chunk upload/download through SNI-enabled server verifying no regression.

## 6. Remaining Work

- **Web handshake** (§6.3 of parent RFC): Challenge-response identity proof for SNI connections. The server detects web clients via the `sniUsed` flag and expects a 32-byte challenge in the first POST body (non-empty, unlike standard handshake). Response includes full cert chain + signature over `(challenge ++ sessionId)`.
- **Static page serving** (§6.5 of parent RFC): Optional serving of the web page HTML/JS bundle on GET requests.
