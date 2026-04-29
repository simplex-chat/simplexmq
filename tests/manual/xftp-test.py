#!/usr/bin/env python3
"""
Automated XFTP server test suite.
Tests memory and PostgreSQL backends, migration, persistence, and edge cases.

Prerequisites:
  cabal build -fserver_postgres exe:xftp-server exe:xftp
  PostgreSQL running (set PGHOST if non-default socket)
  User 'xftp' with SUPERUSER must exist:
    psql -U postgres -c "CREATE USER xftp WITH SUPERUSER;"

Usage:
  python3 tests/manual/xftp-test.py
  PGHOST=/tmp/pgsocket python3 tests/manual/xftp-test.py
"""

import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import traceback
from pathlib import Path


# --- Configuration ---

PORT = "7921"
DB_NAME = "xftp_server_store"
DB_USER = "xftp"
DB_SCHEMA = "xftp_server"
PG_ADMIN_USER = "postgres"


# --- State ---

PASS = 0
FAIL = 0
server_proc = None


# --- Helpers ---

def run(cmd, *, check=True, input=None, timeout=30):
    """Run a command, return CompletedProcess."""
    r = subprocess.run(
        cmd, shell=isinstance(cmd, str),
        capture_output=True, text=True,
        input=input, timeout=timeout,
    )
    if check and r.returncode != 0:
        raise subprocess.CalledProcessError(r.returncode, cmd, r.stdout, r.stderr)
    return r


def cabal_bin(name):
    r = run(f"cabal list-bin exe:{name}")
    p = r.stdout.strip()
    if not os.path.isfile(p):
        sys.exit(f"Binary not found: {p}\nRun: cabal build -fserver_postgres exe:{name}")
    return p


def psql(sql, *, user=PG_ADMIN_USER, db="postgres", check=True):
    return run(["psql", "-U", user, "-d", db, "-t", "-A", "-c", sql], check=check)


def db_count(table):
    r = psql(f"SET search_path TO {DB_SCHEMA}; SELECT count(*) FROM {table};",
             user=DB_USER, db=DB_NAME, check=False)
    if r.returncode != 0:
        return -1
    # psql -t -A output includes "SET" line from SET search_path, take the last line
    lines = [l.strip() for l in r.stdout.strip().split("\n") if l.strip() and l.strip() != "SET"]
    return int(lines[-1]) if lines else -1


def pass_(desc):
    global PASS
    PASS += 1
    print(f"  [PASS] {desc}")


def fail_(desc):
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {desc}")


def check(desc, condition):
    if condition:
        pass_(desc)
    else:
        fail_(desc)



# --- INI helpers ---

def ini_set(key, value):
    ini = ini_path()
    txt = ini.read_text()
    new_txt, n = re.subn(rf"^{re.escape(key)}:.*$", f"{key}: {value}", txt, flags=re.MULTILINE)
    assert n > 0, f"ini_set: key '{key}' not found in {ini}"
    ini.write_text(new_txt)


def ini_uncomment(key):
    ini = ini_path()
    txt = ini.read_text()
    new_txt, n = re.subn(rf"^# {re.escape(key)}:", f"{key}:", txt, flags=re.MULTILINE)
    assert n > 0, f"ini_uncomment: commented key '# {key}' not found in {ini}"
    ini.write_text(new_txt)


def ini_comment(key):
    ini = ini_path()
    txt = ini.read_text()
    new_txt, n = re.subn(rf"^{re.escape(key)}:", f"# {key}:", txt, flags=re.MULTILINE)
    assert n > 0, f"ini_comment: key '{key}' not found in {ini}"
    ini.write_text(new_txt)


def ini_path():
    return Path(os.environ["XFTP_SERVER_CFG_PATH"]) / "file-server.ini"


# --- Server management ---

def init_server(quota="10gb"):
    run([XFTP_SERVER, "init", "-p", str(test_dir / "files"), "-q", quota, "--ip", "127.0.0.1"])
    ini_set("port", PORT)
    fp = (Path(os.environ["XFTP_SERVER_CFG_PATH"]) / "fingerprint").read_text().strip()
    return f"xftp://{fp}@127.0.0.1:{PORT}"


_server_log_fh = None

def start_server(*extra_args):
    global server_proc, _server_log_fh
    stop_server()
    log_path = test_dir / "server.log"
    _server_log_fh = open(log_path, "w")
    server_proc = subprocess.Popen(
        [XFTP_SERVER, "start"] + list(extra_args),
        stdout=_server_log_fh,
        stderr=subprocess.STDOUT,
    )
    time.sleep(2)
    if server_proc.poll() is not None:
        _server_log_fh.close()
        _server_log_fh = None
        log = log_path.read_text()
        print(f"  [ERROR] Server exited with code {server_proc.returncode}")
        for line in log.strip().split("\n")[-5:]:
            print(f"    {line}")
        return False
    return True


def stop_server():
    global server_proc, _server_log_fh
    if server_proc and server_proc.poll() is None:
        server_proc.send_signal(signal.SIGTERM)
        try:
            server_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server_proc.kill()
            server_proc.wait()
    server_proc = None
    if _server_log_fh:
        _server_log_fh.close()
        _server_log_fh = None
    time.sleep(0.5)


def clean_test_dir():
    stop_server()
    if test_dir.exists():
        shutil.rmtree(test_dir)
    (test_dir / "files").mkdir(parents=True)
    (test_dir / "descriptions").mkdir()
    (test_dir / "received").mkdir()


def clean_db():
    psql(f"DROP DATABASE IF EXISTS {DB_NAME};")
    psql(f"CREATE DATABASE {DB_NAME} OWNER {DB_USER};")


def enable_db_mode():
    ini_set("store_files", "database")
    ini_uncomment("db_connection")
    ini_uncomment("db_schema")
    ini_uncomment("db_pool_size")


def disable_db_mode():
    ini_set("store_files", "memory")
    ini_comment("db_connection")
    ini_comment("db_schema")
    ini_comment("db_pool_size")


# --- File operations ---

def make_file(name, size_mb=1):
    path = test_dir / name
    with open(path, "wb") as f:
        f.write(os.urandom(size_mb * 1024 * 1024))
    return path


def desc_dir(name):
    return test_dir / "descriptions" / f"{name}.xftp"


def send_file(src, n=1):
    return run([XFTP, "send", str(src), str(test_dir / "descriptions"),
                "-s", srv, "-n", str(n)], check=False, timeout=60)


def recv_file(desc_path):
    return run([XFTP, "recv", str(desc_path), str(test_dir / "received"), "-y"],
               check=False, timeout=60)


