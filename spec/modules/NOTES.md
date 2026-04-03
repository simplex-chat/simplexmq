# Design Notes

Non-bug observations from module specs that are worth tracking. These remain documented in their respective module specs — this file serves as an index.

## Backend Observations

### N-01: SNotifier path doesn't cache

**Location**: `Simplex.Messaging.Server.QueueStore.Postgres` — `getQueues_` SNotifier branch
**Description**: The SRecipient path caches loaded queues via `cacheRcvQueue` with double-check locking. The SNotifier path does NOT cache — it uses a stale TMap snapshot and `maybe (mkQ False rId qRec) pure`, so concurrent loads for the same notifier can create duplicate ephemeral queue objects. Functionally correct but wasteful.
**Module spec**: [QueueStore/Postgres.md](Simplex/Messaging/Server/QueueStore/Postgres.md)

### N-02: assertUpdated error conflation

**Location**: `Simplex.Messaging.Server.QueueStore.Postgres` — `assertUpdated`
**Description**: `assertUpdated` returns `AUTH` for zero-rows-affected. This is the same error code used for "not found" (via `readQueueRecIO`) and "duplicate" (via `handleDuplicate`). The actual cause — stale cache, deleted queue, or constraint violation — is indistinguishable in logs.
**Module spec**: [QueueStore/Postgres.md](Simplex/Messaging/Server/QueueStore/Postgres.md)

## Design Characteristics

### N-03: RCVerifiedInvitation constructor exported

**Location**: `Simplex.RemoteControl.Invitation` — `RCVerifiedInvitation`
**Description**: `RCVerifiedInvitation` is a newtype with constructor exported via `(..)`. It can be constructed without calling `verifySignedInvitation`, bypassing signature verification. The trust boundary is conventional, not enforced by the type system. `connectRCCtrl` accepts only `RCVerifiedInvitation`.
**Module spec**: [RemoteControl/Invitation.md](Simplex/RemoteControl/Invitation.md)

### N-04: smpEncode Word16 silent truncation

**Location**: `Simplex.Messaging.Encoding` — `Encoding Word16` instance
**Description**: `smpEncode` for ByteString uses a 1-byte length prefix. Maximum encodable length is 255 bytes. Longer values silently wrap via `w2c . fromIntegral`. Callers must ensure ByteStrings fit or use `Large`.
**Module spec**: [Encoding.md](Simplex/Messaging/Encoding.md)

### N-05: writeIORef for period stats — not atomic

**Location**: `Simplex.Messaging.Server.Stats` — `setPeriodStats`
**Description**: Uses `writeIORef` (not atomic). Only safe during router startup when no other threads are running. If called concurrently, period data could be corrupted.
**Module spec**: [Server/Stats.md](Simplex/Messaging/Server/Stats.md)

### N-06: setStatsByServer orphans old TVars

**Location**: `Simplex.Messaging.Notifications.Server.Stats` — `setStatsByServer`
**Description**: Builds a fresh `Map Text (TVar Int)` in IO, then atomically replaces the TMap's root TVar. Old per-router TVars are not reused — any other thread holding a reference from a prior `TM.lookupIO` would modify an orphaned counter. Called at startup, but lacks the explicit "not thread safe" comment.
**Module spec**: [Notifications/Server/Stats.md](Simplex/Messaging/Notifications/Server/Stats.md)

### N-07: Lazy.unPad doesn't validate data length

**Location**: `Simplex.Messaging.Crypto.Lazy` — `unPad` / `splitLen`
**Description**: `splitLen` does not validate that the remaining data is at least `len` bytes — `LB.take len` silently returns a shorter result. The source comment notes this is intentional to avoid consuming all lazy chunks for validation.
**Module spec**: [Crypto/Lazy.md](Simplex/Messaging/Crypto/Lazy.md)

### N-08: Batched commands have no timeout-based expiry

