# Simplex.FileTransfer.Protocol

> XFTP protocol types, commands, responses, and credential verification.

**Source**: [`FileTransfer/Protocol.hs`](../../../../src/Simplex/FileTransfer/Protocol.hs)

## Non-obvious behavior

### 1. Asymmetric credential checks by command

`checkCredentials` enforces different rules per command:
- **FNEW**: requires `auth` (signature) but must NOT have a `fileId` — the sender key from the command body is used for verification
- **PING**: must have NEITHER `auth` NOR `fileId` — actively rejects their presence
- **All others** (FADD, FPUT, FDEL, FGET, FACK): require both `fileId` AND auth key

This asymmetry means FNEW and PING bypass the standard entity-lookup path entirely — they are handled as separate `XFTPRequest` constructors (`XFTPReqNew`, `XFTPReqPing`).

### 2. BLOCKED response downgraded to AUTH for old clients

`encodeProtocol` checks the protocol version: if `v < blockedFilesXFTPVersion`, a `BLOCKED` response is encoded as `AUTH` instead. This prevents old clients that don't understand `BLOCKED` from receiving an unknown error type. The blocking information is silently lost for these clients.

### 3. Single-transmission batch enforcement

`xftpDecodeTServer` calls `xftpDecodeTransmission` which rejects batches containing more than one transmission. Despite using the batch framing format (length-prefixed), XFTP requires exactly one command per request. This differs from SMP where true batching is supported.

### 4. xftpEncodeBatch1 always uses batch framing

Even for single transmissions, `xftpEncodeBatch1` wraps the encoded transmission in batch format (1-byte count prefix + 2-byte length-prefixed transmission). There is no "non-batch" mode in XFTP — all protocol messages use the batch wire format regardless of the negotiated version.

### 5. FileParty GADT partitions command space

Commands are indexed by `FileParty` (`SFSender` / `SFRecipient`) at the type level via `FileCmd`. This ensures at compile time that sender commands (FNEW, FADD, FPUT, FDEL) and recipient commands (FGET, FACK, PING) cannot be confused. The router pattern-matches on `SFileParty` to determine which index (sender vs recipient) to look up in the file store.

### 6. Empty corrId and implicit session ID

`sendXFTPCommand` in the client uses an empty bytestring as `corrId`. This empty value is passed to `C.cbNonce` to produce a constant nonce for command authentication (HMAC/signing). With `implySessId = False` in the default XFTP transport setup, the session ID is not prepended to entity IDs during parsing. Session identity is provided by the TLS connection itself.