def del_file(desc_path):
    return run([XFTP, "del", str(desc_path), "-y"], check=False, timeout=30)


def files_match(a, b):
    """Compare two files byte-for-byte. Both must exist."""
    a, b = Path(a), Path(b)
    if not a.exists() or not b.exists():
        return False
    return a.read_bytes() == b.read_bytes()


def db_import():
    return run([XFTP_SERVER, "database", "import"], input="Y\n", check=False, timeout=30)


def db_export():
    return run([XFTP_SERVER, "database", "export"], input="Y\n", check=False, timeout=30)


def create_schema():
    """Create the xftp_server schema so the server can start on a fresh DB."""
    psql(f"CREATE SCHEMA IF NOT EXISTS {DB_SCHEMA};", user=DB_USER, db=DB_NAME)


CONTROL_PORT = "15230"
CONTROL_PASSWORD = "testadmin"


def enable_control_port():
    ini = ini_path()
    txt = ini.read_text()
    txt, n1 = re.subn(r"^# control_port:.*$", f"control_port: {CONTROL_PORT}", txt, flags=re.MULTILINE)
    txt, n2 = re.subn(r"^# control_port_admin_password:.*$",
                       f"control_port_admin_password: {CONTROL_PASSWORD}", txt, flags=re.MULTILINE)
    assert n1 > 0, "enable_control_port: '# control_port' not found in INI"
    assert n2 > 0, "enable_control_port: '# control_port_admin_password' not found in INI"
    ini.write_text(txt)


def control_recv(s):
    """Receive all available data from control port (drains buffer)."""
    time.sleep(0.3)
    chunks = []
    s.settimeout(0.5)
    while True:
        try:
            data = s.recv(4096)
            if not data:
                break
            chunks.append(data)
        except socket.timeout:
            break
    return b"".join(chunks).decode().strip()


def control_send_recv(s, cmd):
    """Send a command and receive the response line."""
    s.sendall(f"{cmd}\n".encode())
    return control_recv(s)


def control_connect():
    """Connect to control port, drain welcome banner, return socket."""
    s = socket.create_connection(("127.0.0.1", int(CONTROL_PORT)), timeout=5)
    try:
        control_recv(s)  # drain welcome banner (2 lines)
    except Exception:
        s.close()
        raise
    return s


def control_cmd(cmd, *, auth=True):
    """Send a command to the server control port, return the response.
    If auth=True, authenticates as admin first and verifies the role."""
    s = control_connect()
    try:
        if auth:
            auth_resp = control_send_recv(s, f"auth {CONTROL_PASSWORD}")
            assert auth_resp == "Current role is CPRAdmin", \
                f"control_cmd: auth failed, got: {auth_resp!r}"
        return control_send_recv(s, cmd)
    finally:
        try:
            s.sendall(b"quit\n")
        except OSError:
            pass
        s.close()


def get_recipient_ids(desc_path):
    """Extract recipient IDs from a file description (.xftp file)."""
    text = Path(desc_path).read_text()
    ids = []
    for line in text.split("\n"):
        line = line.strip()
        if line.startswith("- ") and ":" in line:
            # Format: - N:recipientId:privateKey:digest[:size]
            parts = line[2:].split(":")
            if len(parts) >= 3:
                ids.append(parts[1])
    return ids



# ===================================================================
# Tests
# ===================================================================

def test_1_basic_memory():
    global srv
    print("\n=== 1. Basic send/receive (memory) ===")
    clean_test_dir()
    srv = init_server()
    assert start_server()

    src = make_file("testfile.bin", 5)
    send_file(src, n=2)

    dd = desc_dir("testfile.bin")
    check("1.1 rcv1.xftp created", (dd / "rcv1.xftp").exists())
    check("1.2 rcv2.xftp created", (dd / "rcv2.xftp").exists())
    check("1.3 snd.xftp.private created", (dd / "snd.xftp.private").exists())

    recv_file(dd / "rcv1.xftp")
    check("1.4 rcv1 file matches", files_match(src, test_dir / "received/testfile.bin"))
    check("1.5 rcv1.xftp deleted by -y", not (dd / "rcv1.xftp").exists())

    (test_dir / "received/testfile.bin").unlink(missing_ok=True)
    recv_file(dd / "rcv2.xftp")
    check("1.6 rcv2 file matches", files_match(src, test_dir / "received/testfile.bin"))
    check("1.7 rcv2.xftp deleted by -y", not (dd / "rcv2.xftp").exists())

    del_file(dd / "snd.xftp.private")
    check("1.8 snd.xftp.private deleted by -y", not (dd / "snd.xftp.private").exists())
    fc = len(list((test_dir / "files").iterdir()))
    check(f"1.9 server files cleaned ({fc})", fc == 0)

    stop_server()


def test_2_basic_postgres():
    global srv
    print("\n=== 2. Basic send/receive (PostgreSQL) ===")
    clean_test_dir()
    clean_db()
    srv = init_server()
    enable_db_mode()
    # Remove store log so database mode starts cleanly
    store_log = Path(os.environ["XFTP_SERVER_LOG_PATH"]) / "file-server-store.log"
    store_log.unlink(missing_ok=True)
    # Create schema so server can connect
    create_schema()
    ok = start_server("--confirm-migrations", "up")
    check("2.1 server started", ok)
    if not ok:
        return

    src = make_file("testfile.bin", 5)
    send_file(src, n=2)
    dd = desc_dir("testfile.bin")
    check("2.2 send succeeded", (dd / "rcv1.xftp").exists())

    recv_file(dd / "rcv1.xftp")
    check("2.3 recv matches", files_match(src, test_dir / "received/testfile.bin"))

    fc = db_count("files")
    rc = db_count("recipients")
    check(f"2.4 files in database ({fc})", fc > 0 and fc != -1)
    check(f"2.5 recipients in database ({rc})", rc > 0 and rc != -1)

    del_file(dd / "snd.xftp.private")
    fc_after = db_count("files")
    rc_after = db_count("recipients")
    check(f"2.6 all files deleted ({fc_after})", fc_after == 0)
    check(f"2.7 all recipients deleted ({rc_after})", rc_after == 0)

    stop_server()


