# Implementation plan: XFTP variable file storage time

Proposal: `../rfcs/2026-08-22-xftp-file-storage-time.md`.

## simplexmq: entitlement crypto

New module `Simplex.Messaging.Crypto.Entitlement`, over `Simplex.Messaging.Crypto.BBS`:

Types:

```
newtype MasterKey = MasterKey ByteString

data Entitlement = Entitlement
  { expiresAt :: UTCTime,
    entitlementName :: Text,
    extraInfo :: Text
  }

data EntitlementCredential = EntitlementCredential
  { issuerKeyIdx :: Word16,
    masterKey :: MasterKey,
    entitlement :: Entitlement,
    issuerSignature :: BBSSignature
  }

data EntitlementProof = EntitlementProof
  { issuerKeyIdx :: Word16,
    entitlement :: Entitlement,
    entProof :: BBSProof
  }
```

Functions and constants:

- the disclosed-message encoding: the master key is message 0 and stays undisclosed; `expiresAt`, `entitlementName`, and `extraInfo` are messages 1 to 3 and are disclosed. The protocol encoding of `Entitlement` and its field order follow the same order
- the BBS header string `"SimpleX badges v1"` (shared with chat's badges, which sign under it), the message count, and the disclosed indexes
- `generateEntitlementProof :: Map Word16 BBSPublicKey -> EntitlementCredential -> BBSPresHeader -> IO (Either String EntitlementProof)` (the issuer key is looked up by the credential's index; an absent index is `Left`)
- `verifyEntitlement :: Map Word16 BBSPublicKey -> BBSPresHeader -> EntitlementProof -> IO EntitlementVerification`, where `data EntitlementVerification = EVValid | EVInvalid | EVUnknownIssuer` (the caller supplies the presentation header; the server reconstructs it, the proof never includes it)
- the issuer public keys constant `Map Word16 BBSPublicKey`

## simplexmq: protocol, new XFTP version

In `Simplex.FileTransfer.Transport`:

- add the next `VersionXFTP` and set `currentXFTPVersion` to 4
- add `entitlementProof :: Maybe EntitlementProof` to `XFTPClientHandshake`, encoded before the `Tail` and only from this version
- the presentation header is the session id alone

In `Simplex.FileTransfer.Protocol`:

- add `GrantedStorageTime` and its encoding; retain the one-character sum prefix for future variants:

```
data GrantedStorageTime = GSTExpires {epochSeconds :: Int64}
```

- add the storage time (`Maybe Word32`: `Nothing` and `Just 0` request the server maximum, a value above zero requests that number of hours) to `FNEW`
- add the granted storage to `FRSndIds` as `Maybe GrantedStorageTime` (`Nothing` when decoding a response from a server below this version)

## simplexmq: server configuration

In `Simplex.FileTransfer.Server.Env` and `Simplex.FileTransfer.Server.Main`:

- make `fileExpiration` non-optional (`ExpirationConfig`, no longer `Maybe`); the server always expires files, so the server maximum is always a concrete number of seconds
- read a maximum storage time (a number of hours) for each entitlement name from the `[STORE_LOG]` INI section, from the keys `expire_files_hours_for_supporter` and `expire_files_hours_for_legend`, into `fileStorageEntitlements :: Map Text EntitlementConfig`, where `newtype EntitlementConfig = EntitlementConfig {storageTime :: Int64}` holds seconds; an absent key is skipped (that name gets the default), a present but malformed value fails startup
- exit at startup if any name's maximum is below the default file expiration
- add `entitlementKeys :: Map Word16 BBSPublicKey` to the server config (default = the shared constant, set from `Main`); the handshake verifies the proof against it, so the trusted keys never come from the sender

## simplexmq: server session

In `Simplex.FileTransfer.Server`:

- `processClientHandshake` verifies the proof from the handshake, once per session, and resolves the maximum storage time for the entitlement name. `HandshakeSent` carries `EntitlementChecked`, so the first handshake verifies and every later one on that connection reuses the result, including after `processHello` returns the session to `HandshakeSent`
- verify only when the answer can change: the name is configured (startup rejects a maximum below the default), and the entitlement expired less than 24 hours ago. A proof that fails these checks gets no verification; a proof that fails to verify is logged. In both cases the session gets the default maximum
- a verified proof becomes `peerEntitlement :: Maybe SessionEntitlement` in `THAuthServer`, where `data SessionEntitlement = SessionEntitlement {expiresAt :: SystemSeconds, entConfig :: EntitlementConfig}`; `processXFTPRequest` takes it from there, so no proof is verified while a command is processed
- `createFile` caps the requested storage time by the session maximum, which is the entitlement's storage time when the entitlement is still valid, and the default otherwise

## simplexmq: server store and expiration

The `files` table gets a nullable `expires_at`. Every new file stores a concrete `expires_at`. It is NULL only for pre-feature rows, which the migration must not re-date (it has no access to the operator's configured TTL); those are expired at query time as `created_at + ttl`.

Common to both stores, in `Simplex.FileTransfer.Server.Store`:

- add `expiresAt :: Maybe RoundedFileTime` to `FileRec`
- in `createFile`, cap the requested hours at the session maximum, round the expiry up to the hour, store it, and return that same value as the granted storage
- `expiredFiles` receives `now` and `old` (= `now - ttl`). A stored expiry is deleted when `expires_at < now` (no grace — it is already rounded up); a legacy row (no `expires_at`) is deleted when `created_at + fileTimePrecision < old` (the grace covers `created_at` being floored to the hour)
- retain `created_at` for statistics, export, and the legacy fallback

STM store:

- in `expiredFiles`, expire a new file when `roundedSeconds expiresAt < now`, and a legacy file (no `expiresAt`) when `created_at + fileTimePrecision < old`

PostgreSQL store, in `Simplex.FileTransfer.Server.Store.Postgres` and its migrations:

- add the nullable column `expires_at BIGINT` (no backfill)
- add one composite index `idx_files_expiry ON files (expires_at, created_at)`
- `expiredFiles` query: `(SELECT ... WHERE expires_at < ? LIMIT ?) UNION ALL (SELECT ... WHERE expires_at IS NULL AND created_at < ? LIMIT ?)` with `(now, limit, old - fileTimePrecision, limit)`. The first arm deletes stored (already rounded-up) expiries; the second drains legacy rows, with the grace folded into `old - fileTimePrecision` so the columns stay bare and sargable. Each arm is one range over the composite index and stops at its own limit; a single `OR` predicate builds a bitmap of every match before the limit applies. A `COALESCE(expires_at, created_at + ttl)` predicate is avoided (not sargable, would force a sequential scan). No `ORDER BY` — the batch loop deletes all expired rows regardless of order. New files always store an expiry, so the second arm drains permanently once the legacy rows expire, and is then removed.

Store log, in `Simplex.FileTransfer.Server.StoreLog`:

- add the optional expiration to the `AddFile` record; a record without it parses to `Nothing` (the configured default), never a hardcoded value

## simplexmq: agent

The credential belongs to the user, so the agent holds it the way it holds the user's servers: in memory, supplied when the agent is created and replaced through an API. It is not stored by the agent.

Per-user state in `Simplex.Messaging.Agent.Env.SQLite` and `Simplex.Messaging.Agent.Client`:

- add `entitlements :: Map UserId EntitlementCredential` to `InitialAgentServers`, beside the servers
- add `userEntitlements :: TMap UserId EntitlementCredential` to `AgentClient`, filled from it by `newAgentClient`
- add `entitlementKeys :: Map Word16 BBSPublicKey` to `AgentConfig` (default = the shared constant), for the issuer key that proof generation needs

Public API in `Simplex.Messaging.Agent`:

- add storage time (`Maybe Word32` hours) to `xftpSendFile`
- add `setUserEntitlement :: AgentClient -> UserId -> Maybe EntitlementCredential -> IO ()`, in the shape of `setProtocolServers`: it replaces the entry, and when the credential changed it closes that user's XFTP clients, so the next upload presents the new credential

Store, in both the SQLite and PostgreSQL agent stores:

- add a nullable storage time column (integer hours; NULL means the server maximum) to `snd_files`
- add the migration to both stores
- in `createSndFile`, store the storage time

Upload, in `Simplex.Messaging.Agent.Client` and `Simplex.FileTransfer.Client`:

- `getXFTPClient` takes a proof for the session as a parameter, `SessionId -> IO (Maybe EntitlementProof)`, beside the callback it already takes for a closed client. The client config holds no credential and no keys
- `getXFTPServerClient` passes a function that reads the user's credential and generates the proof over the session id from the configured issuer keys. A missing credential or a failure to generate gives `Nothing`, with the failure logged
- `xftpClientHandshakeV1` calls it with the session id from the connection, and sends the result in the handshake
- `agentXFTPNewChunk` reads the storage time from the send record and sends FNEW with it
- `createXFTPChunk` returns the granted expiry (epoch seconds); `agentXFTPNewChunk` stores it on `NewSndChunkReplica`

Completion:

- `createXFTPChunk` returns the granted expiry as `Maybe GrantedStorageTime`; `SndFileChunkReplica` and `NewSndChunkReplica` carry `expiresAt :: Maybe GrantedStorageTime`
- persist it in a nullable `replica_expires_at` column on `snd_file_chunk_replicas` (added to the entitlement migration): `createSndFileReplica` stores `epochSeconds`, `getSndFile` and `getNextSndChunkToUpload` read it back into `GSTExpires`
- on `SFDONE`, report the file expiry: a chunk expires when its last replica expires (`max` over replicas, absent replicas ignored, `Nothing` only if none report); the file expires when its first chunk expires (`min` over chunks, `Nothing` if any chunk is unknown). `GrantedStorageTime` derives `Ord`
- `SFDONE` gains a trailing `Maybe GrantedStorageTime` (not str-encoded); chat consumes it (wired later)

Testing:

- e2e test in `tests/XFTPAgent.hs`: generate a BBS keypair, sign a supporter credential (issuer key index 1), run the server with `entitlementKeys = {1: testPk}` and a supporter maximum above the default, run the sender agent with the same `entitlementKeys` and the credential for the user, send a file requesting a number of hours above the default and below that maximum, and assert `SFDONE`'s granted expiry rounds up `now + requested` (proof of the entitlement raising the max above the default)
- the same upload without the credential is capped at the default maximum
- store log round trip in `tests/CoreTests/StoreLogTests.hs`, in the shape of the SMP store log test: a file record survives a write, a read into the store, and compaction, including a file blocked with a notice, where the record has a field after the blocking info

## simplex-chat

- remove lifetime badges: make `badgeExpiry` a `UTCTime`, drop the `"lifetime"` encoding, and remove the lifetime option from the UI and the CLI
- map `BadgeInfo` to `Entitlement` (`entitlementName = textEncode badgeType`, `expiresAt = badgeExpiry`, `extraInfo = badgeExtra`) when calling the agent
- pass the user's credential to the agent when it is created, and through `setUserEntitlement` when the badge changes, in the same places that pass and update the user's servers
- pass the storage time to `xftpSendFile`
- retain the `maxXFTPFileSize` size limit
- reuse `verifyEntitlement` for peer-badge verification
- import the issuer public keys from the shared simplexmq constant

## State

Steps 2 to 5 are implemented in simplexmq. Step 1 and step 6 belong to the chat branch that carries badges.

## Order

1. Add the entitlement crypto module; move chat's badge verification onto it and remove lifetime badges.
2. Add the new XFTP version, the FNEW storage time, and the response.
3. Change the server configuration, store, expiration, and store log.
4. Move the proof to the handshake: the handshake field, the session state on the server, and the proof for the session on the client.
5. Hold the credential per user in the agent, and add the API to replace it.
6. Wire chat to pass the credential and the storage time.
