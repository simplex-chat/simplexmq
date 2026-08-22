# Implementation plan: XFTP variable file storage time

Proposal: `../rfcs/2026-08-22-xftp-file-storage-time.md`.

## simplexmq: entitlement crypto

New module `Simplex.Messaging.Crypto.Entitlement`, over `Simplex.Messaging.Crypto.BBS`:

Types:

```
newtype EntitlementSecret = EntitlementSecret ByteString

data Entitlement = Entitlement
  { level :: Text,
    expiresAt :: UTCTime,
    extraInfo :: Text
  }

data EntitlementCredential = EntitlementCredential
  { issuerKeyIdx :: Int,
    holderSecret :: EntitlementSecret,
    signature :: BBSSignature,
    entitlement :: Entitlement
  }

data EntitlementProof = EntitlementProof
  { issuerKeyIdx :: Int,
    presHeader :: BBSPresHeader,
    proof :: BBSProof,
    entitlement :: Entitlement
  }
```

Functions and constants:

- the disclosed-message encoding: the holder secret is message 0 and stays undisclosed; `expiresAt`, `level`, and `extraInfo` are messages 1 to 3 and are disclosed
- the BBS header string `"SimpleX entitlement v1"`, the message count, and the disclosed indexes
- `generateEntitlementProof :: BBSPublicKey -> EntitlementCredential -> BBSPresHeader -> IO (Either String EntitlementProof)`
- `verifyEntitlement :: Map Int BBSPublicKey -> EntitlementProof -> IO (Maybe Bool)`
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

- read a maximum storage time for each entitlement level, and a default maximum, from the INI file, where each maximum is a number of hours or permanent
- exit at startup if any level maximum is below the default
- read the issuer public keys from the shared constant

## simplexmq: server store and expiration

Common to both stores, in `Simplex.FileTransfer.Server.Store`:

- add `expiresAt :: Maybe RoundedFileTime` to `FileRec`, where `Nothing` is permanent storage
- in `createFile`, verify the proof against `sessionId <> sndKey <> digest`, resolve the requested time against the level maximum (a permanent maximum is unbounded), set `expiresAt` to the resolved expiration or `Nothing` when the result is permanent, and return it
- add the FTTL handler, which verifies the proof against `sessionId <> senderId`, sets `expiresAt` by the same resolution, and returns it
- retain `created_at` for statistics and export

STM store:

- in `expiredFiles`, select files where `expiresAt` is `Just t` and `t < now`

PostgreSQL store, in `Simplex.FileTransfer.Server.Store.Postgres` and its migrations:

- add the nullable column `expires_at BIGINT`, where `NULL` is permanent storage
- add a migration for the column and the index `idx_files_expires_at`
- change the `expiredFiles` query to `WHERE expires_at < ? ORDER BY expires_at LIMIT ?` (a `NULL` expiration is excluded by the comparison)

Store log, in `Simplex.FileTransfer.Server.StoreLog`:

- add the optional expiration to the `AddFile` record, encoding permanent storage
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

- for a completed file, generate a per-chunk proof bound to `sessionId <> senderId` and send FTTL, authorized with the sender key

## simplex-chat

- remove lifetime badges: make `badgeExpiry` a `UTCTime`, drop the `"lifetime"` encoding, and remove the lifetime option from the UI and the CLI
- map `BadgeInfo` to `Entitlement` (`level = textEncode badgeType`, `expiresAt = badgeExpiry`, `extraInfo = badgeExtra`) when calling the agent
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
