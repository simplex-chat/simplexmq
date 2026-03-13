# Simplex.FileTransfer.Types

> Agent-side file transfer types: receive/send file records, status state machines, chunk/replica structures.

**Source**: [`FileTransfer/Types.hs`](../../../../src/Simplex/FileTransfer/Types.hs)

## Non-obvious behavior

### 1. Receive file status state machine

`RcvFileStatus` progresses: `RFSReceiving` → `RFSReceived` → `RFSDecrypting` → `RFSComplete`, with `RFSError` as a terminal state reachable from any non-complete state. The `RFSReceived` → `RFSDecrypting` transition is significant: all chunks are downloaded but decryption hasn't started. The local worker (server=Nothing) picks up files in `RFSReceived` status.

### 2. Send file status state machine

`SndFileStatus` progresses: `SFSNew` → `SFSEncrypting` → `SFSEncrypted` → `SFSUploading` → `SFSComplete`, with `SFSError` as terminal. The prepare worker handles `SFSNew` → `SFSEncrypted` (including retry from `SFSEncrypting`), while per-server upload workers handle `SFSUploading` → `SFSComplete`.

### 3. Encrypted file path convention

`sndFileEncPath` constructs the path as `prefixPath </> "xftp.encrypted"`. This is a convention shared between the agent (`Agent.hs`) and this module — both must agree on where the encrypted intermediate file lives relative to the prefix directory.

### 4. FileHeader fileExtra for future extension

`FileHeader` contains `fileName` and an optional `fileExtra :: Maybe Text` field. Currently unused (`Nothing` in all callers), it provides a forward-compatible extension point embedded in the encrypted file header without requiring protocol version changes.

### 5. authTagSize = 16 bytes

`authTagSize` is defined as `fromIntegral C.authTagSize` (16 bytes). This is the AES-GCM authentication tag appended to the encrypted file stream. It is included in the payload size calculation (`payloadSize = fileSize' + fileSizeLen + authTagSize`), which is then passed to `prepareChunkSizes` to determine chunk allocation.
