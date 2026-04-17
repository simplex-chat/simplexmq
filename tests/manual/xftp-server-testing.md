# XFTP Server Manual Testing Guide

Manual testing of the XFTP server with memory (STM) and PostgreSQL backends, including migration between them, blocking, auth, quota, control port, and edge cases.

All paths are self-contained under `./xftp-test/`. The automated version of this guide is `xftp-test.py` (143 checks). This guide mirrors the script 1:1.

## Prerequisites

See `tests/manual/README.md` for PostgreSQL setup. After setup, in the shell running this guide:

```bash
cabal build -fserver_postgres exe:xftp-server exe:xftp

export XFTP_SERVER=$(cabal list-bin exe:xftp-server)
export XFTP=$(cabal list-bin exe:xftp)
export TEST_DIR=$(pwd)/xftp-test
export XFTP_SERVER_CFG_PATH=$TEST_DIR/etc
export XFTP_SERVER_LOG_PATH=$TEST_DIR/var
export PGHOST=/tmp/pgsocket
```

PostgreSQL roles `postgres` and `xftp` (both SUPERUSER) must exist — see the README.

Helper functions for editing the INI config:

```bash
ini_set() { sed -i "s|^${1}:.*|${1}: ${2}|" $XFTP_SERVER_CFG_PATH/file-server.ini; }
ini_uncomment() { sed -i "s|^# ${1} =|${1} =|" $XFTP_SERVER_CFG_PATH/file-server.ini; }
ini_comment() { sed -i "s|^${1} =|# ${1} =|" $XFTP_SERVER_CFG_PATH/file-server.ini; }

enable_control_port() {
  sed -i 's/^# control_port = 5226/control_port = 15230/' $XFTP_SERVER_CFG_PATH/file-server.ini
  sed -i 's/^# control_port_admin_password =.*/control_port_admin_password = testadmin/' $XFTP_SERVER_CFG_PATH/file-server.ini
}

# Extract recipient IDs from a file description (chunk format: "- N:rcvId:privKey:digest")
get_recipient_ids() {
  grep '^ *- [0-9]' "$1" | cut -d: -f2
}

# Send a command to the control port as admin and print the response
control_cmd() {
  python3 -c "
import socket, time
s = socket.create_connection(('127.0.0.1', 15230), timeout=5)
s.settimeout(2)
# Drain welcome
time.sleep(0.3)
s.recv(4096)
s.sendall(b'auth testadmin\n')
time.sleep(0.3); s.recv(4096)
s.sendall(b'$1\n')
time.sleep(0.3)
print(s.recv(4096).decode().strip())
s.sendall(b'quit\n'); s.close()
"
}
```

## Important notes

- **`-y` on `recv`** auto-confirms, ACKs chunks on the server, and deletes the descriptor file.
- **`-y` on `del`** auto-confirms and deletes the sender descriptor.
- **`database import` and `database export`** prompt for confirmation. Answer uppercase **`Y`**.
- Server defaults to port 443 (requires root). All tests use port 7921.
- **`init` does not create the store log file.** It is created on first `server start` with `enable: on`.
- **`--confirm-migrations up`** auto-confirms PG schema migrations.
- With `store_files: database`, the PG schema must already exist — create manually or use `database import` which creates it automatically.

## 1. Basic send/receive (memory backend)

### 1.1 Initialize and start server

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}

$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921

FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!
sleep 2
```

### 1.2 Send a file with 2 recipients

```bash
dd if=/dev/urandom of=$TEST_DIR/testfile.bin bs=1M count=5 2>/dev/null

$XFTP send $TEST_DIR/testfile.bin $TEST_DIR/descriptions -s "$SRV" -n 2 -v

ls $TEST_DIR/descriptions/testfile.bin.xftp/
# Expected: rcv1.xftp  rcv2.xftp  snd.xftp.private
```

### 1.3 Receive the file (recipient 1)

```bash
$XFTP recv $TEST_DIR/descriptions/testfile.bin.xftp/rcv1.xftp $TEST_DIR/received -y -v
diff $TEST_DIR/testfile.bin $TEST_DIR/received/testfile.bin
# Expected: no output

ls $TEST_DIR/descriptions/testfile.bin.xftp/rcv1.xftp 2>&1
# Expected: No such file or directory (deleted by -y)
```

### 1.4 Receive the file (recipient 2)

```bash
rm -f $TEST_DIR/received/testfile.bin

$XFTP recv $TEST_DIR/descriptions/testfile.bin.xftp/rcv2.xftp $TEST_DIR/received -y -v
diff $TEST_DIR/testfile.bin $TEST_DIR/received/testfile.bin
```

### 1.5 Delete the file from server

```bash
$XFTP del $TEST_DIR/descriptions/testfile.bin.xftp/snd.xftp.private -y -v

ls $TEST_DIR/descriptions/testfile.bin.xftp/snd.xftp.private 2>&1
# Expected: No such file or directory