**Location**: `Simplex.Messaging.Client` — `sendBatch`
**Description**: Batched commands are written with `Nothing` as the request parameter — the send thread skips the `pending` flag check. Individual commands have timeout-based expiry. If the router stops returning results, batched commands can block the send queue indefinitely.
**Module spec**: [Client.md](Simplex/Messaging/Client.md)

### N-09: Postgres MsgStore nanosecond precision

**Location**: `Simplex.Messaging.Server.MsgStore.Postgres` — `toMessage`
**Description**: `MkSystemTime ts 0` constructs timestamps with zero nanoseconds. Only whole seconds are stored. Messages read from Postgres have coarser timestamps than STM/Journal stores. Not a practical issue — timestamps are typically rounded to hours or days.
**Module spec**: [Server/MsgStore/Postgres.md](Simplex/Messaging/Server/MsgStore/Postgres.md)

### N-10: MsgStore Postgres — error stubs crash at runtime

**Location**: `Simplex.Messaging.Server.MsgStore.Postgres` — multiple `MsgStoreClass` methods
**Description**: Multiple `MsgStoreClass` methods are `error "X not used"`. Required by the type class but not applicable to Postgres. Calling any at runtime crashes. Safe because Postgres overrides the relevant default methods, but a new caller using the wrong method would crash with no compile-time warning.
**Module spec**: [Server/MsgStore/Postgres.md](Simplex/Messaging/Server/MsgStore/Postgres.md)

### N-11: strP default assumes base64url for all types

**Location**: `Simplex.Messaging.Encoding.String` — `StrEncoding` class default
**Description**: The `MINIMAL` pragma allows defining only `strDecode` without `strP`. The default `strP = strDecode <$?> base64urlP` assumes input is base64url-encoded for any type. A new `StrEncoding` instance that defines only `strDecode` for non-base64 data would get a broken parser.
**Module spec**: [Encoding/String.md](Simplex/Messaging/Encoding/String.md)

## Silent Behaviors

Intentional design choices that are correct but non-obvious. A code modifier who doesn't know these could introduce bugs.

### N-12: Service signing silently skipped on empty authenticator

**Location**: `Simplex.Messaging.Client` — service signature path
**Description**: The service signature is only added when the entity authenticator is non-empty. If authenticator generation fails silently (returns empty bytes), service signing is silently skipped.
**Module spec**: [Client.md](Simplex/Messaging/Client.md)

### N-13: stmDeleteNtfToken — nonexistent token indistinguishable from empty

**Location**: `Simplex.Messaging.Notifications.Server.Store` — `stmDeleteNtfToken`
**Description**: If the token ID doesn't exist in the `tokens` map, the registration-cleanup branch is skipped and the function returns an empty list. The caller cannot distinguish "deleted a token with no subscriptions" from "token never existed."
**Module spec**: [Notifications/Server/Store.md](Simplex/Messaging/Notifications/Server/Store.md)

### N-14: createCommand silently drops commands for deleted connections

**Location**: `Simplex.Messaging.Agent.Store.AgentStore` — `createCommand`
**Description**: When `createCommand` encounters a constraint violation (the referenced connection was already deleted), it logs the error and returns successfully. Commands targeting deleted connections are silently dropped.
**Module spec**: [Agent/Store/AgentStore.md](Simplex/Messaging/Agent/Store/AgentStore.md)

### N-15: Redirect chain loading errors silently swallowed

**Location**: `Simplex.Messaging.Agent.Store.AgentStore`
**Description**: When loading redirect chains, errors loading individual redirect files are silently swallowed via `either (const $ pure Nothing) (pure . Just)`. Prevents a corrupt redirect from blocking access to the main file.
**Module spec**: [Agent/Store/AgentStore.md](Simplex/Messaging/Agent/Store/AgentStore.md)

### N-16: BLOCKED encoded as AUTH for old XFTP clients

**Location**: `Simplex.FileTransfer.Protocol` — `encodeProtocol`
**Description**: If the protocol version is below `blockedFilesXFTPVersion`, a `BLOCKED` result is encoded as `AUTH` instead. The blocking information (reason) is permanently lost for these clients.
**Module spec**: [FileTransfer/Protocol.md](Simplex/FileTransfer/Protocol.md)

