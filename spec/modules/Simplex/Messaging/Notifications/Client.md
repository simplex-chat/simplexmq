# Simplex.Messaging.Notifications.Client

> Typed wrappers around `ProtocolClient` for NTF protocol commands.

**Source**: [`Notifications/Client.hs`](../../../../../src/Simplex/Messaging/Notifications/Client.hs)

## Non-obvious behavior

### 1. Subscription operations always use NRMBackground

`ntfCreateSubscription`, `ntfCheckSubscription`, `ntfDeleteSubscription`, and their batch variants hardcode `NRMBackground` as the network request mode. Token operations (`ntfRegisterToken`, `ntfVerifyToken`, etc.) accept the mode as a parameter. This reflects that subscription management is a background activity driven by the supervisor, while token operations can be user-initiated.

### 2. Batch operations return per-item errors

`ntfCreateSubscriptions` and `ntfCheckSubscriptions` return `NonEmpty (Either NtfClientError result)` — individual items in a batch can fail independently. Callers must handle partial success (some created, some failed). The singular variants throw on any error.
