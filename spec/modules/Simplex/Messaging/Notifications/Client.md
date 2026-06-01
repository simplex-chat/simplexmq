# Simplex.Messaging.Notifications.Client

> Typed wrappers around `ProtocolClient` for NTF protocol commands.

**Source**: [`Notifications/Client.hs`](../../../../../src/Simplex/Messaging/Notifications/Client.hs)

## Non-obvious behavior

### 1. Subscription operations always use NRMBackground

`ntfCreateSubscription`, `ntfCheckSubscription`, `ntfDeleteSubscription`, and their batch variants hardcode `NRMBackground` as the network request mode. Token operations (`ntfRegisterToken`, `ntfVerifyToken`, etc.) accept the mode as a parameter. This reflects that subscription management is a background activity driven by the supervisor, while token operations can be user-initiated.

### 2. Batch operations return per-item errors

`ntfCreateSubscriptions` and `ntfCheckSubscriptions` return `NonEmpty (Either NtfClientError result)` — individual items in a batch can fail independently. Callers must handle partial success (some created, some failed). The singular variants throw on any error.

### 3. Default port is 443

`defaultNTFClientConfig` sets the default transport to `("443", transport @TLS)`. Unlike the SMP protocol which typically uses port 5223, the NTF protocol defaults to the standard HTTPS port.

### 4. okNtfCommand parameter ordering

`okNtfCommand` has an unusual parameter order — the command comes first, then client, mode, key, entityId. This enables partial application in the `ntfDeleteToken`, `ntfVerifyToken` etc. definitions, where the command is fixed and the remaining parameters flow through.