### N-17: restore_messages three-valued logic with implicit default

**Location**: `Simplex.Messaging.Server.Main` — INI config
**Description**: The `restore_messages` INI setting has three-valued logic: explicit "on" → restore, explicit "off" → skip, missing → inherits from `enable_store_log`. This implicit default is not captured in the type system — callers see `Maybe Bool`.
**Module spec**: [Server/Main.md](Simplex/Messaging/Server/Main.md)

### N-18: Stats format migration permanently loses precision

**Location**: `Simplex.Messaging.Server.Stats` — `strP` for `ServerStatsData`
**Description**: The parser handles multiple format generations. Old format `qDeleted=` is read as `(value, 0, 0)`. `qSubNoMsg` is parsed and discarded. `subscribedQueues` is parsed but replaced with empty data. Data loaded from old formats is coerced — precision is permanently lost.
**Module spec**: [Server/Stats.md](Simplex/Messaging/Server/Stats.md)

### N-19: resubscribe exceptions silently lost

**Location**: `Simplex.Messaging.Notifications.Server` — `resubscribe`
**Description**: `resubscribe` is launched via `forkIO` before `raceAny_` starts — not part of the `raceAny_` group. Most exceptions are silently lost per `forkIO` semantics. `ExitCode` exceptions are special-cased by GHC's runtime and do propagate.
**Module spec**: [Notifications/Server.md](Simplex/Messaging/Notifications/Server.md)

### N-20: closeSMPClientAgent worker cancellation is fire-and-forget

**Location**: `Simplex.Messaging.Client.Agent` — `closeSMPClientAgent`
**Description**: Executes in order: set `active = False`, close all client connections, swap workers map to empty and fork cancellation threads. Cancel threads use `uninterruptibleCancel` but are fire-and-forget — the function may return before all workers are cancelled.
**Module spec**: [Client/Agent.md](Simplex/Messaging/Client/Agent.md)

### N-21: APNS unknown 410 reasons trigger retry instead of permanent failure

**Location**: `Simplex.Messaging.Notifications.Server.Push.APNS`
**Description**: Unknown 410 (Gone) reasons fall through to `PPRetryLater`, while unknown 400 and 403 reasons fall through to `PPResponseError`. An unexpected APNS 410 reason string triggers retry rather than permanent failure.
**Module spec**: [Notifications/Server/Push/APNS.md](Simplex/Messaging/Notifications/Server/Push/APNS.md)

### N-22: NTInvalid/NTExpired tokens can create subscriptions

**Location**: `Simplex.Messaging.Notifications.Protocol` — token status permissions
**Description**: Token status `NTInvalid` allows subscription commands (SNEW, SCHK, SDEL). A TODO comment explains: invalidation can happen after verification, and existing subscriptions should remain manageable. `NTExpired` is also permitted.
**Module spec**: [Notifications/Protocol.md](Simplex/Messaging/Notifications/Protocol.md)

### N-23: removeInactiveTokenRegistrations doesn't clean up empty inner maps

**Location**: `Simplex.Messaging.Notifications.Server.Store` — `stmRemoveInactiveTokenRegistrations`
**Description**: `stmDeleteNtfToken` checks whether inner TMap is empty after removal and cleans up the outer key. `stmRemoveInactiveTokenRegistrations` does not — surviving active tokens' registrations remain, but empty inner maps can persist.
**Module spec**: [Notifications/Server/Store.md](Simplex/Messaging/Notifications/Server/Store.md)

### N-24: cbNonce silently truncates or pads

**Location**: `Simplex.Messaging.Crypto` — `cbNonce`
**Description**: If the input is longer than 24 bytes, it is silently truncated. If shorter, it is silently padded. No error is raised. Callers must ensure correct length.
**Module spec**: [Crypto.md](Simplex/Messaging/Crypto.md)
