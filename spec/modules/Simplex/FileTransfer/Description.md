# Simplex.FileTransfer.Description

> File description: YAML encoding/decoding, validation, URI format, and replica optimization.

**Source**: [`FileTransfer/Description.hs`](../../../../src/Simplex/FileTransfer/Description.hs)

## Non-obvious behavior

### 1. ValidFileDescription non-exported constructor

`ValidFileDescription` is a newtype with a non-exported data constructor (`ValidFD`), but the module exports a bidirectional pattern synonym `ValidFileDescription` that can be used as a constructor. Despite this, `validateFileDescription` provides the canonical validation path, checking:
- Chunk numbers are sequential starting from 1
- Total chunk sizes equal the declared file size

Note: an empty chunk list with size 0 passes validation — there is no explicit "at least one chunk" check.

### 2. First-replica-only digest and chunkSize

When encoding chunks to YAML via `unfoldChunksToReplicas`, the `digest` and non-default `chunkSize` fields are only included on the first replica of each chunk. Subsequent replicas of the same chunk omit these fields. `foldReplicasToChunks` reconstructs them by carrying forward the digest/size from the first replica. If replicas have conflicting digests or sizes, validation fails.

### 3. Default chunkSize elision

The top-level `FileDescription` has a `chunkSize` field. Individual chunk replicas only serialize their `chunkSize` if it differs from this default. This saves space in the common case where most chunks are the same size (only the last chunk may be smaller).

### 4. YAML encoding groups replicas by server

`groupReplicasByServer` groups all chunk replicas by their server, producing `FileServerReplica` records. This is the serialization format — replicas are organized by server, not by chunk. The parser (`foldReplicasToChunks`) reverses this grouping back to per-chunk replica lists.

### 5. FileDescriptionURI uses query-string encoding

`FileDescriptionURI` serializes file descriptions into a compact query-string format (key=value pairs separated by `&`) with `QEscape` encoding for binary values. This is distinct from the YAML format used for file-based descriptions. The URI format is designed for embedding in links.

### 6. QR code size limit

`qrSizeLimit = 1002` bytes limits the maximum size of a file description URI that can be encoded as a QR code. Descriptions exceeding this limit cannot be shared via QR code and require alternative transport.

### 7. Soft and hard file size limits

Two limits exist: `maxFileSize = 1GB` (soft limit, checked by CLI client) and `maxFileSizeHard = 5GB` (hard limit, checked during agent-side encryption). The soft limit is a user-facing guard; the hard limit prevents resource exhaustion during encryption.

### 8. Redirect file descriptions

A `FileDescription` can contain a `redirect` field pointing to another file's metadata (`RedirectFileInfo` with size and digest). The outer description downloads an encrypted YAML file that, once decrypted, yields the actual `FileDescription` for the real file. This adds one level of indirection for privacy — the relay servers hosting the redirect don't know the actual file's servers.