def test_3_migration_memory_to_pg():
    global srv
    print("\n=== 3. Migration: memory -> PostgreSQL ===")
    clean_test_dir()
    clean_db()
    srv = init_server()
    assert start_server()

    srcA = make_file("fileA.bin")
    send_file(srcA, n=2)
    check("3.1 fileA sent", (desc_dir("fileA.bin") / "rcv1.xftp").exists())

    srcB = make_file("fileB.bin")
    send_file(srcB, n=2)
    check("3.2 fileB sent", (desc_dir("fileB.bin") / "rcv1.xftp").exists())

    # Partially receive fileB
    recv_file(desc_dir("fileB.bin") / "rcv1.xftp")
    check("3.3 fileB rcv1 received", files_match(srcB, test_dir / "received/fileB.bin"))

    stop_server()

    # Switch to database and import
    enable_db_mode()
    r = db_import()
    check("3.4 import succeeded", r.returncode == 0)

    log_bak = Path(os.environ["XFTP_SERVER_LOG_PATH"]) / "file-server-store.log.bak"
    log_file = Path(os.environ["XFTP_SERVER_LOG_PATH"]) / "file-server-store.log"
    check("3.5 store log renamed to .bak", log_bak.exists())
    check("3.6 store log removed", not log_file.exists())

    fc = db_count("files")
    rc = db_count("recipients")
    check(f"3.7 files imported ({fc})", fc > 0 and fc != -1)
    check(f"3.8 recipients imported ({rc})", rc > 0 and rc != -1)

    # Start PG server, receive remaining
    ok = start_server("--confirm-migrations", "up")
    check("3.9 PG server started", ok)
    if not ok:
        return

    recv_file(desc_dir("fileA.bin") / "rcv1.xftp")
    check("3.10 fileA rcv1 after migration", files_match(srcA, test_dir / "received/fileA.bin"))

    recv_file(desc_dir("fileA.bin") / "rcv2.xftp")
    # rcv2 downloads to fileA_1.bin (fileA.bin already exists from rcv1)
    rcv2_path = test_dir / "received"
    rcv2_files = [f for f in rcv2_path.iterdir() if f.name.startswith("fileA") and f.name != "fileA.bin"]
    check("3.11 fileA rcv2 after migration", len(rcv2_files) == 1 and files_match(srcA, rcv2_files[0]))

    (test_dir / "received/fileB.bin").unlink(missing_ok=True)
    recv_file(desc_dir("fileB.bin") / "rcv2.xftp")
    check("3.12 fileB rcv2 after migration", files_match(srcB, test_dir / "received/fileB.bin"))

    stop_server()


def test_4_migration_pg_to_memory():
    global srv
    print("\n=== 4. Migration: PostgreSQL -> memory ===")

    r = db_export()
    check("4.1 export succeeded", r.returncode == 0)

    log_file = Path(os.environ["XFTP_SERVER_LOG_PATH"]) / "file-server-store.log"
    check("4.2 store log created", log_file.exists())

    disable_db_mode()
    ok = start_server()
    check("4.3 memory server started", ok)
    if not ok:
        return

    r = del_file(desc_dir("fileA.bin") / "snd.xftp.private")
    check("4.4 fileA delete on memory round-trip", r.returncode == 0)

    r = del_file(desc_dir("fileB.bin") / "snd.xftp.private")
    check("4.5 fileB delete on memory round-trip", r.returncode == 0)

    stop_server()


def test_4b_send_pg_receive_memory():
    """Send on PostgreSQL, export, receive on memory."""
    global srv
    print("\n=== 4b. Send on PG, export, receive on memory ===")
    clean_test_dir()
    clean_db()
    srv = init_server()
    enable_db_mode()
    store_log = Path(os.environ["XFTP_SERVER_LOG_PATH"]) / "file-server-store.log"
    store_log.unlink(missing_ok=True)
    create_schema()
    ok = start_server("--confirm-migrations", "up")
    check("4b.1 PG server started", ok)
    if not ok:
        return

    srcA = make_file("pgfileA.bin")
    send_file(srcA, n=2)
    check("4b.2 pgfileA sent", (desc_dir("pgfileA.bin") / "rcv1.xftp").exists())

    # Partially receive rcv1 on PG
    recv_file(desc_dir("pgfileA.bin") / "rcv1.xftp")
    check("4b.3 pgfileA rcv1 on PG", files_match(srcA, test_dir / "received/pgfileA.bin"))

    stop_server()

    # Export to store log
    r = db_export()
    check("4b.4 export succeeded", r.returncode == 0)

    # Switch to memory
    disable_db_mode()
    ok = start_server()
    check("4b.5 memory server started", ok)
    if not ok:
        return

    # rcv2 should work on memory backend
    (test_dir / "received/pgfileA.bin").unlink(missing_ok=True)
    recv_file(desc_dir("pgfileA.bin") / "rcv2.xftp")
    check("4b.6 pgfileA rcv2 on memory after export", files_match(srcA, test_dir / "received/pgfileA.bin"))

    del_file(desc_dir("pgfileA.bin") / "snd.xftp.private")
    check("4b.7 delete on memory", not (desc_dir("pgfileA.bin") / "snd.xftp.private").exists())

    stop_server()


def test_5_restart_persistence():
    global srv
    print("\n=== 5. Restart persistence ===")

    # 5.1 Memory with store log
    print("  --- 5.1 memory + store log ---")
    clean_test_dir()
    srv = init_server()
    assert start_server()

    src = make_file("persist.bin")
    send_file(src)
    stop_server()
    assert start_server()

    recv_file(desc_dir("persist.bin") / "rcv1.xftp")
    check("5.1 recv after restart (memory+log)", files_match(src, test_dir / "received/persist.bin"))
    stop_server()

    # 5.2 Memory without store log
    print("  --- 5.2 memory, no log ---")
    for f in (test_dir / "descriptions").iterdir():
        shutil.rmtree(f) if f.is_dir() else f.unlink()
    for f in (test_dir / "received").iterdir():
        f.unlink()
    ini_set("enable", "off")
    assert start_server()

    src2 = make_file("persist2.bin")
    send_file(src2)
    stop_server()
    assert start_server()

    r = recv_file(desc_dir("persist2.bin") / "rcv1.xftp")
    check("5.2a recv after restart (no log) fails", r.returncode != 0)
    check("5.2b error is AUTH", "AUTH" in (r.stdout + r.stderr))
    stop_server()

    # 5.3 PostgreSQL
    print("  --- 5.3 PostgreSQL ---")
    clean_test_dir()
    clean_db()
    srv = init_server()
    enable_db_mode()
    store_log = Path(os.environ["XFTP_SERVER_LOG_PATH"]) / "file-server-store.log"
    store_log.unlink(missing_ok=True)
    create_schema()
    ok = start_server("--confirm-migrations", "up")
    check("5.3a PG server started", ok)
    if not ok:
        return

    src = make_file("persist.bin")
    send_file(src)
    stop_server()
    ok = start_server("--confirm-migrations", "up")
    check("5.3b PG server restarted", ok)
    if not ok:
        return

    recv_file(desc_dir("persist.bin") / "rcv1.xftp")
    check("5.3 recv after restart (PostgreSQL)", files_match(src, test_dir / "received/persist.bin"))
    stop_server()


