# XFTP

File transfer protocol for large files: router storage architecture, protocol commands, agent upload/download pipelines, chunk management, and encryption. XFTP enables secure file sharing by splitting files into encrypted chunks stored across multiple routers.

For XFTP transport handshake details, see [transport.md](transport.md). For the XFTP protocol specification, see [xftp.md](../../protocol/xftp.md).

- [Protocol overview](#protocol-overview)
- [Router storage](#router-storage)
- [Protocol commands](#protocol-commands)
- [Agent upload pipeline](#agent-upload-pipeline)
- [Agent download pipeline](#agent-download-pipeline)
- [Chunk encryption](#chunk-encryption)
- [Chunk management](#chunk-management)

---

## Protocol overview

**Source**: [FileTransfer/Protocol.hs](../../src/Simplex/FileTransfer/Protocol.hs)

XFTP separates file metadata from file content. A sender uploads encrypted chunks to one or more routers, then shares a file description (containing chunk locations, keys, and digests) with recipients via SMP messaging.

Key properties:
- File encrypted as a single stream with XSalsa20-Poly1305, then split into chunks
- Chunks are byte ranges of the encrypted file (not independently encrypted)
- Chunks can be replicated across multiple routers
- Recipients download chunks directly from routers
- Router never sees plaintext or file metadata

### Parties

| Party | Role | Authentication |
|-------|------|----------------|
| Sender | Creates file, uploads chunks, manages recipients | Per-file sender key |
| Recipient | Downloads chunks, acknowledges receipt | Per-recipient key (created by sender) |

### File description

The sender generates a `ValidFileDescription` containing:
- Chunk specifications: server address, recipient ID, recipient key, size, digest
- Encryption key and nonce for the full file
- File size and SHA-512 digest
- Optional redirect to another file description

---

## Router storage

**Source**: [FileTransfer/Server/Store.hs](../../src/Simplex/FileTransfer/Server/Store.hs)

### In-memory store

```haskell
data FileStore = FileStore
  { files :: TMap SenderId FileRec,
    recipients :: TMap RecipientId (SenderId, RcvPublicAuthKey),
    usedStorage :: TVar Int64
  }
```

- `files` maps sender IDs to file records
- `recipients` maps recipient IDs to (sender, auth key) for download authorization
- `usedStorage` tracks total bytes for quota enforcement

### File record

```haskell
data FileRec = FileRec
  { senderId :: SenderId,
    fileInfo :: FileInfo,           -- sndKey, size, digest
    filePath :: TVar (Maybe FilePath),  -- set after upload
    recipientIds :: TVar (Set RecipientId),
    createdAt :: RoundedFileTime,   -- truncated to 1-hour precision
    fileStatus :: TVar ServerEntityStatus
  }
```

The `filePath` is `Nothing` until FPUT completes. The file is stored at `filesPath/<base64url(senderId)>`.

### Quota management

File size is reserved atomically when FNEW is processed. If `usedStorage + fileSize > fileSizeQuota`, the request is rejected with QUOTA error. Storage is released when files are deleted or expire.

### File expiration

Files expire based on `ttl` configuration (default 48 hours). The expiration thread periodically scans files where `createdAt + fileTimePrecision < threshold`. Expired files are deleted from disk and removed from the store.

`fileTimePrecision` is 3600 seconds (1 hour), providing k-anonymity for file creation times.

---

## Protocol commands

**Source**: [FileTransfer/Protocol.hs](../../src/Simplex/FileTransfer/Protocol.hs), [FileTransfer/Server.hs](../../src/Simplex/FileTransfer/Server.hs)

### Command summary

| Command | Party | Purpose |
|---------|-------|---------|
| FNEW | Sender | Create file with metadata and initial recipient keys |
| FADD | Sender | Add recipient auth keys to existing file |
| FPUT | Sender | Upload encrypted chunk data |
| FDEL | Sender | Delete file from router |
| FGET | Recipient | Download file (initiates DH key exchange) |
| FACK | Recipient | Acknowledge download, remove recipient from file |
| PING | Recipient | Keepalive |

### FNEW - create file

Request: `FNEW FileInfo (NonEmpty RcvPublicAuthKey) (Maybe BasicAuth)`

- `FileInfo`: sender's auth key, file size (Word32), SHA-512 digest
- Recipient keys: one per intended recipient
- Optional basic auth for servers requiring authorization

Response: `FRSndIds SenderId (NonEmpty RecipientId)`

The router generates random sender ID and recipient IDs. The sender uses `SenderId` for subsequent commands; recipients receive their `RecipientId` via file description.

### FPUT - upload chunk

Request: `FPUT` with chunk data in HTTP/2 body

The router:
1. Validates sender authorization
2. Reserves storage quota
3. Receives encrypted chunk with timeout
4. Writes to `filesPath/<base64url(senderId)>`
5. Updates `filePath` in file record

If the file already has a `filePath` (re-upload), the body is discarded and `FROk` returned immediately.

### FGET - download chunk

Request: `FGET RcvPublicDhKey`

The recipient provides an ephemeral X25519 public key for DH agreement.

Response: `FRFile SrvPublicDhKey C.CbNonce` (server's ephemeral DH key and nonce)

The router:
1. Generates ephemeral DH key pair
2. Computes shared secret: `dh'(recipientDhKey, serverPrivKey)`
3. Initializes encryption state with shared secret and nonce
4. Streams encrypted file in HTTP/2 response body

The recipient uses the returned server DH key and nonce to decrypt the stream.

### FACK - acknowledge receipt

Request: `FACK`

Removes the recipient from the file's recipient set. Once all recipients have acknowledged, only the sender can access the file (until FDEL or expiration).

### FDEL - delete file

Request: `FDEL`

Deletes the file from disk and store, releases quota. All recipient IDs become invalid.

---

## Agent upload pipeline

**Source**: [FileTransfer/Agent.hs](../../src/Simplex/FileTransfer/Agent.hs), [FileTransfer/Chunks.hs](../../src/Simplex/FileTransfer/Chunks.hs)

### Upload state machine

```
SFSNew -> SFSEncrypting -> SFSEncrypted -> SFSUploading -> SFSComplete
                                                       \-> SFSError
```

### Phase 1: File preparation (SFSNew -> SFSEncrypted)

`prepareFile` encrypts the source file:

1. Generate random `SbKey` and `CbNonce`
2. Create encrypted file structure:
   - 8 bytes: encoded content length
   - FileHeader: filename and optional metadata (SMP-encoded)
   - File content: encrypted in 64KB streaming chunks
   - Padding: `'#'` characters to multiple of 16384 bytes
   - Auth tag: 16 bytes (Poly1305)
3. Compute SHA-512 digest of encrypted file
4. Calculate chunk boundaries via `prepareChunkSizes`

### Chunk size selection

`prepareChunkSizes` selects chunk sizes based on total file size:

| File size | Chunk size used |
|-----------|-----------------|
| > 3/4 of 4MB (~3.0MB) | 4MB chunks |
| > 3/4 of 1MB (768KB) | 1MB chunks |
| Otherwise | 64KB or 256KB |

The last chunk may be smaller than the standard size.

### Phase 2: Chunk registration

For each chunk:
1. Select XFTP server (different server per chunk recommended)
2. Send FNEW with chunk's digest and recipient keys
3. Store `SndFileChunkReplica` with server-assigned IDs
4. Status: `SFRSCreated`

### Phase 3: Upload (SFSUploading -> SFSComplete)

`uploadFileChunk` for each replica:
1. If not all recipients added: send FADD
2. Read chunk from encrypted file at (offset, size)
3. Send FPUT with chunk data
4. Update replica status to `SFRSUploaded`
5. Report progress to agent client

When all chunks uploaded: mark file `SFSComplete`, generate file description.

### Error handling

- Retry with exponential backoff per `reconnectInterval`
- Track consecutive retries per replica
- After `xftpConsecutiveRetries` failures: mark `SFSError`
- Delay and retry count stored in DB for resumption

---

## Agent download pipeline

**Source**: [FileTransfer/Agent.hs](../../src/Simplex/FileTransfer/Agent.hs)

### Download state machine

```
RFSReceiving -> RFSReceived -> RFSDecrypting -> RFSComplete
                                            \-> RFSError
```

### Phase 1: Chunk download (RFSReceiving -> RFSReceived)

`downloadFileChunk` for each chunk:
1. Verify server is in approved relays (if relay approval required)
2. Generate ephemeral DH key pair
3. Send FGET with public DH key
4. Receive `FRFile` with server's DH key and nonce
5. Compute shared secret, initialize decryption
6. Stream-decrypt chunk to `tmpPath/chunkNo`
7. Verify chunk's SHA-256 digest matches specification
8. Mark replica as `received`

Replicas are tried in order; if first fails, try next replica of same chunk.

### Phase 2: Reassembly (RFSReceived -> RFSComplete)

`decryptFile` reassembles and decrypts:
1. Concatenate all chunk files in order
2. Validate total size matches file digest
3. Decrypt with file's `SbKey` and `CbNonce`:
   - Parse length prefix and FileHeader
   - Stream-decrypt content
   - Verify auth tag
4. Write to final destination (`savePath`)
5. Delete temporary chunk files
6. Mark `RFSComplete`

### Redirect files

If the file description has a `redirect` field:
1. Decrypt the downloaded content
2. Parse as YAML file description
3. Validate size/digest match redirect specification
4. Register actual chunks from redirect description
5. Download from redirected sources

This enables indirection for large file descriptions or server migration.

---

## Chunk encryption

**Source**: [FileTransfer/Crypto.hs](../../src/Simplex/FileTransfer/Crypto.hs), [Messaging/Crypto/File.hs](../../src/Simplex/Messaging/Crypto/File.hs)

### File encryption (sender side)

```
[8-byte length][FileHeader][file content][padding][16-byte auth tag]
```

- Algorithm: XSalsa20-Poly1305 (NaCl secret_box)
- Key: random 32-byte `SbKey`
- Nonce: random 24-byte `CbNonce`
- Streaming: 64KB chunks encrypted incrementally
- Padding: `'#'` characters to align to 16384-byte boundary

### Chunk transport encryption (FGET)

Each FGET establishes a fresh DH shared secret:
1. Recipient generates ephemeral X25519 key pair
2. Sends public key in FGET request
3. Router generates ephemeral key pair
4. Both compute: `secret = dh(peerPubKey, ownPrivKey)`
5. Router streams chunk encrypted with `cbInit(secret, nonce)`
6. Recipient decrypts with same parameters

This provides forward secrecy per-download - compromising the file encryption key does not reveal transport keys.

### Auth tag verification

The 16-byte Poly1305 auth tag is verified after receiving all chunks:
- Single chunk: tag appended at end
- Multiple chunks: tag in final chunk, verified after concatenation

Failed auth tag verification produces `CRYPTO` error.

---

## Chunk management

**Source**: [FileTransfer/Types.hs](../../src/Simplex/FileTransfer/Types.hs)

### Sender chunk state

```haskell
data SndFileChunkReplica = SndFileChunkReplica
  { sndChunkReplicaId :: Int64,
    server :: XFTPServer,
    replicaId :: ChunkReplicaId,
    replicaKey :: C.APrivateAuthKey,
    rcvIdsKeys :: [(ChunkReplicaId, C.APrivateAuthKey)],
    replicaStatus :: SndFileReplicaStatus,
    delay :: Maybe Int64,
    retries :: Int
  }

data SndFileReplicaStatus = SFRSCreated | SFRSUploaded
```

- `SFRSCreated`: FNEW sent, replica registered on server
- `SFRSUploaded`: FPUT complete, chunk data stored
- `rcvIdsKeys`: recipient IDs and keys for this replica

### Recipient chunk state

```haskell
data RcvFileChunk = RcvFileChunk
  { rcvFileChunkId :: Int64,
    chunkNo :: Int,
    chunkSize :: Word32,
    digest :: ByteString,
    replicas :: [RcvFileChunkReplica],
    fileTmpPath :: FilePath,
    chunkTmpPath :: Maybe FilePath
  }

data RcvFileChunkReplica = RcvFileChunkReplica
  { rcvChunkReplicaId :: Int64,
    server :: XFTPServer,
    replicaId :: ChunkReplicaId,
    replicaKey :: C.APrivateAuthKey,
    received :: Bool,
    delay :: Maybe Int64,
    retries :: Int
  }
```

### Replica selection

Each chunk can have multiple replicas on different servers. The file description includes all replicas; the recipient:
1. Tries first replica
2. On failure, tries next replica
3. Continues until success or all replicas exhausted

This provides redundancy against server unavailability.

### Retry handling

Retry state is stored per-replica with two fields:
- `delay :: Maybe Int64` - milliseconds until next retry
- `retries :: Int` - consecutive failure count

On failure, delay increases with exponential backoff. State persists in DB for resumption after agent restart.

### Chunk sizes

```haskell
chunkSize0 = kb 64      -- 65536 bytes
chunkSize1 = kb 256     -- 262144 bytes
chunkSize2 = mb 1       -- 1048576 bytes
chunkSize3 = mb 4       -- 4194304 bytes

serverChunkSizes = [chunkSize0, chunkSize1, chunkSize2, chunkSize3]
```

Routers validate that uploaded chunks match one of the allowed sizes. This prevents fingerprinting based on exact file sizes.
