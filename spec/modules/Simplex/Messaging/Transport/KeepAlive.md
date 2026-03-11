# Simplex.Messaging.Transport.KeepAlive

> Platform-specific TCP keepalive configuration via CApiFFI.

**Source**: [`Transport/KeepAlive.hs`](../../../../../src/Simplex/Messaging/Transport/KeepAlive.hs)

## Platform-specific TCP_KEEPIDLE

macOS uses `TCP_KEEPALIVE` instead of `TCP_KEEPIDLE`. The CPP conditional imports the correct constant at compile time via `foreign import capi`. Windows uses hardcoded numeric values — the source comment states: "The values are copied from windows::Win32::Networking::WinSock."

Defaults: idle=30s, interval=15s, count=4.