def test_6_edge_cases():
    global srv
    print("\n=== 6. Edge cases ===")

    # 6.1 Receive after server-side delete
    print("  --- 6.1 receive after delete ---")
    clean_test_dir()
    srv = init_server()
    assert start_server()

    src = make_file("deltest.bin")
    send_file(src, n=2)
    del_file(desc_dir("deltest.bin") / "snd.xftp.private")
    r = recv_file(desc_dir("deltest.bin") / "rcv2.xftp")
    check("6.1a recv after server delete fails", r.returncode != 0)
    check("6.1b error is AUTH", "AUTH" in (r.stdout + r.stderr))
    stop_server()

    # 6.2 Multiple recipients, partial ack
    print("  --- 6.2 multiple recipients ---")
    clean_test_dir()
    srv = init_server()
    assert start_server()

    src = make_file("multi.bin")
    send_file(src, n=3)

    recv_file(desc_dir("multi.bin") / "rcv1.xftp")
    check("6.2a rcv1 received", files_match(src, test_dir / "received/multi.bin"))

    (test_dir / "received/multi.bin").unlink(missing_ok=True)
    recv_file(desc_dir("multi.bin") / "rcv2.xftp")
    check("6.2b rcv2 still works", files_match(src, test_dir / "received/multi.bin"))

    (test_dir / "received/multi.bin").unlink(missing_ok=True)
    recv_file(desc_dir("multi.bin") / "rcv3.xftp")
    check("6.2c rcv3 still works", files_match(src, test_dir / "received/multi.bin"))
    stop_server()

    # 6.3 Database mode with existing store log should fail
    # Simulates: ran server in memory mode (creating store log), then switched to database
    print("  --- 6.3 database mode + existing store log ---")
    clean_test_dir()
    clean_db()
    srv = init_server()
    # Start in memory mode to create the store log file
    assert start_server()
    make_file("dummy63.bin")
    send_file(test_dir / "dummy63.bin")
    stop_server()
    # Verify store log was created
    store_log = Path(os.environ["XFTP_SERVER_LOG_PATH"]) / "file-server-store.log"
    assert store_log.exists(), "store log should exist after memory-mode run"
    # Switch to database mode without importing
    enable_db_mode()
    create_schema()
    log_file = test_dir / "server-63.log"
    with open(log_file, "w") as fh:
        p = subprocess.Popen(
            [XFTP_SERVER, "start", "--confirm-migrations", "up"],
            stdout=fh, stderr=subprocess.STDOUT,
        )
        time.sleep(5)
        exited = p.poll() is not None
        if not exited:
            p.kill()
            p.wait()
    log_text = log_file.read_text()
    check("6.3a server exited", exited)
    check("6.3b error message correct",
          "store log file" in log_text and "exists but store_files is" in log_text)

    # 6.4 Database mode, no store log, schema doesn't exist (should fail)
    print("  --- 6.4 database mode + no schema ---")
    clean_test_dir()
    clean_db()
    srv = init_server()
    enable_db_mode()
    # No schema, no store log — server should fail with "schema does not exist"
    store_log = Path(os.environ["XFTP_SERVER_LOG_PATH"]) / "file-server-store.log"
    store_log.unlink(missing_ok=True)
    ok = start_server("--confirm-migrations", "up")
    check("6.4a start fails without schema", not ok)
    log_text = (test_dir / "server.log").read_text() if (test_dir / "server.log").exists() else ""
    check("6.4b error mentions schema", "schema" in log_text and "does not exist" in log_text)
    stop_server()

    # 6.5 Dual-write mode: database + db_store_log: on
    # Verifies that new writes in dual-write mode land in BOTH the DB and the store log,
    # so switching to memory-only (using the store log) preserves files sent in dual-write.
    print("  --- 6.5 database + store log + db_store_log: on ---")
    clean_test_dir()
    clean_db()
    srv = init_server()
    enable_db_mode()
    ini_uncomment("db_store_log")
    ini_set("db_store_log", "on")
    create_schema()
    # Remove store log so import isn't needed for initial start
    store_log = Path(os.environ["XFTP_SERVER_LOG_PATH"]) / "file-server-store.log"
    store_log.unlink(missing_ok=True)
    ok = start_server("--confirm-migrations", "up")
    check("6.5a start in dual-write mode", ok)
    if not ok:
        stop_server()
    else:
        # Send a NEW file in dual-write mode
        src = make_file("dual.bin")
        send_file(src, n=1)
        dd = desc_dir("dual.bin")
        check("6.5b send in dual-write mode", (dd / "rcv1.xftp").exists())

        stop_server()

        # Verify store log was written (dual-write)
        check("6.5c store log has entries",
              store_log.exists() and store_log.stat().st_size > 0)

        # Verify DB has the file too
        fc = db_count("files")
        check(f"6.5d file in DB ({fc})", fc > 0 and fc != -1)

        # Now switch to memory-only using the store log — proves the log has valid data
        disable_db_mode()
        ini_comment("db_store_log")
        ok = start_server()
        check("6.5e memory server from dual-write log", ok)
        if ok:
            recv_file(dd / "rcv1.xftp")
            check("6.5f recv on memory from dual-write log",
                  files_match(src, test_dir / "received/dual.bin"))
        stop_server()

    # 6.6 Import to non-empty database should fail
    # Use db_export to produce a real store log, then try to re-import without clearing DB.
    print("  --- 6.6 import to non-empty DB ---")
    clean_test_dir()
    clean_db()
    srv = init_server()
    enable_db_mode()
    store_log = Path(os.environ["XFTP_SERVER_LOG_PATH"]) / "file-server-store.log"
    store_log.unlink(missing_ok=True)
    create_schema()
    ok = start_server("--confirm-migrations", "up")
    if ok:
        make_file("dummy.bin")
        send_file(test_dir / "dummy.bin")
        stop_server()
        # Export produces a real, valid store log
        r = db_export()
        check("6.6a export for re-import test", r.returncode == 0)
        # Now try to import the valid log back into the non-empty DB
        r = db_import()
        check("6.6b import to non-empty DB fails", r.returncode != 0)
    else:
        fail_("6.6 could not start server for setup")

    # 6.7 Import with no store log file (should fail)
    print("  --- 6.7 import without store log ---")
    clean_test_dir()
    clean_db()
    srv = init_server()
    enable_db_mode()
    store_log = Path(os.environ["XFTP_SERVER_LOG_PATH"]) / "file-server-store.log"
    store_log.unlink(missing_ok=True)
    r = db_import()
    check("6.7 import without store log fails", r.returncode != 0)

    # 6.8 Export when store log already exists (should fail)
    print("  --- 6.8 export with existing store log ---")
    clean_test_dir()
    clean_db()
    srv = init_server()
    enable_db_mode()
    create_schema()
    store_log = Path(os.environ["XFTP_SERVER_LOG_PATH"]) / "file-server-store.log"
    store_log.unlink(missing_ok=True)
    ok = start_server("--confirm-migrations", "up")
    if ok:
        make_file("exp.bin")
        send_file(test_dir / "exp.bin")
        stop_server()
        # Create a log file to block export
        store_log.write_text("existing\n")
        r = db_export()
        check("6.8 export with existing store log fails", r.returncode != 0)
    else:
        fail_("6.8 could not start server for setup")


