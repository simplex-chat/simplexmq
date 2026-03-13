# Simplex.FileTransfer.Server.Stats

> XFTP router statistics: IORef-based counters with backward-compatible persistence.

**Source**: [`FileTransfer/Server/Stats.hs`](../../../../../src/Simplex/FileTransfer/Server/Stats.hs)

## Non-obvious behavior

### 1. setFileServerStats is not thread safe

`setFileServerStats` directly writes to IORefs without synchronization. It is explicitly intended for router startup only (restoring from backup file), before any concurrent threads are running.

### 2. Backward-compatible parsing

The `strP` parser uses `opt` for newer fields, defaulting missing fields to 0. This allows reading stats files from older router versions that don't include fields like `filesBlocked` or `fileDownloadAcks`.

### 3. PeriodStats for download tracking

`filesDownloaded` uses `PeriodStats` (not a simple `IORef Int`) to track unique file downloads over time periods (day/week/month). This enables the CSV stats log to report distinct files downloaded per period, not just total download count.
