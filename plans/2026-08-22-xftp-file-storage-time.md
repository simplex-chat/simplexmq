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
data FileStorageTime = FSTMax | FSTFor Word32   -- FSTMax may resolve to permanent; FSTFor: hours
```

- add the `FileStorageTime` and `Maybe EntitlementProof` fields to `FNEW`, and add `FTTL`
- add the expiration to `FRSndIds`, and add a new response for `FTTL`
- build the presentation header for FNEW and for FTTL

In `Simplex.FileTransfer.Server`:

- pass `sessionId` from `thParams` into `processXFTPRequest`

## simplexmq: server configuration

In `Simplex.FileTransfer.Server.Env` and `Simplex.FileTransfer.Server.Main`:

- read a maximum storage time for each entitlement name, and a default maximum, from the INI file, where each maximum is a number of hours or permanent
- exit at startup if any name's maximum is below the default
- read the issuer public keys from the shared constant

## simplexmq: server store and expiration

The `files` table gets a nullable `expires_at` and a `permanent BOOLEAN NOT NULL DEFAULT false`. `expires_at IS NULL` means "no explicit expiry — apply the configured default" (`created_at + ttl`); this covers legacy rows, which the migration must not re-date, since it has no access to the operator's configured TTL. `permanent = true` means the file never expires and keeps `expires_at` NULL, so a legacy row and a permanent row are distinguished by the flag, not by overloading NULL. The flag is also directly queryable for analytics.

Common to both stores, in `Simplex.FileTransfer.Server.Store`:

- add `expiresAt :: Maybe RoundedFileTime` and `permanent :: Bool` to `FileRec`
- in `createFile`, verify the proof against `sessionId <> sndKey <> digest`, resolve the requested time against the entitlement's maximum, and store `expiresAt`/`permanent` from the resolution (permanent when the ceiling is unbounded); return the granted storage
- add the FTTL handler, which verifies the proof against `sessionId <> sndKey <> digest`, sets `expiresAt`/`permanent` by the same resolution, and returns it
- `expiredFiles` takes the configured default TTL and expires a non-permanent file when `COALESCE(expiresAt, created_at + ttl) < now`
- retain `created_at` for statistics, export, and the default-expiry fallback

STM store:

- in `expiredFiles`, expire a file when `not permanent && maybe (created_at + ttl) roundedSeconds expiresAt < now`

PostgreSQL store, in `Simplex.FileTransfer.Server.Store.Postgres` and its migrations:

- add the nullable column `expires_at BIGINT` and `permanent BOOLEAN NOT NULL DEFAULT FALSE` (no backfill)
- add one composite index `idx_files_expiry ON files (permanent, expires_at, created_at)`
- `expiredFiles` query: `WHERE (NOT permanent AND expires_at < ?) OR (NOT permanent AND expires_at IS NULL AND created_at < ?) LIMIT ?` with `(now, now - ttl)`. Keep the `OR` at the top level so each disjunct is independently indexable (BitmapOr on the one composite index): `permanent` leads (equality seek skips permanent rows), `expires_at` covers arm 1's range and arm 2's `IS NULL` group, and `created_at` orders arm 2 within that group. A `COALESCE(expires_at, created_at + ttl)` predicate is avoided (not sargable, would force a sequential scan). No `ORDER BY` — the batch loop deletes all expired rows regardless of order.

Store log, in `Simplex.FileTransfer.Server.StoreLog`:

- add the `permanent` flag and the optional expiration to the `AddFile` record; a record with neither parses to `False`/`Nothing` (the configured default), never a hardcoded value
- for older records without an expiration, default `expiresAt` to `createdAt + default storage time`

## simplexmq: agent

Public API in `Simplex.Messaging.Agent`:

- add `Maybe EntitlementCredential` and `FileStorageTime` parameters to `xftpSendFile` and `xftpSendDescription`
- add a set-time API for FTTL that operates per chunk, using the sender description

Store, in both the SQLite and PostgreSQL agent stores:

- add a nullable entitlement credential column and a storage time column to `snd_files`
- add the migration to both stores
- in `createSndFile`, store the credential and the storage time

Upload, in `Simplex.Messaging.Agent.Client` and `Simplex.FileTransfer.Client`:

- in `agentXFTPNewChunk`, read the credential, the storage time, and the digest from the send record
- inside `withClient`, where `sessionId` is available, build the presentation header `sessionId <> sndKey <> digest`, generate the proof, and send FNEW with the storage time and the proof
- discard the returned expiration for now

Set-time:

- for a completed file, generate a per-chunk proof bound to `sessionId <> sndKey <> digest` and send FTTL, authorized with the sender key

## simplex-chat

- remove lifetime badges: make `badgeExpiry` a `UTCTime`, drop the `"lifetime"` encoding, and remove the lifetime option from the UI and the CLI
- map `BadgeInfo` to `Entitlement` (`entitlementName = textEncode badgeType`, `expiresAt = badgeExpiry`, `extraInfo = badgeExtra`) when calling the agent
- pass the user's credential and `FSTMax` to `xftpSendFile`
- retain the `maxXFTPFileSize` size limit
- reuse `verifyEntitlement` for peer-badge verification
- import the issuer public keys from the shared simplexmq constant

## Order

1. Add the entitlement crypto module; move chat's badge verification onto it and remove lifetime badges.
2. Add `FileStorageTime`, the new XFTP version, the FNEW and FTTL protocol changes, and the responses.
3. Change the server configuration, store, expiration, and store log.
4. Change the agent store, add proof generation on upload, and add the set-time API.
5. Wire chat to pass the credential and the storage time.
