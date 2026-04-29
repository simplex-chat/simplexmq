# XFTP Server Manual Test Suite

Automated integration tests for the XFTP server covering memory and PostgreSQL backends, migration, persistence, blocking, and edge cases.

- `xftp-test.py` — automated test script (143 checks)
- `xftp-server-testing.md` — manual step-by-step guide covering the same scenarios

## Prerequisites

- Linux (tested)
- Python 3
- Haskell toolchain (`cabal`, `ghc`)
- PostgreSQL 16+ (`postgresql-16` package or equivalent)

## Setup

### 1. Build the XFTP binaries

```bash
cabal build -fserver_postgres exe:xftp-server exe:xftp
```

### 2. Set up a local PostgreSQL instance

The test script connects to PostgreSQL via `PGHOST` (Unix socket path). Set up a local instance that you own (no root required):

```bash
# Pick a data directory and socket directory
export PGDATA=/tmp/pgdata
export PGHOST=/tmp/pgsocket

# Clean up any previous instance
rm -rf $PGDATA $PGHOST
mkdir -p $PGDATA $PGHOST

# Initialize the cluster
/usr/lib/postgresql/16/bin/initdb -D $PGDATA --auth=trust --no-locale --encoding=UTF8

# Configure to listen on our socket directory and localhost TCP
echo "unix_socket_directories = '$PGHOST'" >> $PGDATA/postgresql.conf
echo "listen_addresses = '127.0.0.1'" >> $PGDATA/postgresql.conf

# Start the server
/usr/lib/postgresql/16/bin/pg_ctl -D $PGDATA -l /tmp/pg.log start

# Verify it's running
pg_isready -h $PGHOST
# Expected: /tmp/pgsocket:5432 - accepting connections
```

### 3. Create the required PostgreSQL roles

The test script expects three roles to exist:

- `postgres` — admin role used by the test bracket to create/drop databases
- `xftp` — test user for the XFTP server database

```bash
# Create the postgres admin role (if initdb created the cluster as your user)
psql -h $PGHOST -d postgres -c "CREATE USER postgres WITH SUPERUSER;"

# Create the xftp test user
psql -h $PGHOST -U postgres -d postgres -c "CREATE USER xftp WITH SUPERUSER;"
```

Verify both roles exist:

```bash
psql -h $PGHOST -U postgres -d postgres -c "\du"
```

## Run the test suite

```bash
PGHOST=/tmp/pgsocket python3 tests/manual/xftp-test.py
```

Expected output (abbreviated):

```
XFTP server: /project/git/simplexmq-4/dist-newstyle/.../xftp-server
XFTP client: /project/git/simplexmq-4/dist-newstyle/.../xftp
Test dir:    /project/git/simplexmq-4/xftp-test
PGHOST:      /tmp/pgsocket

=== 1. Basic send/receive (memory) ===
  [PASS] 1.1 rcv1.xftp created
  ...
=== 12. Recipient cascade and storage accounting ===
  ...
  [PASS] 12.2e DB files after delete (0)

==========================================
Results: 143 passed, 0 failed
==========================================
```

Total runtime: ~3 minutes. Exit code 0 on success, 1 on any failure.

## What the suite tests

| # | Section | Checks | Scope |
|---|---------|--------|-------|
| 1 | Basic memory | 9 | Send/recv/delete on STM backend |
| 2 | Basic PostgreSQL | 7 | Send/recv/delete on PG backend, DB row verification |
| 3 | Migration memory → PG | 12 | Send on memory, partial recv, import, recv remaining |
| 4 | Migration PG → memory | 5 | Export, switch to memory, delete exported files |
| 4b | Send PG, recv memory | 7 | Reverse direction — send on PG, export, recv on memory |
| 5 | Restart persistence | 6 | memory+log / memory no log / PostgreSQL |
| 6 | Config edge cases | 15 | store log conflicts, missing schema, dual-write, import/export guards |
| 7 | File blocking | 13 | Control port block, block state survives migration both directions |
| 8 | Migration edge cases | 23 | Acked recipients preserved, deleted files absent, 20MB multi-chunk, double round-trip |
| 9 | Auth & access control | 9 | allowNewFiles, basic auth (none/wrong/correct/server-no-auth), quota |
| 10 | Control port ops | 8 | No auth, wrong auth, stats, delete, invalid block |
| 11 | Blocked sender delete | 3 | Sender can't delete blocked file |
| 12 | Cascade & storage | 8 | Recipient cascade, disk/DB accounting |

## Troubleshooting

### Server binary not found

```
Binary not found: .../xftp-server
Run: cabal build -fserver_postgres exe:xftp-server
```

Run the cabal build command from step 1.

### Cannot connect to PostgreSQL

```
Cannot connect to PostgreSQL as postgres. Is it running?
```

Check:
1. `pg_isready -h $PGHOST` returns "accepting connections"
2. `PGHOST` environment variable is exported in the shell running the test
3. The `postgres` role exists: `psql -h $PGHOST -U postgres -d postgres -c "SELECT 1;"`

### PostgreSQL user 'xftp' does not exist

```
PostgreSQL user 'xftp' does not exist.
Run: psql -U postgres -c "CREATE USER xftp WITH SUPERUSER;"
```

Run the create-user command from step 3.

### Port 7921 or 15230 already in use

The test uses port 7921 for XFTP and 15230 for the control port. If these are occupied, stop whatever is using them or edit `PORT` / `CONTROL_PORT` constants at the top of `xftp-test.py`.

### Server fails to start mid-test

Check `xftp-test/server.log` in the project directory for the server's stdout/stderr. The test framework prints the last 5 lines of the log on startup failure.

## Stopping the test PostgreSQL instance

```bash
/usr/lib/postgresql/16/bin/pg_ctl -D /tmp/pgdata stop
```

## Cleanup

The test script cleans up its own test directory (`./xftp-test/`) and drops the test database (`xftp_server_store`) on completion. To also remove the PostgreSQL instance:

```bash
/usr/lib/postgresql/16/bin/pg_ctl -D /tmp/pgdata stop
rm -rf /tmp/pgdata /tmp/pgsocket /tmp/pg.log
```
