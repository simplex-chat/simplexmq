# Simplex.FileTransfer.Transport

> XFTP protocol types, version negotiation, and encrypted file streaming with integrity verification.

**Source**: [`FileTransfer/Transport.hs`](../../../../src/Simplex/FileTransfer/Transport.hs)

## xftpClientHandshakeStub — XFTP doesn't use TLS handshake

`xftpClientHandshakeStub` always fails with `throwE TEVersion`. The source comment states: "XFTP protocol does not use this handshake method." The XFTP handshake is performed at the HTTP/2 layer — `XFTPServerHandshake` and `XFTPClientHandshake` are sent as HTTP/2 request/response bodies (see `FileTransfer/Client.hs` and `FileTransfer/Server.hs`).

## receiveSbFile — constant-time auth tag verification

`receiveSbFile` validates the authentication tag using `BA.constEq` (constant-time byte comparison). The auth tag is collected from the stream after all file data — if the file data ends mid-chunk, the remaining bytes of that chunk are used first, and a follow-up read provides the rest of the tag if needed.

## receiveFile_ — two-phase integrity verification

File reception has two verification phases:
1. **During receive**: either size checking (plaintext via `hReceiveFile`) or auth tag validation (encrypted via `receiveSbFile`)
2. **After receive**: `LC.sha256Hash` of the entire received file is compared to `chunkDigest`

## sendEncFile — auth tag appended after all chunks

`sendEncFile` streams encrypted chunks via `LC.sbEncryptChunk`, then sends `LC.sbAuth sbState` (the authentication tag) as a final frame when the remaining size reaches zero.