def test_7_blocking():
    """Block files via control port, verify blocked state survives migration."""
    global srv
    print("\n=== 7. File blocking via control port ===")

    # 7.1 Block a file and verify receive fails with BLOCKED
    print("  --- 7.1 block file, receive fails ---")
    clean_test_dir()
    srv = init_server()
    enable_control_port()
    assert start_server()

    src = make_file("blockme.bin")
    send_file(src, n=2)
    dd = desc_dir("blockme.bin")

    # Get recipient IDs from the file description
    rcv_ids = get_recipient_ids(dd / "rcv1.xftp")
    check("7.1a got recipient IDs", len(rcv_ids) > 0)

    # Block using the first chunk's recipient ID
    resp = control_cmd(f"block {rcv_ids[0]} reason=spam")
    check("7.1b block command OK", resp == "ok")

    # Receive should fail with BLOCKED
    r = recv_file(dd / "rcv1.xftp")
    output = r.stdout + r.stderr
    check("7.1c receive blocked file fails", r.returncode != 0)
    check("7.1d error is BLOCKED (not AUTH)", "BLOCKED" in output and "AUTH" not in output)

    stop_server()

    # 7.2 Blocked file survives migration memory -> PG
    print("  --- 7.2 blocked file survives memory->PG migration ---")
    clean_test_dir()
    clean_db()
    srv = init_server()
    enable_control_port()
    assert start_server()

    src = make_file("blockmigrate.bin")
    send_file(src, n=2)
    dd = desc_dir("blockmigrate.bin")

    rcv_ids = get_recipient_ids(dd / "rcv1.xftp")
    resp = control_cmd(f"block {rcv_ids[0]} reason=content")
    check("7.2a block before migration", resp == "ok")

    stop_server()

    # Import to PG
    enable_db_mode()
    r = db_import()
    check("7.2b import succeeded", r.returncode == 0)

    ok = start_server("--confirm-migrations", "up")
    check("7.2c PG server started", ok)
    if ok:
        r = recv_file(dd / "rcv1.xftp")
        check("7.2d recv fails after migration", r.returncode != 0)
        check("7.2e error is BLOCKED", "BLOCKED" in (r.stdout + r.stderr))
    stop_server()

    # 7.3 Blocked file survives migration PG -> memory
    print("  --- 7.3 blocked file survives PG->memory export ---")
    clean_test_dir()
    clean_db()
    srv = init_server()
    enable_control_port()
    enable_db_mode()
    store_log = Path(os.environ["XFTP_SERVER_LOG_PATH"]) / "file-server-store.log"
    store_log.unlink(missing_ok=True)
    create_schema()
    ok = start_server("--confirm-migrations", "up")
    check("7.3a PG server started", ok)
    if not ok:
        return

    src = make_file("blockpg.bin")
    send_file(src, n=2)
    dd = desc_dir("blockpg.bin")

    rcv_ids = get_recipient_ids(dd / "rcv1.xftp")
    resp = control_cmd(f"block {rcv_ids[0]} reason=spam")
    check("7.3b block on PG", resp == "ok")

    stop_server()

    # Export to memory
    r = db_export()
    check("7.3c export succeeded", r.returncode == 0)

    disable_db_mode()
    ok = start_server()
    check("7.3d memory server started", ok)
    if ok:
        r = recv_file(dd / "rcv1.xftp")
        check("7.3e recv fails after PG->memory", r.returncode != 0)
        check("7.3f error is BLOCKED", "BLOCKED" in (r.stdout + r.stderr))
    stop_server()


