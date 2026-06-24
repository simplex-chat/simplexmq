# Simplex.Messaging.Notifications.Server.Main

> CLI interface and INI configuration parsing for the NTF router.

**Source**: [`Notifications/Server/Main.hs`](../../../../../../src/Simplex/Messaging/Notifications/Server/Main.hs)

No non-obvious behavior. Standard CLI/config boilerplate. Notable defaults: `subsBatchSize = 900`, `periodicNtfsInterval = 5 minutes`, `pushQSize = 32768`, `persistErrorInterval = 0` (disables SMP client reconnection error persistence).
