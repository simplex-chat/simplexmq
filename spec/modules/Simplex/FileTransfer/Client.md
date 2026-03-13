# Simplex.FileTransfer.Client

> XFTP client: connection management, handshake, chunk upload/download with forward secrecy.

**Source**: [`FileTransfer/Client.hs`](../../../../src/Simplex/FileTransfer/Client.hs)

## Non-obvious behavior

### 1. ALPN-based handshake version selection

`getXFTPClient` checks the ALPN result after TLS negotiation:
- **`xftpALPNv1` or `httpALPN11`**: performs v1 handshake with key exchange (`httpALPN11` is used for web port connections)
- **No ALPN or unrecognized**: uses legacy v1 transport parameters without handshake

### 2. Router certificate chain validation

`xftpClientHandshakeV1` validates the router's identity by checking that the CA fingerprint from the certificate chain matches the expected `keyHash` from the router address. The router signs an authentication public key (X25519) with its long-term key. The client verifies this signature against the certificate chain, then extracts the X25519 key for HMAC-based command authentication. This authentication key is distinct from the per-download ephemeral DH keys.

### 3. Ephemeral DH key pair per download

`downloadXFTPChunk` generates a fresh X25519 key pair for each chunk download. The public key is sent with the FGET command; the router responds with its own ephemeral key. The derived shared secret encrypts the file data in transit. This provides forward secrecy — compromising a past DH key doesn't decrypt other downloads.

### 4. Chunk-size-proportional download timeout

`downloadXFTPChunk` calculates the timeout as `baseTimeout + (sizeInKB * perKbTimeout)`, where `baseTimeout` is the base TCP timeout and `perKbTimeout` is a per-kilobyte timeout from the network config. Larger chunks get proportionally more time. This prevents premature timeouts on large chunks over slow connections.

### 5. prepareChunkSizes threshold algorithm

`prepareChunkSizes` selects chunk sizes using a 75% threshold: if the remaining payload exceeds 75% of the next larger chunk size, it uses the larger size. Otherwise, it uses the smaller size. `singleChunkSize` returns `Just size` only if the payload fits in a single chunk (used for redirect files which must be single-chunk).

### 6. Upload sends file body after command response

`uploadXFTPChunk` sends the FPUT command and file body in the same streaming HTTP/2 request: the protocol command block is sent first, followed immediately by the raw file data via `hSendFile`. The router response (`FROk` or error) is received only after both the command and file body have been fully sent. This is a single HTTP/2 round trip, not a two-phase interaction.

### 7. Empty corrId as nonce

`sendXFTPCommand` uses `""` (empty bytestring) as the correlation ID for all commands. XFTP is strictly request-response within a single HTTP/2 stream, so correlation IDs are unnecessary. The empty value is passed to `C.cbNonce` to produce a constant nonce for command authentication (HMAC/signing), not encryption — XFTP authenticates commands but does not encrypt them within the TLS tunnel.