def test_8_migration_edge_cases():
    """Edge cases in migration: acked recipients, deleted files, large files, double round-trip."""
    global srv
    print("\n=== 8. Migration edge cases ===")

    # 8.1 Acked recipient fails after memory->PG migration
    print("  --- 8.1 acked recipient fails after memory->PG ---")
    clean_test_dir()
    clean_db()
    srv = init_server()
    assert start_server()

    src = make_file("acktest.bin")
    send_file(src, n=2)
    dd = desc_dir("acktest.bin")

    # Copy rcv1 descriptor before recv (recv -y deletes it)
    rcv1_backup = test_dir / "rcv1_acktest.xftp"
    shutil.copy2(dd / "rcv1.xftp", rcv1_backup)

    # Receive rcv1 (acknowledges it on server, deletes descriptor)
    recv_file(dd / "rcv1.xftp")
    check("8.1a rcv1 received", files_match(src, test_dir / "received/acktest.bin"))

    stop_server()

    # Migrate to PG
    enable_db_mode()
    r = db_import()
    check("8.1b import succeeded", r.returncode == 0)

    ok = start_server("--confirm-migrations", "up")
    check("8.1c PG server started", ok)
    if ok:
        # Acked rcv1 should fail — recipient was removed by ack before migration
        r = recv_file(rcv1_backup)
        check("8.1d acked rcv1 fails after migration", r.returncode != 0)
        check("8.1e error is AUTH", "AUTH" in (r.stdout + r.stderr))

        # Unacked rcv2 should still work
        (test_dir / "received/acktest.bin").unlink(missing_ok=True)
        recv_file(dd / "rcv2.xftp")
        check("8.1f rcv2 works after migration", files_match(src, test_dir / "received/acktest.bin"))
    stop_server()

    # 8.2 Acked recipient fails after PG->memory export
    print("  --- 8.2 acked recipient fails after PG->memory ---")
    clean_test_dir()
    clean_db()
    srv = init_server()
    enable_db_mode()
    store_log = Path(os.environ["XFTP_SERVER_LOG_PATH"]) / "file-server-store.log"
    store_log.unlink(missing_ok=True)
    create_schema()
    ok = start_server("--confirm-migrations", "up")
    check("8.2a PG server started", ok)
    if not ok:
        return

    src = make_file("ackpg.bin")
    send_file(src, n=2)
    dd = desc_dir("ackpg.bin")

    # Copy rcv1 descriptor before recv
    rcv1_backup = test_dir / "rcv1_ackpg.xftp"
    shutil.copy2(dd / "rcv1.xftp", rcv1_backup)

    recv_file(dd / "rcv1.xftp")
    check("8.2b rcv1 received on PG", files_match(src, test_dir / "received/ackpg.bin"))

    stop_server()

    r = db_export()
    check("8.2c export succeeded", r.returncode == 0)

    disable_db_mode()
    ok = start_server()
    check("8.2d memory server started", ok)
    if ok:
        # Acked rcv1 should fail
        r = recv_file(rcv1_backup)
        check("8.2e acked rcv1 fails after export", r.returncode != 0)
        check("8.2f error is AUTH", "AUTH" in (r.stdout + r.stderr))

        # Unacked rcv2 should work
        (test_dir / "received/ackpg.bin").unlink(missing_ok=True)
        recv_file(dd / "rcv2.xftp")
        check("8.2g rcv2 works on memory after export", files_match(src, test_dir / "received/ackpg.bin"))
    stop_server()

    # 8.3 Deleted file absent after migration
    print("  --- 8.3 deleted file absent after migration ---")
    clean_test_dir()
    clean_db()
    srv = init_server()
    assert start_server()

    # Send a file that will be deleted before migration.
    # Use n=2 so we have a rcv descriptor to test post-migration (rcv1 will be
    # acked by the recv below; backup rcv2 before delete so we can try to recv
    # it after migration — should return AUTH because the file was deleted).
    srcDel = make_file("delmigrate.bin")
    send_file(srcDel, n=2)
    ddDel = desc_dir("delmigrate.bin")
    # Backup rcv2 descriptor BEFORE delete (del doesn't touch rcv descriptors)
    rcv2_del_backup = test_dir / "rcv2_delmigrate.xftp"
    shutil.copy2(ddDel / "rcv2.xftp", rcv2_del_backup)
    recv_file(ddDel / "rcv1.xftp")
    del_file(ddDel / "snd.xftp.private")

    # Send a positive control file that will NOT be deleted
    srcKeep = make_file("keepmigrate.bin")
    send_file(srcKeep, n=1)
    check("8.3a keep file sent", (desc_dir("keepmigrate.bin") / "rcv1.xftp").exists())

    stop_server()

    enable_db_mode()
    r = db_import()
    check("8.3b import succeeded", r.returncode == 0)

    # The kept file must be imported — proves import actually ran.
    fc = db_count("files")
    check(f"8.3c files imported ({fc})", fc > 0 and fc != -1)

    ok = start_server("--confirm-migrations", "up")
    check("8.3d PG server started", ok)
    if ok:
        # Positive control: kept file is receivable after migration
        recv_file(desc_dir("keepmigrate.bin") / "rcv1.xftp")
        check("8.3e kept file receivable after migration",
              files_match(srcKeep, test_dir / "received/keepmigrate.bin"))

        # Negative control: deleted file's rcv2 must return AUTH after migration
        r = recv_file(rcv2_del_backup)
        check("8.3f deleted file rcv2 fails after migration", r.returncode != 0)
        check("8.3g error is AUTH (deleted file absent)",
              "AUTH" in (r.stdout + r.stderr))
    stop_server()

    # 8.4 Large multi-chunk file integrity after migration
    print("  --- 8.4 large file (multi-chunk) migration ---")
    clean_test_dir()
    clean_db()
    srv = init_server()
    assert start_server()

    src = make_file("largefile.bin", size_mb=20)
    send_file(src, n=1)
    dd = desc_dir("largefile.bin")
    check("8.4a large file sent", (dd / "rcv1.xftp").exists())

    stop_server()

    enable_db_mode()
    r = db_import()
    check("8.4b import succeeded", r.returncode == 0)

    ok = start_server("--confirm-migrations", "up")
    check("8.4c PG server started", ok)
    if ok:
        recv_file(dd / "rcv1.xftp")
        check("8.4d large file integrity after migration",
              files_match(src, test_dir / "received/largefile.bin"))
    stop_server()

    # 8.5 Double round-trip: memory -> PG -> memory, then receive
    print("  --- 8.5 double round-trip migration ---")
    clean_test_dir()
    clean_db()
    srv = init_server()
    assert start_server()

    src = make_file("roundtrip.bin")
    send_file(src, n=1)
    dd = desc_dir("roundtrip.bin")

    stop_server()

    # memory -> PG
    enable_db_mode()
    r = db_import()
    check("8.5a first import (memory->PG)", r.returncode == 0)

    ok = start_server("--confirm-migrations", "up")
    check("8.5b PG server started", ok)
    stop_server()

    # PG -> memory
    r = db_export()
    check("8.5c first export (PG->memory)", r.returncode == 0)

    disable_db_mode()
    ok = start_server()
    check("8.5d memory server started (round 1)", ok)
    stop_server()

    # memory -> PG again
    clean_db()
    enable_db_mode()
    r = db_import()
    check("8.5e second import (memory->PG)", r.returncode == 0)

    ok = start_server("--confirm-migrations", "up")
    check("8.5f PG server started (round 2)", ok)
    if ok:
        recv_file(dd / "rcv1.xftp")
        check("8.5g file intact after double round-trip",
              files_match(src, test_dir / "received/roundtrip.bin"))
    stop_server()