ls $TEST_DIR/files/ | wc -l
# Expected: 0
```

### 1.6 Stop server

```bash
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

## 2. Basic send/receive (PostgreSQL backend)

### 2.1 Initialize fresh server for PostgreSQL

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
psql -U postgres -c "CREATE DATABASE xftp_server_store OWNER xftp;"

$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size

FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

psql -U xftp -d xftp_server_store -c "CREATE SCHEMA IF NOT EXISTS xftp_server;"
```

### 2.2 Start server with PostgreSQL

```bash
$XFTP_SERVER start --confirm-migrations up &
SERVER_PID=$!
sleep 2
```

### 2.3 Send, receive, verify

```bash
dd if=/dev/urandom of=$TEST_DIR/testfile.bin bs=1M count=5 2>/dev/null

$XFTP send $TEST_DIR/testfile.bin $TEST_DIR/descriptions -s "$SRV" -n 2 -v
$XFTP recv $TEST_DIR/descriptions/testfile.bin.xftp/rcv1.xftp $TEST_DIR/received -y -v
diff $TEST_DIR/testfile.bin $TEST_DIR/received/testfile.bin
```

### 2.4 Verify data is in PostgreSQL

```bash
psql -U xftp -d xftp_server_store \
  -c "SET search_path TO xftp_server; SELECT count(*) AS files FROM files;"
# Expected: > 0

psql -U xftp -d xftp_server_store \
  -c "SET search_path TO xftp_server; SELECT count(*) AS recipients FROM recipients;"
# Expected: > 0
```

### 2.5 Delete and verify all cleaned up

```bash
$XFTP del $TEST_DIR/descriptions/testfile.bin.xftp/snd.xftp.private -y -v

psql -U xftp -d xftp_server_store -c "SET search_path TO xftp_server; SELECT count(*) FROM files;"
# Expected: 0
psql -U xftp -d xftp_server_store -c "SET search_path TO xftp_server; SELECT count(*) FROM recipients;"
# Expected: 0

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

## 3. Migration: memory to PostgreSQL

### 3.1 Start with memory backend, send files

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
psql -U postgres -c "CREATE DATABASE xftp_server_store OWNER xftp;"

$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/fileA.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/fileA.bin $TEST_DIR/descriptions -s "$SRV" -n 2

dd if=/dev/urandom of=$TEST_DIR/fileB.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/fileB.bin $TEST_DIR/descriptions -s "$SRV" -n 2

# Partially receive fileB (only rcv1)
$XFTP recv $TEST_DIR/descriptions/fileB.bin.xftp/rcv1.xftp $TEST_DIR/received -y
diff $TEST_DIR/fileB.bin $TEST_DIR/received/fileB.bin
```

### 3.2 Stop server and migrate to PostgreSQL

```bash
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; sleep 1

ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size

echo Y | $XFTP_SERVER database import
# Expected: "Loaded N files, M recipients" / "Imported N files" / "Imported M recipients"
#           "Store log renamed to ...file-server-store.log.bak"

ls $XFTP_SERVER_LOG_PATH/file-server-store.log.bak  # should exist
ls $XFTP_SERVER_LOG_PATH/file-server-store.log 2>&1  # should NOT exist

psql -U xftp -d xftp_server_store <<'SQL'
SET search_path TO xftp_server;
SELECT count(*) AS file_count FROM files;
SELECT count(*) AS recipient_count FROM recipients;
SQL
```

### 3.3 Start server with PostgreSQL and receive remaining files

```bash
$XFTP_SERVER start --confirm-migrations up &
SERVER_PID=$!; sleep 2

$XFTP recv $TEST_DIR/descriptions/fileA.bin.xftp/rcv1.xftp $TEST_DIR/received -y
diff $TEST_DIR/fileA.bin $TEST_DIR/received/fileA.bin

$XFTP recv $TEST_DIR/descriptions/fileA.bin.xftp/rcv2.xftp $TEST_DIR/received -y

rm -f $TEST_DIR/received/fileB.bin
$XFTP recv $TEST_DIR/descriptions/fileB.bin.xftp/rcv2.xftp $TEST_DIR/received -y
diff $TEST_DIR/fileB.bin $TEST_DIR/received/fileB.bin

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

## 4. Migration: PostgreSQL back to memory

Continues from section 3 state.

### 4.1 Export from PostgreSQL

```bash
echo Y | $XFTP_SERVER database export
ls $XFTP_SERVER_LOG_PATH/file-server-store.log  # should exist
head -5 $XFTP_SERVER_LOG_PATH/file-server-store.log
# Should contain FNEW, FADD, FPUT entries
```

### 4.2 Switch back to memory and start

```bash
ini_set store_files memory
ini_comment db_connection
ini_comment db_schema
ini_comment db_pool_size

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2
```

### 4.3 Verify deletes work on round-trip data

