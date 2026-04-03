# Simplex.Messaging.Notifications.Server.Store.Types

> Pure record types and STM conversion for notification tokens and subscriptions.

**Source**: [`Notifications/Server/Store/Types.hs`](../../../../../../../src/Simplex/Messaging/Notifications/Server/Store/Types.hs)

No non-obvious behavior. `mkTknData`/`mkTknRec` convert between pure records and TVar-based STM data. `tknUpdatedAt` is parsed as optional for backward compatibility with store logs that predate it.