def test_9_auth_and_access_control():
    """Basic auth, allowNewFiles, storage quota, file expiration."""
    global srv
    print("\n=== 9. Auth and access control ===")

    # 9.1 AllowNewFiles=false rejects upload
    print("  --- 9.1 allowNewFiles=false ---")
    clean_test_dir()
    srv = init_server()
    ini_set("new_files", "off")
    assert start_server()

    src = make_file("reject.bin")
    r = send_file(src)
    check("9.1 upload rejected when new_files=off", r.returncode != 0)
    stop_server()

    # 9.2 Basic auth: no password → fails
    print("  --- 9.2 basic auth: no password ---")
    clean_test_dir()
    srv = init_server()
    ini_set("new_files", "on")
    # Uncomment and set create_password
    ini = ini_path()
    txt = ini.read_text()
    txt, n = re.subn(r"^# create_password:.*$", "create_password: secret123", txt, flags=re.MULTILINE)
    assert n > 0, "create_password commented line not found in INI"
    ini.write_text(txt)
    assert start_server()

    src = make_file("authtest.bin")
    r = send_file(src)
    check("9.2a upload without password fails", r.returncode != 0)
    check("9.2b error is AUTH", "AUTH" in (r.stdout + r.stderr))
    stop_server()

    # 9.3 Basic auth: wrong password → fails
    print("  --- 9.3 basic auth: wrong password ---")
    # Reinit with password in server address
    clean_test_dir()
    srv = init_server()
    ini_set("new_files", "on")
    ini = ini_path()
    txt = ini.read_text()
    txt, n = re.subn(r"^# create_password:.*$", "create_password: secret123", txt, flags=re.MULTILINE)
    assert n > 0, "create_password commented line not found in INI"
    ini.write_text(txt)
    fp = (Path(os.environ["XFTP_SERVER_CFG_PATH"]) / "fingerprint").read_text().strip()
    wrong_srv = f"xftp://{fp}:wrongpass@127.0.0.1:{PORT}"
    assert start_server()

    src = make_file("authtest.bin")
    r = run([XFTP, "send", str(src), str(test_dir / "descriptions"),
             "-s", wrong_srv, "-n", "1"], check=False, timeout=30)
    output = r.stdout + r.stderr
    check("9.3a wrong password prints AUTH error", "PCEProtocolError AUTH" in output)
    check("9.3b no descriptor created", not (desc_dir("authtest.bin") / "rcv1.xftp").exists())
    stop_server()

    # 9.4 Basic auth: correct password → succeeds
    print("  --- 9.4 basic auth: correct password ---")
    clean_test_dir()
    srv = init_server()
    ini_set("new_files", "on")
    ini = ini_path()
    txt = ini.read_text()
    txt, n = re.subn(r"^# create_password:.*$", "create_password: secret123", txt, flags=re.MULTILINE)
    assert n > 0, "create_password commented line not found in INI"
    ini.write_text(txt)
    fp = (Path(os.environ["XFTP_SERVER_CFG_PATH"]) / "fingerprint").read_text().strip()
    correct_srv = f"xftp://{fp}:secret123@127.0.0.1:{PORT}"
    assert start_server()

    src = make_file("authok.bin")
    r = run([XFTP, "send", str(src), str(test_dir / "descriptions"),
             "-s", correct_srv, "-n", "1"], check=False, timeout=60)
    check("9.4 upload with correct password succeeds", r.returncode == 0)
    stop_server()

    # 9.5 Server no auth, client sends auth → succeeds
    print("  --- 9.5 no server auth, client sends auth ---")
    clean_test_dir()
    srv = init_server()
    fp = (Path(os.environ["XFTP_SERVER_CFG_PATH"]) / "fingerprint").read_text().strip()
    auth_srv = f"xftp://{fp}:anypass@127.0.0.1:{PORT}"
    assert start_server()

    src = make_file("noauth.bin")
    r = run([XFTP, "send", str(src), str(test_dir / "descriptions"),
             "-s", auth_srv, "-n", "1"], check=False, timeout=60)
    check("9.5 upload with auth to no-auth server succeeds", r.returncode == 0)
    stop_server()

    # 9.6 Storage quota: exact boundary
    print("  --- 9.6 storage quota boundary ---")
    clean_test_dir()
    # Chunk size is 128KB, so 1MB file = ~8 chunks but stored as one padded chunk per server file
    # Use small quota: allow exactly 2 files of 1MB
    srv = init_server(quota="3mb")
    assert start_server()

    src1 = make_file("quota1.bin")
    r1 = send_file(src1)
    check("9.6a first file within quota", r1.returncode == 0)

    src2 = make_file("quota2.bin")
    r2 = send_file(src2)
    check("9.6b second file within quota", r2.returncode == 0)

    src3 = make_file("quota3.bin")
    r3 = send_file(src3)
    check("9.6c third file rejected", r3.returncode != 0)
    check("9.6d error is QUOTA", "QUOTA" in (r3.stdout + r3.stderr))
    stop_server()

    # 9.7 File expiration
    # Note: createdAt uses hour-level precision (fileTimePrecision = 3600s).
    # With expire_files_hours=0, TTL=0, and the check is createdAt + TTL < now.
    # Files created in the current hour have createdAt = now (rounded), so
    # createdAt + 0 is NOT < now — they won't expire until the next hour.
    # The check interval is hardcoded at 2 hours and not configurable via INI.
    # This makes expiration untestable in a fast automated test.
    # File expiration IS tested in the Haskell test suite (testFileChunkExpiration)
    # with a 1-second TTL and 1-second check interval configured programmatically.
    print("  --- 9.7 file expiration (skipped: requires hour boundary, tested in Haskell suite) ---")


def test_10_control_port_operations():
    """Control port: delete, auth failure, invalid commands, stats."""
    global srv
    print("\n=== 10. Control port operations ===")

    clean_test_dir()
    srv = init_server()
    enable_control_port()
    assert start_server()

    # 10.1 Control port: command without authentication
    # Server should respond with "AUTH" when no auth has been provided
    print("  --- 10.1 no auth ---")
    src = make_file("ctrldel.bin")
    send_file(src, n=1)
    dd = desc_dir("ctrldel.bin")
    rcv_ids = get_recipient_ids(dd / "rcv1.xftp")
    resp = control_cmd(f"delete {rcv_ids[0]}", auth=False)
    check("10.1 command without auth returns AUTH", resp == "AUTH")

    # 10.2 Control port: wrong password assigns CPRNone, commands return AUTH
    print("  --- 10.2 wrong password ---")
    s = control_connect()
    auth_resp = control_send_recv(s, "auth wrongpassword")
    check("10.2a wrong password gives CPRNone", auth_resp == "Current role is CPRNone")
    cmd_resp = control_send_recv(s, f"delete {rcv_ids[0]}")
    check("10.2b CPRNone command returns AUTH", cmd_resp == "AUTH")
    s.sendall(b"quit\n")
    s.close()

    # 10.3 Control port: stats-rts
    # Without +RTS -T, returns "unsupported operation (GHC.Stats.getRTSStats: ...)"
    # With +RTS -T, returns actual GHC runtime stats with "gcs" field etc.
    # Either is a valid non-error response.
    print("  --- 10.3 stats-rts ---")
    resp = control_cmd("stats-rts")
    check("10.3 stats-rts responds",
          "getRTSStats" in resp or "gcs" in resp or "allocated_bytes" in resp)

    # 10.4 Control port: delete command removes file
    print("  --- 10.4 control port delete ---")
    resp = control_cmd(f"delete {rcv_ids[0]}")
    check("10.4a delete command returns ok", resp == "ok")

    r = recv_file(dd / "rcv1.xftp")
    check("10.4b recv after control port delete fails", r.returncode != 0)
    check("10.4c error is AUTH", "AUTH" in (r.stdout + r.stderr))

    # 10.5 Control port: invalid block reason
    print("  --- 10.5 invalid block reason ---")
    src2 = make_file("badblock.bin")
    send_file(src2, n=1)
    dd2 = desc_dir("badblock.bin")
    rcv_ids2 = get_recipient_ids(dd2 / "rcv1.xftp")

    resp = control_cmd(f"block {rcv_ids2[0]} reason=invalid_reason")
    check("10.5 invalid block reason returns error", resp.startswith("error:"))

    stop_server()


