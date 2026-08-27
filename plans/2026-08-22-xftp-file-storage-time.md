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

- add `GrantedStorageTime` and its encoding; retain the one-character sum prefix for future variants:

```
data GrantedStorageTime = GSTExpires {epochSeconds :: Int64}
```

- add the storage time (`Maybe Int64`: `Nothing` requests the server maximum, `Just` a number of hours) and `Maybe EntitlementProof` fields to `FNEW`
- add the granted storage to `FRSndIds` as `Maybe GrantedStorageTime` (`Nothing` when decoding a response from a server below this version)
- build the presentation header for FNEW

In `Simplex.FileTransfer.Server`:

- pass `sessionId` from `thParams` into `processXFTPRequest`

## simplexmq: server configuration

In `Simplex.FileTransfer.Server.Env` and `Simplex.FileTransfer.Server.Main`:

- make `fileExpiration` non-optional (`ExpirationConfig`, no longer `Maybe`); the server always expires files, so the server maximum is always a concrete number of seconds
- read a maximum storage time (a number of hours) for each entitlement name from the `[STORE_LOG]` INI section, from the keys `expire_files_hours_for_supporter` and `expire_files_hours_for_legend`
- exit at startup if any name's maximum is below the default file expiration
- read the issuer public keys from the shared constant

## simplexmq: server store and expiration

The `files` table gets a nullable `expires_at`. Every new file stores a concrete `expires_at`. It is NULL only for pre-feature rows, which the migration must not re-date (it has no access to the operator's configured TTL); those are expired at query time as `created_at + ttl`.

Common to both stores, in `Simplex.FileTransfer.Server.Store`:

- add `expiresAt :: Maybe RoundedFileTime` to `FileRec`
- in `createFile`, verify the proof against `sessionId <> sndKey <> digest`, cap the requested hours at the entitlement's maximum, round the expiry up to the hour, store it, and return that same value as the granted storage
- a valid proof raises the maximum to the entitlement's configured value; a proof that fails verification, carries an unknown issuer key, or whose entitlement expired more than 24 hours ago falls back to the default maximum. The entitlement is honoured for 24 hours after its `expiresAt`.
- `expiredFiles` receives `now` and `old` (= `now - ttl`). A stored expiry is deleted when `expires_at < now` (no grace — it is already rounded up); a legacy row (no `expires_at`) is deleted when `created_at + fileTimePrecision < old` (the grace covers `created_at` being floored to the hour)
- retain `created_at` for statistics, export, and the legacy fallback

STM store:

- in `expiredFiles`, expire a new file when `roundedSeconds expiresAt < now`, and a legacy file (no `expiresAt`) when `created_at + fileTimePrecision < old`

PostgreSQL store, in `Simplex.FileTransfer.Server.Store.Postgres` and its migrations:

- add the nullable column `expires_at BIGINT` (no backfill)
- add one composite index `idx_files_expiry ON files (expires_at, created_at)`
- `expiredFiles` query: `WHERE (expires_at < ?) OR (expires_at IS NULL AND created_at < ?) LIMIT ?` with `(now, old - fileTimePrecision)`. The first arm deletes stored (already rounded-up) expiries; the second drains legacy rows, with the grace folded into `old - fileTimePrecision` so the columns stay bare and sargable. Keep the `OR` at the top level so each disjunct is independently indexable (BitmapOr on the composite index): `expires_at` covers arm 1's range and arm 2's `IS NULL` group, and `created_at` orders arm 2 within that group. A `COALESCE(expires_at, created_at + ttl)` predicate is avoided (not sargable, would force a sequential scan). No `ORDER BY` — the batch loop deletes all expired rows regardless of order.

Store log, in `Simplex.FileTransfer.Server.StoreLog`:

- add the optional expiration to the `AddFile` record; a record without it parses to `Nothing` (the configured default), never a hardcoded value

## simplexmq: agent

Public API in `Simplex.Messaging.Agent`:

- add `Maybe EntitlementCredential` and storage time (`Maybe Int64` hours) parameters to `xftpSendFile`

Store, in both the SQLite and PostgreSQL agent stores:

- add a nullable entitlement credential column (JSON text) and a nullable storage time column (integer hours; NULL means the server maximum) to `snd_files`
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
2. Add the new XFTP version, the FNEW protocol change (storage time + proof), and the response.
3. Change the server configuration, store, expiration, and store log.
4. Change the agent store and add proof generation on upload.
5. Wire chat to pass the credential and the storage time.
