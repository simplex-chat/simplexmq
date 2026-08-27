# Implementation plan: XFTP variable file storage time

Proposal: `../rfcs/2026-08-22-xftp-file-storage-time.md`.

## simplexmq: entitlement crypto

New module `Simplex.Messaging.Crypto.Entitlement`, over `Simplex.Messaging.Crypto.BBS`:

Types:

```
newtype MasterKey = MasterKey ByteString

data Entitlement = Entitlement
  { entitlementName :: Text,
    expiresAt :: UTCTime,
    extraInfo :: Text
  }

data EntitlementCredential = EntitlementCredential
  { issuerKeyIdx :: Int,
    masterKey :: MasterKey,
    issuerSignature :: BBSSignature,
    entitlement :: Entitlement
  }

data EntitlementProof = EntitlementProof
  { issuerKeyIdx :: Int,
    proof :: BBSProof,
    entitlement :: Entitlement
  }
```

Functions and constants:

- the disclosed-message encoding: the master key is message 0 and stays undisclosed; `expiresAt`, `entitlementName`, and `extraInfo` are messages 1 to 3 and are disclosed
- the BBS header string `"SimpleX entitlement v1"`, the message count, and the disclosed indexes
- `generateEntitlementProof :: BBSPublicKey -> EntitlementCredential -> BBSPresHeader -> IO (Either String EntitlementProof)`
- `verifyEntitlement :: Map Int BBSPublicKey -> BBSPresHeader -> EntitlementProof -> IO (Maybe Bool)` (the caller supplies the presentation header; the server reconstructs it, the proof never includes it)
- the issuer public keys constant `Map Int BBSPublicKey`

## simplexmq: protocol, new XFTP version

In `Simplex.FileTransfer.Transport`:

- add the next `VersionXFTP` and set `currentXFTPVersion` to 4

In `Simplex.FileTransfer.Protocol`:

- add `FileStorageTime` and its encoding:

```
data FileStorageTime = FSMaxTime | FSTime {hours :: Word32}
```

- add `GrantedStorageTime` and its encoding; retain the one-character sum prefix for future variants:

```
data GrantedStorageTime = GSTExpires {epochSeconds :: Int64}
```

- add the `FileStorageTime` and `Maybe EntitlementProof` fields to `FNEW`
- add the granted storage to `FRSndIds`
- build the presentation header for FNEW

In `Simplex.FileTransfer.Server`:

- pass `sessionId` from `thParams` into `processXFTPRequest`

## simplexmq: server configuration

In `Simplex.FileTransfer.Server.Env` and `Simplex.FileTransfer.Server.Main`:

- read a maximum storage time for each entitlement name from the INI file, as a number of hours
- exit at startup if any name's maximum is below the default file expiration
- read the issuer public keys from the shared constant

## simplexmq: server store and expiration

The `files` table gets a nullable `expires_at`. `expires_at IS NULL` means "no explicit expiry — apply the configured default" (`created_at + ttl`); this covers legacy rows, which the migration must not re-date, since it has no access to the operator's configured TTL.

Common to both stores, in `Simplex.FileTransfer.Server.Store`:

- add `expiresAt :: Maybe RoundedFileTime` to `FileRec`
- in `createFile`, verify the proof against `sessionId <> sndKey <> digest`, resolve the requested time against the entitlement's maximum, store `expiresAt` from the resolution, and return the granted storage
- `expiredFiles` takes the configured default TTL and expires a file when `COALESCE(expiresAt, created_at + ttl) < now`
- retain `created_at` for statistics, export, and the default-expiry fallback

STM store:

- in `expiredFiles`, expire a file when `maybe (created_at + ttl) roundedSeconds expiresAt < now`

PostgreSQL store, in `Simplex.FileTransfer.Server.Store.Postgres` and its migrations:

- add the nullable column `expires_at BIGINT` (no backfill)
- add one composite index `idx_files_expiry ON files (expires_at, created_at)`
- `expiredFiles` query: `WHERE (expires_at < ?) OR (expires_at IS NULL AND created_at < ?) LIMIT ?` with `(now, now - ttl)`. Keep the `OR` at the top level so each disjunct is independently indexable (BitmapOr on the composite index): `expires_at` covers arm 1's range and arm 2's `IS NULL` group, and `created_at` orders arm 2 within that group. A `COALESCE(expires_at, created_at + ttl)` predicate is avoided (not sargable, would force a sequential scan). No `ORDER BY` — the batch loop deletes all expired rows regardless of order.

Store log, in `Simplex.FileTransfer.Server.StoreLog`:

- add the optional expiration to the `AddFile` record; a record without it parses to `Nothing` (the configured default), never a hardcoded value

## simplexmq: agent

Public API in `Simplex.Messaging.Agent`:

- add `Maybe EntitlementCredential` and `FileStorageTime` parameters to `xftpSendFile` and `xftpSendDescription`

Store, in both the SQLite and PostgreSQL agent stores:

- add a nullable entitlement credential column and a storage time column to `snd_files`
- add the migration to both stores
- in `createSndFile`, store the credential and the storage time

Upload, in `Simplex.Messaging.Agent.Client` and `Simplex.FileTransfer.Client`:

- in `agentXFTPNewChunk`, read the credential, the storage time, and the digest from the send record
- inside `withClient`, where `sessionId` is available, build the presentation header `sessionId <> sndKey <> digest`, generate the proof, and send FNEW with the storage time and the proof
- discard the returned expiration for now

## simplex-chat

- remove lifetime badges: make `badgeExpiry` a `UTCTime`, drop the `"lifetime"` encoding, and remove the lifetime option from the UI and the CLI
- map `BadgeInfo` to `Entitlement` (`entitlementName = textEncode badgeType`, `expiresAt = badgeExpiry`, `extraInfo = badgeExtra`) when calling the agent
- pass the user's credential and `FSMaxTime` to `xftpSendFile`
- retain the `maxXFTPFileSize` size limit
- reuse `verifyEntitlement` for peer-badge verification
- import the issuer public keys from the shared simplexmq constant

## Order

1. Add the entitlement crypto module; move chat's badge verification onto it and remove lifetime badges.
2. Add `FileStorageTime`, the new XFTP version, the FNEW protocol change, and the response.
3. Change the server configuration, store, expiration, and store log.
4. Change the agent store and add proof generation on upload.
5. Wire chat to pass the credential and the storage time.
