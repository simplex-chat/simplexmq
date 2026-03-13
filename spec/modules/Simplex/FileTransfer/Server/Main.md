# Simplex.FileTransfer.Server.Main

> XFTP router CLI: INI configuration parsing, TLS setup, and default constants.

**Source**: [`FileTransfer/Server/Main.hs`](../../../../../src/Simplex/FileTransfer/Server/Main.hs)

## Non-obvious behavior

### 1. Key router constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `fileIdSize` | 16 bytes | Random file/recipient ID length |
| `fileTimeout` | 5 minutes | Maximum upload duration per chunk |
| `logStatsInterval` | 86400s (daily) | Stats CSV flush interval |
| `logStatsStartTime` | 0 (midnight UTC) | First stats flush time-of-day |

### 2. allowedChunkSizes defaults to all four sizes

If not configured, `allowedChunkSizes` defaults to `[kb 64, kb 256, mb 1, mb 4]`. The INI file can restrict this to a subset, controlling which chunk sizes the router accepts.

### 3. Storage quota from INI with unit parsing

`fileSizeQuota` is parsed from the INI `[STORE_LOG]` section using `FileSize` parsing, which accepts byte values with optional unit suffixes (KB, MB, GB). Absence means unlimited quota (`Nothing`).

### 4. Dual TLS credential support

The router supports both primary TLS credentials (`caCertificateFile`/`certificateFile`/`privateKeyFile`) and optional HTTP-specific credentials (`httpCaCertificateFile`/etc.). When HTTP credentials are present, the router uses `defaultSupportedParamsHTTPS` which enables broader TLS compatibility for web clients.
