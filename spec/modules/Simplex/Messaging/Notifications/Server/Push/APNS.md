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

### 8. JWT signature uses DER-encoded ASN.1, not raw r||s

`signedJWTToken` serializes the ECDSA signature as a DER-encoded ASN.1 SEQUENCE of two INTEGERs, then base64url-encodes it. RFC 7518 Section 3.4 requires raw concatenation of fixed-length r and s values instead. This deviation works because Apple's APNS server accepts DER-encoded signatures, but it would break if Apple enforced strict JWS compliance.

### 9. Two different base64url encodings

The encryption path uses `U.encode` (base64url **with** padding `=`), while the JWT path uses `U.encodeUnpadded` (base64url **without** padding). JWT requires unpadded base64url per RFC 7515, but the encrypted notification ciphertext is padded before being embedded as a JSON text value.

### 10. Error response defaults to empty string on parse failure

If the APNS error response body is empty, malformed, or not JSON, `decodeStrict'` returns `Nothing` and the reason defaults to `""`. This empty string never matches named error patterns, so unparseable error bodies fall through to the catch-all of whichever status code branch matches. For 410, this means a malformed body is treated as `PPRetryLater` rather than a token invalidation.

### 11. 410 unknown reasons are retryable, unlike 400/403 unknowns

Unknown 410 (Gone) reasons fall through to `PPRetryLater`, while unknown 400 and 403 reasons fall through to `PPResponseError`. This means an unexpected APNS 410 reason string triggers retry behavior rather than permanent failure.

### 12. 429 TooManyRequests is not explicitly handled

There is a commented-out note but no actual 429 handler. A rate-limiting response falls through to the `otherwise` branch and becomes `PPResponseError`, surfacing as a generic error rather than a retryable condition.

### 13. Nonce generation is STM-atomic, separate from encryption

The per-notification nonce is generated inside `atomically` using the `ChaChaDRG` TVar, guaranteeing uniqueness under concurrent delivery. The nonce is then used by `cbEncrypt` outside STM. This separation means the nonce is committed to the DRG state even if encryption or send subsequently fails — correct behavior since nonce reuse would be catastrophic.

### 14. Background notifications use priority 5, alerts use default 10

`apnsRequest` conditionally appends `apns-priority: 5` only for `APNSBackground` notifications. Alert and mutable-content notifications omit the header, relying on APNS's default priority of 10. Apple requires background pushes to use priority 5 — using 10 can cause APNS to reject them.

### 15. APNSErrorResponse is data, not newtype

The comment explicitly states `APNSErrorResponse` is `data` rather than `newtype` "to have a correct JSON encoding as a record." With `deriveFromJSON`, a newtype around `Text` would serialize as a bare string, not `{"reason": "..."}`. The `data` wrapper forces record encoding matching APNS's JSON error format.

### 16. HTTP/2 requests go through a serializing queue

`sendRequest` routes through the HTTP2Client's `reqQ` (a `TBQueue`), serializing all requests through a single sender thread. Concurrent push deliveries are implicitly serialized at the HTTP/2 layer, meaning high-throughput scenarios bottleneck on this queue rather than utilizing HTTP/2's multiplexing.

### 17. Connection initialization is fire-and-forget

`createAPNSPushClient` calls `connectHTTPS2` and discards the result with `void`. If the initial connection fails, the error is only logged — the client is still created. The first push delivery triggers `getApnsHTTP2Client` which reconnects. This means the server can start even if APNS is unreachable.
