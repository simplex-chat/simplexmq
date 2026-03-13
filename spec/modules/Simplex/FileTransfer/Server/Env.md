# Simplex.FileTransfer.Server.Env

> XFTP server environment: configuration, storage quota tracking, and request routing.

**Source**: [`FileTransfer/Server/Env.hs`](../../../../../src/Simplex/FileTransfer/Server/Env.hs)

## Non-obvious behavior

### 1. Startup storage accounting with quota warning

`newXFTPServerEnv` computes `usedStorage` by summing file sizes from the in-memory store at startup. If the computed usage exceeds the configured `fileSizeQuota`, a warning is logged but the server still starts. This allows the server to come up even if it's over quota (e.g., after a quota reduction), relying on expiration to reclaim space.

### 2. XFTPRequest ADT separates new files from commands

`XFTPRequest` has three constructors:
- `XFTPReqNew`: file creation (carries `FileInfo`, recipient keys, optional basic auth)
- `XFTPReqCmd`: command on an existing file (carries file ID, `FileRec`, and the command)
- `XFTPReqPing`: health check

This separation occurs after credential verification in `Server.hs`. `XFTPReqNew` bypasses entity lookup entirely since the file doesn't exist yet.

### 3. fileTimeout for upload deadline

`fileTimeout` in `XFTPServerConfig` sets the maximum time allowed for a single file upload (FPUT). The server wraps the receive operation in `timeout fileTimeout`. Default is 5 minutes (for 4MB chunks). This prevents slow or stalled uploads from holding server resources indefinitely.