def test_11_blocked_file_sender_delete():
    """Blocked file: sender cannot delete it."""
    global srv
    print("\n=== 11. Blocked file: sender delete attempt ===")

    clean_test_dir()
    srv = init_server()
    enable_control_port()
    assert start_server()

    src = make_file("blockdel.bin")
    send_file(src, n=1)
    dd = desc_dir("blockdel.bin")

    rcv_ids = get_recipient_ids(dd / "rcv1.xftp")
    resp = control_cmd(f"block {rcv_ids[0]} reason=spam")
    check("11.1 block succeeded", resp == "ok")

    # Sender tries to delete — should fail with BLOCKED
    r = del_file(dd / "snd.xftp.private")
    check("11.2 sender delete of blocked file fails", r.returncode != 0)
    check("11.3 error mentions BLOCKED",
          "BLOCKED" in (r.stdout + r.stderr))

    stop_server()


def test_12_recipient_cascade_and_storage():
    """Recipient cascade delete and storage accounting."""
    global srv
    print("\n=== 12. Recipient cascade and storage accounting ===")

    # 12.1 Recipient cascade: delete file, all recipients gone
    print("  --- 12.1 recipient cascade delete (PG) ---")
    clean_test_dir()
    clean_db()
    srv = init_server()
    enable_db_mode()
    store_log = Path(os.environ["XFTP_SERVER_LOG_PATH"]) / "file-server-store.log"
    store_log.unlink(missing_ok=True)
    create_schema()
    ok = start_server("--confirm-migrations", "up")
    check("12.1a PG server started", ok)
    if not ok:
        return

    src = make_file("cascade.bin")
    send_file(src, n=3)

    fc_before = db_count("files")
    rc_before = db_count("recipients")
    check(f"12.1b files before delete ({fc_before})", fc_before > 0)
    check(f"12.1c recipients before delete ({rc_before})", rc_before > 0)

    del_file(desc_dir("cascade.bin") / "snd.xftp.private")

    fc_after = db_count("files")
    rc_after = db_count("recipients")
    check(f"12.1d files after delete ({fc_after})", fc_after == 0)
    check(f"12.1e recipients cascade deleted ({rc_after})", rc_after == 0)

    # 12.2 Storage accounting: upload, delete, verify disk
    print("  --- 12.2 storage accounting ---")
    src1 = make_file("stor1.bin")
    r1 = send_file(src1)
    check("12.2a stor1 upload succeeded", r1.returncode == 0)
    src2 = make_file("stor2.bin")
    r2 = send_file(src2)
    check("12.2b stor2 upload succeeded", r2.returncode == 0)

    files_on_disk = len(list((test_dir / "files").iterdir()))
    check(f"12.2c files on disk after upload ({files_on_disk})", files_on_disk > 0)

    del_file(desc_dir("stor1.bin") / "snd.xftp.private")
    del_file(desc_dir("stor2.bin") / "snd.xftp.private")

    files_on_disk = len(list((test_dir / "files").iterdir()))
    check(f"12.2d files on disk after delete ({files_on_disk})", files_on_disk == 0)

    fc = db_count("files")
    check(f"12.2e DB files after delete ({fc})", fc == 0)

    stop_server()


# ===================================================================
# Main
# ===================================================================

if __name__ == "__main__":
    XFTP_SERVER = cabal_bin("xftp-server")
    XFTP = cabal_bin("xftp")
    test_dir = Path.cwd() / "xftp-test"

    os.environ["XFTP_SERVER_CFG_PATH"] = str(test_dir / "etc")
    os.environ["XFTP_SERVER_LOG_PATH"] = str(test_dir / "var")

    srv = ""

    print(f"XFTP server: {XFTP_SERVER}")
    print(f"XFTP client: {XFTP}")
    print(f"Test dir:    {test_dir}")
    print(f"PGHOST:      {os.environ.get('PGHOST', '(default)')}")

    # Verify prerequisites
    r = psql("SELECT 1;", check=False)
    if r.returncode != 0:
        sys.exit(f"Cannot connect to PostgreSQL as {PG_ADMIN_USER}. Is it running?")
    r = psql("SELECT 1;", user=DB_USER, db="postgres", check=False)
    if r.returncode != 0:
        sys.exit(f"PostgreSQL user '{DB_USER}' does not exist.\n"
                 f"Run: psql -U {PG_ADMIN_USER} -c \"CREATE USER {DB_USER} WITH SUPERUSER;\"")

    try:
        test_1_basic_memory()
        test_2_basic_postgres()
        test_3_migration_memory_to_pg()
        test_4_migration_pg_to_memory()  # continues from test_3 state
        test_4b_send_pg_receive_memory()
        test_5_restart_persistence()
        test_6_edge_cases()
        test_7_blocking()
        test_8_migration_edge_cases()
        test_9_auth_and_access_control()
        test_10_control_port_operations()
        test_11_blocked_file_sender_delete()
        test_12_recipient_cascade_and_storage()
    except Exception:
        stop_server()
        print("\n  [ERROR] Unexpected exception:")
        traceback.print_exc()
        FAIL += 1
    finally:
        stop_server()
        # Cleanup
        if test_dir.exists():
            shutil.rmtree(test_dir)
        psql(f"DROP DATABASE IF EXISTS {DB_NAME};", check=False)

    print(f"\n{'=' * 42}")
    print(f"Results: {PASS} passed, {FAIL} failed")
    print(f"{'=' * 42}")
    sys.exit(1 if FAIL > 0 else 0)
