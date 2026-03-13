# Simplex.Messaging.Notifications.Server.Push.APNS

> Apple Push Notification Service (APNS) client: JWT authentication, HTTP/2 delivery, and e2e encryption.

**Source**: [`Notifications/Server/Push/APNS.hs`](../../../../../../../src/Simplex/Messaging/Notifications/Server/Push/APNS.hs)

## Non-obvious behavior

### 1. PNCheckMessages is not encrypted

`PNVerification` and `PNMessage` notifications are encrypted with the shared DH secret (`C.cbEncrypt`) and padded to `paddedNtfLength` (3072 bytes) to prevent metadata leakage. `PNCheckMessages` is sent as a plain `{"checkMessages": true}` background notification — it carries no sensitive data and doesn't need e2e encryption.

### 2. Fixed-length encryption padding

All encrypted notifications are padded to `paddedNtfLength` (3072 bytes) regardless of actual content size. This prevents notification size from revealing whether it's a verification code (small) or a message batch (larger).

### 3. JWT token caching with TTL refresh

`getApnsJWTToken` caches the signed JWT and only regenerates it when the token age exceeds `tokenTTL` (30 minutes). No locking is used — if two threads race to refresh, last writer wins, which is acceptable since both produce valid tokens.

### 4. HTTP/2 reconnect-on-use

`createAPNSPushClient` registers a disconnect callback that sets `https2Client` to `Nothing`. `getApnsHTTP2Client` lazily reconnects on the next push delivery attempt. The connection is not proactively maintained.

### 5. 503 triggers active disconnect before retry

When APNS returns 503 (Service Unavailable), the client actively closes the HTTP/2 connection (`disconnectApnsHTTP2Client`) before throwing `PPRetryLater`. This ensures a fresh connection is established on retry rather than reusing a potentially degraded connection.

### 6. ExpiredProviderToken is permanent

403 errors for `ExpiredProviderToken` and `InvalidProviderToken` are classified as `PPPermanentError` rather than retryable. Since `getApnsJWTToken` just refreshed the JWT before the request, retrying with the same key would produce the same error. This indicates a configuration problem (wrong key/team ID).

### 7. EC key type assumption

`readECPrivateKey` uses a specific pattern match for EC keys (`PrivKeyEC_Named`). It will crash at runtime if the APNS key file contains a different key type. The comment acknowledges this limitation.
