# Simplex.Messaging.Notifications.Protocol

> NTF protocol entities, commands, responses, and wire encoding for the notification system.

**Source**: [`Notifications/Protocol.hs`](../../../../../src/Simplex/Messaging/Notifications/Protocol.hs)

## Non-obvious behavior

### 1. Asymmetric credential validation

`checkCredentials` enforces different rules per command category:

| Category | Signature required | Entity ID |
|----------|-------------------|-----------|
| TNEW, SNEW | Yes | Must be empty (new entity) |
| PING | No | Must be empty |
| All others | Yes | Must be present |

For responses, the rule inverts: `NRTknId`, `NRSubId`, and `NRPong` must NOT have entity IDs (they are returned before/without entity context), while `NRErr` optionally has one (errors can occur with or without entity context).

### 2. PNMessageData semicolon separator

`encodePNMessages` uses `;` as the separator between push notification message items instead of the standard `,` used by `NonEmpty` `strEncode`. This is because `SMPQueueNtf` contains an `SMPServer` whose host list encoding already uses commas, which would create ambiguous parsing.

### 3. NTInvalid reason is version-gated

When encoding `NRTkn` responses, the `NTInvalid` reason is only included if the negotiated protocol version is >= `invalidReasonNTFVersion` (v3). Older clients receive `NTInvalid Nothing`. This prevents parse failures on clients that don't understand the reason field.

### 4. subscribeNtfStatuses migration invariant

The comment on `subscribeNtfStatuses` (`[NSNew, NSPending, NSActive, NSInactive]`) warns that changing these statuses requires a new database migration for queue ID hashes (see `m20250830_queue_ids_hash`). This is a cross-module invariant between protocol types and router storage.

### 5. allowNtfSubCommands permits NTInvalid and NTExpired

Token status `NTInvalid` allows subscription commands (SNEW, SCHK, SDEL), which is counterintuitive. The rationale (noted in a TODO comment) is that invalidation can happen after verification, and existing subscriptions should remain manageable. `NTExpired` is also permitted for the same reason.

### 6. PPApnsNull test provider

`PPApnsNull` is a push provider that never communicates with APNS. It's used for end-to-end testing of the notification router from clients without requiring actual push infrastructure.

### 7. DeviceToken hex validation

`DeviceToken` string parsing has two paths: a hardcoded literal match for `"apns_null test_ntf_token"` (test tokens), and hex string validation for real tokens (must be even-length hex). The wire encoding (`smpP`) does not perform this validation — it accepts any `ByteString`.

### 8. SMPQueueNtf parsing applies updateSMPServerHosts

Both `smpP` and `strP` for `SMPQueueNtf` apply `updateSMPServerHosts` to the parsed SMP server. This normalizes router host addresses on deserialization, ensuring consistent comparison even if the on-wire format uses different host representations.

### 9. NRTknId response tag comment

The `NRTknId_` tag encodes as `"IDTKN"` with a source comment: "it should be 'TID', 'SID'". This indicates a naming inconsistency that was preserved for backward compatibility — the tag names don't follow the pattern of other NTF protocol tags.

### 10. useServiceAuth is False

The `Protocol` instance explicitly returns `False` for `useServiceAuth`, meaning the NTF protocol never uses service-level authentication. All authentication is entity-level (per token/subscription).