```bash
$XFTP del $TEST_DIR/descriptions/fileA.bin.xftp/snd.xftp.private -y
$XFTP del $TEST_DIR/descriptions/fileB.bin.xftp/snd.xftp.private -y

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

## 4b. Send on PostgreSQL, export, receive on memory

### 4b.1 Start PG server and send a file

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
psql -U postgres -c "CREATE DATABASE xftp_server_store OWNER xftp;"

$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

psql -U xftp -d xftp_server_store -c "CREATE SCHEMA IF NOT EXISTS xftp_server;"

$XFTP_SERVER start --confirm-migrations up &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/pgfileA.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/pgfileA.bin $TEST_DIR/descriptions -s "$SRV" -n 2

# Receive rcv1 on PG
$XFTP recv $TEST_DIR/descriptions/pgfileA.bin.xftp/rcv1.xftp $TEST_DIR/received -y
diff $TEST_DIR/pgfileA.bin $TEST_DIR/received/pgfileA.bin

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; sleep 1
```

### 4b.2 Export and switch to memory

```bash
echo Y | $XFTP_SERVER database export

ini_set store_files memory
ini_comment db_connection
ini_comment db_schema
ini_comment db_pool_size

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2
```

### 4b.3 Receive remaining file on memory backend

```bash
rm -f $TEST_DIR/received/pgfileA.bin
$XFTP recv $TEST_DIR/descriptions/pgfileA.bin.xftp/rcv2.xftp $TEST_DIR/received -y
diff $TEST_DIR/pgfileA.bin $TEST_DIR/received/pgfileA.bin

$XFTP del $TEST_DIR/descriptions/pgfileA.bin.xftp/snd.xftp.private -y

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

## 5. Server restart persistence

### 5.1 Memory backend with store log

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/persist.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/persist.bin $TEST_DIR/descriptions -s "$SRV" -n 1

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; sleep 1

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

$XFTP recv $TEST_DIR/descriptions/persist.bin.xftp/rcv1.xftp $TEST_DIR/received -y
diff $TEST_DIR/persist.bin $TEST_DIR/received/persist.bin

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

### 5.2 Memory backend WITHOUT store log

```bash
rm -rf $TEST_DIR/descriptions/* $TEST_DIR/received/*
ini_set enable off

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/persist2.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/persist2.bin $TEST_DIR/descriptions -s "$SRV" -n 1

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; sleep 1

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

$XFTP recv $TEST_DIR/descriptions/persist2.bin.xftp/rcv1.xftp $TEST_DIR/received -y 2>&1
# Expected: CLIError "PCEProtocolError AUTH"

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

### 5.3 PostgreSQL backend

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
psql -U postgres -c "CREATE DATABASE xftp_server_store OWNER xftp;"

$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

psql -U xftp -d xftp_server_store -c "CREATE SCHEMA IF NOT EXISTS xftp_server;"

$XFTP_SERVER start --confirm-migrations up &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/persist.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/persist.bin $TEST_DIR/descriptions -s "$SRV" -n 1

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; sleep 1

$XFTP_SERVER start --confirm-migrations up &
SERVER_PID=$!; sleep 2

$XFTP recv $TEST_DIR/descriptions/persist.bin.xftp/rcv1.xftp $TEST_DIR/received -y
diff $TEST_DIR/persist.bin $TEST_DIR/received/persist.bin

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

## 6. Edge cases

### 6.1 Receive after server-side delete

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/deltest.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/deltest.bin $TEST_DIR/descriptions -s "$SRV" -n 2

$XFTP del $TEST_DIR/descriptions/deltest.bin.xftp/snd.xftp.private -y

$XFTP recv $TEST_DIR/descriptions/deltest.bin.xftp/rcv2.xftp $TEST_DIR/received -y 2>&1
# Expected: AUTH error

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

### 6.2 Multiple recipients and partial acknowledgment

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/multi.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/multi.bin $TEST_DIR/descriptions -s "$SRV" -n 3

$XFTP recv $TEST_DIR/descriptions/multi.bin.xftp/rcv1.xftp $TEST_DIR/received -y
diff $TEST_DIR/multi.bin $TEST_DIR/received/multi.bin

rm -f $TEST_DIR/received/multi.bin
$XFTP recv $TEST_DIR/descriptions/multi.bin.xftp/rcv2.xftp $TEST_DIR/received -y
diff $TEST_DIR/multi.bin $TEST_DIR/received/multi.bin

rm -f $TEST_DIR/received/multi.bin
$XFTP recv $TEST_DIR/descriptions/multi.bin.xftp/rcv3.xftp $TEST_DIR/received -y
diff $TEST_DIR/multi.bin $TEST_DIR/received/multi.bin

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

### 6.3 Switching to database mode with existing store log (should fail)

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
psql -U postgres -c "CREATE DATABASE xftp_server_store OWNER xftp;"

$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

# Run memory mode to create a store log
$XFTP_SERVER start &
SERVER_PID=$!; sleep 2
dd if=/dev/urandom of=$TEST_DIR/dummy.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/dummy.bin $TEST_DIR/descriptions -s "$SRV" -n 1
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; sleep 1

ls $XFTP_SERVER_LOG_PATH/file-server-store.log  # should exist

# Switch to DB mode without importing
ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size
psql -U xftp -d xftp_server_store -c "CREATE SCHEMA IF NOT EXISTS xftp_server;"

$XFTP_SERVER start --confirm-migrations up 2>&1
# Expected error:
# Error: store log file .../file-server-store.log exists but store_files is `database`.
# Use `file-server database import` to migrate, or set `db_store_log: on`.
```

### 6.4 Database mode without schema (should fail)

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
psql -U postgres -c "CREATE DATABASE xftp_server_store OWNER xftp;"

$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size

# Do NOT create the schema
$XFTP_SERVER start --confirm-migrations up 2>&1
# Expected error:
# connectPostgresStore, schema xftp_server does not exist, exiting.
```

### 6.5 Dual-write mode: database + db_store_log: on

Verifies that writes in dual-write mode land in BOTH the DB and the store log.

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
psql -U postgres -c "CREATE DATABASE xftp_server_store OWNER xftp;"

$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size
ini_uncomment db_store_log
ini_set db_store_log on
psql -U xftp -d xftp_server_store -c "CREATE SCHEMA IF NOT EXISTS xftp_server;"
rm -f $XFTP_SERVER_LOG_PATH/file-server-store.log

FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

$XFTP_SERVER start --confirm-migrations up &
SERVER_PID=$!; sleep 2

# Send a new file in dual-write mode
dd if=/dev/urandom of=$TEST_DIR/dual.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/dual.bin $TEST_DIR/descriptions -s "$SRV" -n 1

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; sleep 1

# Both the store log AND the DB must have entries
ls -la $XFTP_SERVER_LOG_PATH/file-server-store.log  # size > 0
psql -U xftp -d xftp_server_store -c "SET search_path TO xftp_server; SELECT count(*) FROM files;"
# Expected: > 0

# Now switch to memory-only and verify the file is accessible (proves store log has valid data)
ini_set store_files memory
ini_comment db_connection
ini_comment db_schema
ini_comment db_pool_size
ini_comment db_store_log

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

$XFTP recv $TEST_DIR/descriptions/dual.bin.xftp/rcv1.xftp $TEST_DIR/received -y
diff $TEST_DIR/dual.bin $TEST_DIR/received/dual.bin
echo "Dual-write mode verified: same file accessible from DB and from store log"

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

### 6.6 Import to non-empty database (should fail)

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
psql -U postgres -c "CREATE DATABASE xftp_server_store OWNER xftp;"

$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

psql -U xftp -d xftp_server_store -c "CREATE SCHEMA IF NOT EXISTS xftp_server;"
rm -f $XFTP_SERVER_LOG_PATH/file-server-store.log

$XFTP_SERVER start --confirm-migrations up &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/dummy.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/dummy.bin $TEST_DIR/descriptions -s "$SRV" -n 1
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null

# Export produces a real valid store log, then re-import into non-empty DB
echo Y | $XFTP_SERVER database export
echo Y | $XFTP_SERVER database import 2>&1
# Expected: import fails because DB is not empty
```

### 6.7 Import without store log file (should fail)

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size

rm -f $XFTP_SERVER_LOG_PATH/file-server-store.log

echo Y | $XFTP_SERVER database import 2>&1
# Expected: Error: store log file ... does not exist.
```

### 6.8 Export when store log already exists (should fail)

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
psql -U postgres -c "CREATE DATABASE xftp_server_store OWNER xftp;"

$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

psql -U xftp -d xftp_server_store -c "CREATE SCHEMA IF NOT EXISTS xftp_server;"
rm -f $XFTP_SERVER_LOG_PATH/file-server-store.log

$XFTP_SERVER start --confirm-migrations up &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/exp.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/exp.bin $TEST_DIR/descriptions -s "$SRV" -n 1
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null

echo "existing" > $XFTP_SERVER_LOG_PATH/file-server-store.log
echo Y | $XFTP_SERVER database export 2>&1
# Expected: Error: store log file ... already exists.
```

## 7. File blocking via control port

### 7.1 Block a file, verify receive fails

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
enable_control_port
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/blockme.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/blockme.bin $TEST_DIR/descriptions -s "$SRV" -n 2

# Extract the first recipient ID from the descriptor
RCV_ID=$(get_recipient_ids $TEST_DIR/descriptions/blockme.bin.xftp/rcv1.xftp | head -1)
echo "Blocking recipient ID: $RCV_ID"

control_cmd "block $RCV_ID reason=spam"
# Expected: ok

$XFTP recv $TEST_DIR/descriptions/blockme.bin.xftp/rcv1.xftp $TEST_DIR/received -y 2>&1
# Expected: CLIError "PCEProtocolError (BLOCKED {blockInfo = BlockingInfo {reason = BRSpam, ...}})"

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

### 7.2 Blocked file survives memory -> PG migration

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
psql -U postgres -c "CREATE DATABASE xftp_server_store OWNER xftp;"

$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
enable_control_port
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/blockmigrate.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/blockmigrate.bin $TEST_DIR/descriptions -s "$SRV" -n 2

RCV_ID=$(get_recipient_ids $TEST_DIR/descriptions/blockmigrate.bin.xftp/rcv1.xftp | head -1)
control_cmd "block $RCV_ID reason=content"

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; sleep 1

# Migrate to PG
ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size
echo Y | $XFTP_SERVER database import

$XFTP_SERVER start --confirm-migrations up &
SERVER_PID=$!; sleep 2

$XFTP recv $TEST_DIR/descriptions/blockmigrate.bin.xftp/rcv1.xftp $TEST_DIR/received -y 2>&1
# Expected: BLOCKED error

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

### 7.3 Blocked file survives PG -> memory export

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
psql -U postgres -c "CREATE DATABASE xftp_server_store OWNER xftp;"

$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size
enable_control_port
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

psql -U xftp -d xftp_server_store -c "CREATE SCHEMA IF NOT EXISTS xftp_server;"
rm -f $XFTP_SERVER_LOG_PATH/file-server-store.log

$XFTP_SERVER start --confirm-migrations up &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/blockpg.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/blockpg.bin $TEST_DIR/descriptions -s "$SRV" -n 2

RCV_ID=$(get_recipient_ids $TEST_DIR/descriptions/blockpg.bin.xftp/rcv1.xftp | head -1)
control_cmd "block $RCV_ID reason=spam"

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; sleep 1

echo Y | $XFTP_SERVER database export
ini_set store_files memory
ini_comment db_connection
ini_comment db_schema
ini_comment db_pool_size

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

$XFTP recv $TEST_DIR/descriptions/blockpg.bin.xftp/rcv1.xftp $TEST_DIR/received -y 2>&1
# Expected: BLOCKED error

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

## 8. Migration edge cases

### 8.1 Acked recipient preserved after memory -> PG migration

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
psql -U postgres -c "CREATE DATABASE xftp_server_store OWNER xftp;"

$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/acktest.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/acktest.bin $TEST_DIR/descriptions -s "$SRV" -n 2

# BACKUP rcv1 descriptor before recv (recv -y deletes it)
cp $TEST_DIR/descriptions/acktest.bin.xftp/rcv1.xftp $TEST_DIR/rcv1_backup.xftp

# Recv rcv1 (acks it server-side, deletes descriptor)
$XFTP recv $TEST_DIR/descriptions/acktest.bin.xftp/rcv1.xftp $TEST_DIR/received -y

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; sleep 1

# Migrate to PG
ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size
echo Y | $XFTP_SERVER database import

$XFTP_SERVER start --confirm-migrations up &
SERVER_PID=$!; sleep 2

# Acked rcv1 MUST fail (recipient removed by ack, preserved through migration)
$XFTP recv $TEST_DIR/rcv1_backup.xftp $TEST_DIR/received -y 2>&1
# Expected: AUTH error

# Unacked rcv2 MUST work
rm -f $TEST_DIR/received/acktest.bin
$XFTP recv $TEST_DIR/descriptions/acktest.bin.xftp/rcv2.xftp $TEST_DIR/received -y
diff $TEST_DIR/acktest.bin $TEST_DIR/received/acktest.bin

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

### 8.2 Acked recipient preserved after PG -> memory export

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
psql -U postgres -c "CREATE DATABASE xftp_server_store OWNER xftp;"

$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

psql -U xftp -d xftp_server_store -c "CREATE SCHEMA IF NOT EXISTS xftp_server;"
rm -f $XFTP_SERVER_LOG_PATH/file-server-store.log

$XFTP_SERVER start --confirm-migrations up &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/ackpg.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/ackpg.bin $TEST_DIR/descriptions -s "$SRV" -n 2

cp $TEST_DIR/descriptions/ackpg.bin.xftp/rcv1.xftp $TEST_DIR/rcv1_backup.xftp
$XFTP recv $TEST_DIR/descriptions/ackpg.bin.xftp/rcv1.xftp $TEST_DIR/received -y

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; sleep 1

echo Y | $XFTP_SERVER database export

ini_set store_files memory
ini_comment db_connection
ini_comment db_schema
ini_comment db_pool_size

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

$XFTP recv $TEST_DIR/rcv1_backup.xftp $TEST_DIR/received -y 2>&1
# Expected: AUTH error

rm -f $TEST_DIR/received/ackpg.bin
$XFTP recv $TEST_DIR/descriptions/ackpg.bin.xftp/rcv2.xftp $TEST_DIR/received -y
diff $TEST_DIR/ackpg.bin $TEST_DIR/received/ackpg.bin

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

### 8.3 Deleted file absent after migration (positive + negative control)

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
psql -U postgres -c "CREATE DATABASE xftp_server_store OWNER xftp;"

$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

# File to be deleted (use n=2, backup rcv2 before delete)
dd if=/dev/urandom of=$TEST_DIR/delmigrate.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/delmigrate.bin $TEST_DIR/descriptions -s "$SRV" -n 2
cp $TEST_DIR/descriptions/delmigrate.bin.xftp/rcv2.xftp $TEST_DIR/rcv2_del_backup.xftp

$XFTP recv $TEST_DIR/descriptions/delmigrate.bin.xftp/rcv1.xftp $TEST_DIR/received -y
$XFTP del $TEST_DIR/descriptions/delmigrate.bin.xftp/snd.xftp.private -y

# Positive control: a file that is NOT deleted
dd if=/dev/urandom of=$TEST_DIR/keepmigrate.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/keepmigrate.bin $TEST_DIR/descriptions -s "$SRV" -n 1

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; sleep 1

ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size
echo Y | $XFTP_SERVER database import

psql -U xftp -d xftp_server_store -c "SET search_path TO xftp_server; SELECT count(*) FROM files;"
# Expected: > 0 (kept file imported)

$XFTP_SERVER start --confirm-migrations up &
SERVER_PID=$!; sleep 2

# Positive: kept file MUST be receivable
$XFTP recv $TEST_DIR/descriptions/keepmigrate.bin.xftp/rcv1.xftp $TEST_DIR/received -y
diff $TEST_DIR/keepmigrate.bin $TEST_DIR/received/keepmigrate.bin

# Negative: deleted file's rcv2 MUST return AUTH
$XFTP recv $TEST_DIR/rcv2_del_backup.xftp $TEST_DIR/received -y 2>&1
# Expected: AUTH error

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

### 8.4 Large multi-chunk file integrity after migration

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
psql -U postgres -c "CREATE DATABASE xftp_server_store OWNER xftp;"

$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/largefile.bin bs=1M count=20 2>/dev/null
$XFTP send $TEST_DIR/largefile.bin $TEST_DIR/descriptions -s "$SRV" -n 1

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; sleep 1

ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size
echo Y | $XFTP_SERVER database import

$XFTP_SERVER start --confirm-migrations up &
SERVER_PID=$!; sleep 2

$XFTP recv $TEST_DIR/descriptions/largefile.bin.xftp/rcv1.xftp $TEST_DIR/received -y
diff $TEST_DIR/largefile.bin $TEST_DIR/received/largefile.bin
echo "20MB multi-chunk integrity preserved"

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

### 8.5 Double round-trip: memory -> PG -> memory -> PG

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
psql -U postgres -c "CREATE DATABASE xftp_server_store OWNER xftp;"

$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2
dd if=/dev/urandom of=$TEST_DIR/roundtrip.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/roundtrip.bin $TEST_DIR/descriptions -s "$SRV" -n 1
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; sleep 1

# Round 1: memory -> PG
ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size
echo Y | $XFTP_SERVER database import
$XFTP_SERVER start --confirm-migrations up &
SERVER_PID=$!; sleep 2
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; sleep 1

# Round 1: PG -> memory
echo Y | $XFTP_SERVER database export
ini_set store_files memory
ini_comment db_connection
ini_comment db_schema
ini_comment db_pool_size
$XFTP_SERVER start &
SERVER_PID=$!; sleep 2
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; sleep 1

# Round 2: memory -> PG
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
psql -U postgres -c "CREATE DATABASE xftp_server_store OWNER xftp;"
ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size
echo Y | $XFTP_SERVER database import

$XFTP_SERVER start --confirm-migrations up &
SERVER_PID=$!; sleep 2

$XFTP recv $TEST_DIR/descriptions/roundtrip.bin.xftp/rcv1.xftp $TEST_DIR/received -y
diff $TEST_DIR/roundtrip.bin $TEST_DIR/received/roundtrip.bin
echo "File intact after memory->PG->memory->PG double round-trip"

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

## 9. Auth and access control

### 9.1 allowNewFiles=false rejects upload

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
ini_set new_files off
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/reject.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/reject.bin $TEST_DIR/descriptions -s "$SRV" -n 1 2>&1
# Expected: upload fails

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

### 9.2 Basic auth: no password → fails with AUTH

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
sed -i 's/^# create_password:.*$/create_password: secret123/' $XFTP_SERVER_CFG_PATH/file-server.ini
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/authtest.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/authtest.bin $TEST_DIR/descriptions -s "$SRV" -n 1 2>&1
# Expected: AUTH error

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

### 9.3 Basic auth: wrong password → PCEProtocolError AUTH

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
sed -i 's/^# create_password:.*$/create_password: secret123/' $XFTP_SERVER_CFG_PATH/file-server.ini
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
WRONG_SRV="xftp://$FP:wrongpass@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/authtest.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/authtest.bin $TEST_DIR/descriptions -s "$WRONG_SRV" -n 1 2>&1
# Expected: "PCEProtocolError AUTH" in output
ls $TEST_DIR/descriptions/authtest.bin.xftp/rcv1.xftp 2>&1
# Expected: No such file or directory (no descriptor created)

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

### 9.4 Basic auth: correct password → succeeds

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
sed -i 's/^# create_password:.*$/create_password: secret123/' $XFTP_SERVER_CFG_PATH/file-server.ini
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
CORRECT_SRV="xftp://$FP:secret123@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/authok.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/authok.bin $TEST_DIR/descriptions -s "$CORRECT_SRV" -n 1

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

### 9.5 Server without auth, client sends auth → succeeds

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
AUTH_SRV="xftp://$FP:anypass@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/noauth.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/noauth.bin $TEST_DIR/descriptions -s "$AUTH_SRV" -n 1

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

### 9.6 Storage quota boundary

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
$XFTP_SERVER init -p $TEST_DIR/files -q 3mb --ip 127.0.0.1
ini_set port 7921
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/quota1.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/quota1.bin $TEST_DIR/descriptions -s "$SRV" -n 1

dd if=/dev/urandom of=$TEST_DIR/quota2.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/quota2.bin $TEST_DIR/descriptions -s "$SRV" -n 1

dd if=/dev/urandom of=$TEST_DIR/quota3.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/quota3.bin $TEST_DIR/descriptions -s "$SRV" -n 1 2>&1
# Expected: QUOTA error

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

### 9.7 File expiration

File expiration is not testable in a fast manual test because `createdAt` uses hour-level precision (`fileTimePrecision = 3600s`) and the check interval is hardcoded at 2 hours. It is tested in the Haskell test suite (`testFileChunkExpiration` with a 1-second TTL).

## 10. Control port operations

### 10.1 Command without auth → AUTH

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
enable_control_port
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/ctrldel.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/ctrldel.bin $TEST_DIR/descriptions -s "$SRV" -n 1
RCV_ID=$(get_recipient_ids $TEST_DIR/descriptions/ctrldel.bin.xftp/rcv1.xftp | head -1)

# No auth
python3 -c "
import socket, time
s = socket.create_connection(('127.0.0.1', 15230), timeout=5)
s.settimeout(2)
time.sleep(0.3); s.recv(4096)
s.sendall(b'delete $RCV_ID\n')
time.sleep(0.3)
print(s.recv(4096).decode().strip())
s.sendall(b'quit\n'); s.close()
"
# Expected: AUTH
```

### 10.2 Wrong password → CPRNone, commands return AUTH

```bash
python3 -c "
import socket, time
s = socket.create_connection(('127.0.0.1', 15230), timeout=5)
s.settimeout(2)
time.sleep(0.3); s.recv(4096)
s.sendall(b'auth wrongpassword\n')
time.sleep(0.3)
print('auth:', s.recv(4096).decode().strip())
# Expected: Current role is CPRNone
s.sendall(b'delete $RCV_ID\n')
time.sleep(0.3)
print('delete:', s.recv(4096).decode().strip())
# Expected: AUTH
s.sendall(b'quit\n'); s.close()
"
```

### 10.3 stats-rts responds

```bash
control_cmd "stats-rts"
# Expected: either GHC RTS stats or "unsupported operation (GHC.Stats.getRTSStats: ...)"
```

### 10.4 Delete command removes file

```bash
control_cmd "delete $RCV_ID"
# Expected: ok

$XFTP recv $TEST_DIR/descriptions/ctrldel.bin.xftp/rcv1.xftp $TEST_DIR/received -y 2>&1
# Expected: AUTH error
```

### 10.5 Invalid block reason → error:

```bash
dd if=/dev/urandom of=$TEST_DIR/badblock.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/badblock.bin $TEST_DIR/descriptions -s "$SRV" -n 1
RCV_ID2=$(get_recipient_ids $TEST_DIR/descriptions/badblock.bin.xftp/rcv1.xftp | head -1)

control_cmd "block $RCV_ID2 reason=invalid_reason"
# Expected: error:...

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

## 11. Blocked file: sender cannot delete

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
enable_control_port
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

$XFTP_SERVER start &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/blockdel.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/blockdel.bin $TEST_DIR/descriptions -s "$SRV" -n 1

RCV_ID=$(get_recipient_ids $TEST_DIR/descriptions/blockdel.bin.xftp/rcv1.xftp | head -1)
control_cmd "block $RCV_ID reason=spam"

# Sender delete should fail with BLOCKED
$XFTP del $TEST_DIR/descriptions/blockdel.bin.xftp/snd.xftp.private -y 2>&1
# Expected: BLOCKED error

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

## 12. Recipient cascade and storage accounting

### 12.1 Recipient cascade delete (PG)

```bash
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{files,descriptions,received}
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
psql -U postgres -c "CREATE DATABASE xftp_server_store OWNER xftp;"

$XFTP_SERVER init -p $TEST_DIR/files -q 10gb --ip 127.0.0.1
ini_set port 7921
ini_set store_files database
ini_uncomment db_connection
ini_uncomment db_schema
ini_uncomment db_pool_size
FP=$(cat $XFTP_SERVER_CFG_PATH/fingerprint)
SRV="xftp://$FP@127.0.0.1:7921"

psql -U xftp -d xftp_server_store -c "CREATE SCHEMA IF NOT EXISTS xftp_server;"
rm -f $XFTP_SERVER_LOG_PATH/file-server-store.log

$XFTP_SERVER start --confirm-migrations up &
SERVER_PID=$!; sleep 2

dd if=/dev/urandom of=$TEST_DIR/cascade.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/cascade.bin $TEST_DIR/descriptions -s "$SRV" -n 3

psql -U xftp -d xftp_server_store -c "SET search_path TO xftp_server; SELECT count(*) FROM files;"
# Expected: > 0
psql -U xftp -d xftp_server_store -c "SET search_path TO xftp_server; SELECT count(*) FROM recipients;"
# Expected: > 0

$XFTP del $TEST_DIR/descriptions/cascade.bin.xftp/snd.xftp.private -y

psql -U xftp -d xftp_server_store -c "SET search_path TO xftp_server; SELECT count(*) FROM files;"
# Expected: 0
psql -U xftp -d xftp_server_store -c "SET search_path TO xftp_server; SELECT count(*) FROM recipients;"
# Expected: 0 (cascade delete)
```

### 12.2 Storage accounting

```bash
dd if=/dev/urandom of=$TEST_DIR/stor1.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/stor1.bin $TEST_DIR/descriptions -s "$SRV" -n 1

dd if=/dev/urandom of=$TEST_DIR/stor2.bin bs=1M count=1 2>/dev/null
$XFTP send $TEST_DIR/stor2.bin $TEST_DIR/descriptions -s "$SRV" -n 1

ls $TEST_DIR/files/ | wc -l
# Expected: > 0

$XFTP del $TEST_DIR/descriptions/stor1.bin.xftp/snd.xftp.private -y
$XFTP del $TEST_DIR/descriptions/stor2.bin.xftp/snd.xftp.private -y

ls $TEST_DIR/files/ | wc -l
# Expected: 0

psql -U xftp -d xftp_server_store -c "SET search_path TO xftp_server; SELECT count(*) FROM files;"
# Expected: 0

kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
```

## Cleanup

```bash
kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null
rm -rf $TEST_DIR
psql -U postgres -c "DROP DATABASE IF EXISTS xftp_server_store;"
```

## Summary of expected results

| # | Scenario | Expected |
|---|----------|----------|
| 1 | Send/receive on memory | OK |
| 2 | Send/receive on PostgreSQL | OK (DB rows match) |
| 3 | Memory → PG, receive remaining | OK |
| 4 | PG → memory, delete round-trip | OK |
| 4b | Send PG, export, receive on memory | OK |
| 5.1 | Restart persistence (memory + log) | OK |
| 5.2 | Restart persistence (memory, no log) | AUTH error |
| 5.3 | Restart persistence (PostgreSQL) | OK |
| 6.1 | Receive after server delete | AUTH error |
| 6.2 | Multiple recipients (n=3) | All work |
| 6.3 | DB mode + existing store log | Server refuses |
| 6.4 | DB mode + no schema | Server fails |
| 6.5 | Dual-write (db_store_log: on) | Both DB and log have data |
| 6.6 | Import to non-empty DB | Error |
| 6.7 | Import without store log | Error |
| 6.8 | Export when store log exists | Error |
| 7.1 | Block file, receive fails | BLOCKED (not AUTH) |
| 7.2 | Block survives memory → PG | BLOCKED |
| 7.3 | Block survives PG → memory | BLOCKED |
| 8.1 | Acked rcv1 fails, rcv2 works (memory → PG) | AUTH + OK |
| 8.2 | Acked rcv1 fails, rcv2 works (PG → memory) | AUTH + OK |
| 8.3 | Deleted file absent, kept file present | rcv2_del=AUTH, kept=OK |
| 8.4 | Large 20MB multi-chunk migration | Integrity preserved |
| 8.5 | Double round-trip memory↔PG | Intact |
| 9.1 | new_files=off | Upload rejected |
| 9.2 | Basic auth, no password | AUTH |
| 9.3 | Basic auth, wrong password | PCEProtocolError AUTH |
| 9.4 | Basic auth, correct password | OK |
| 9.5 | No server auth, client sends auth | OK |
| 9.6 | Quota boundary | 3rd file QUOTA error |
| 10.1 | Control port, no auth | AUTH |
| 10.2 | Control port, wrong password | CPRNone → AUTH |
| 10.3 | stats-rts | Responds |
| 10.4 | Control port delete | ok → recv AUTH |
| 10.5 | Invalid block reason | error: |
| 11 | Blocked file, sender delete | BLOCKED |
| 12.1 | Recipient cascade delete (PG) | files=0, recipients=0 |
| 12.2 | Storage accounting | disk=0, DB=0 |
