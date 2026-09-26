import contextlib
import http.client
import io
import ipaddress
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from snrc_resolve import config, server
from fakes import FakeChain, FakeNode


@unittest.skipUnless(sys.platform.startswith("linux"), "Linux drops SYNs on a full accept queue")
class ListenBacklogTests(unittest.TestCase):
    """The smp-server opens a connection per lookup and gives up after 3 s, so a
    burst the accept queue cannot hold fails: TCP retries a dropped SYN after 1 s."""

    BURST = 50

    def test_a_burst_of_connections_is_queued_while_the_server_is_busy(self):
        # never accepts, so every connection must wait in the queue
        http_server = server.ResolverServer(("127.0.0.1", 0), server.Handler)
        clients = []
        try:
            for i in range(self.BURST):
                c = socket.socket()
                clients.append(c)
                c.settimeout(0.5)
                try:
                    c.connect(http_server.server_address)
                except TimeoutError:
                    self.fail(f"connection {i + 1} of {self.BURST} was not queued")
        finally:
            for c in clients:
                c.close()
            http_server.server_close()


class RequestLogTests(unittest.TestCase):
    """Each request is one event with the client it came from, behind a reverse
    proxy the client the proxy names rather than the proxy itself."""

    def setUp(self):
        self.http_server = server.ResolverServer(("127.0.0.1", 0), server.Handler)
        threading.Thread(target=self.http_server.serve_forever, args=(0.05,), daemon=True).start()
        self._saved = config.TRUSTED_PROXIES

    def tearDown(self):
        config.TRUSTED_PROXIES = self._saved
        self.http_server.shutdown()
        self.http_server.server_close()

    def request(self, path, headers=None, level="INFO"):
        url = f"http://127.0.0.1:{self.http_server.server_address[1]}{path}"
        with self.assertLogs("snrc_resolve", level) as logs:
            try:
                urlopen(Request(url, headers=headers or {}), timeout=5).read()
            except HTTPError:
                pass
            deadline = time.monotonic() + 2
            while not any(r.getMessage() == "request" for r in logs.records) and time.monotonic() < deadline:
                time.sleep(0.01)
        [record] = [r for r in logs.records if r.getMessage() == "request"]
        return record

    def test_a_request_is_logged_with_its_outcome(self):
        record = self.request("/v2/resolve/x.simplex")
        fields = record.fields
        self.assertEqual(record.levelname, "INFO")
        self.assertEqual(
            (fields["client"], fields["method"], fields["path"], fields["status"], fields["worker"]),
            ("127.0.0.1", "GET", "/v2/resolve/x.simplex", 400, os.getpid()),
        )
        self.assertGreater(fields["bytes"], 0)
        self.assertGreaterEqual(fields["ms"], 0)

    def test_a_trusted_proxy_names_the_client(self):
        config.TRUSTED_PROXIES = (ipaddress.ip_network("127.0.0.1/32"),)
        record = self.request("/v2/resolve/x.simplex", {"X-Forwarded-For": "203.0.113.7"})
        self.assertEqual(record.fields["client"], "203.0.113.7")

    def test_any_other_peer_cannot_name_itself(self):
        record = self.request("/v2/resolve/x.simplex", {"X-Forwarded-For": "203.0.113.7"})
        self.assertEqual(record.fields["client"], "127.0.0.1")

    def test_health_checks_are_logged_only_at_debug(self):
        """The container checks /health every 30 s."""
        record = self.request("/health", level="DEBUG")
        self.assertEqual(record.levelname, "DEBUG")


class ClientAddressTests(unittest.TestCase):
    PROXY = "172.18.0.1"

    def setUp(self):
        self._saved = config.TRUSTED_PROXIES
        config.TRUSTED_PROXIES = (ipaddress.ip_network("172.16.0.0/12"),)

    def tearDown(self):
        config.TRUSTED_PROXIES = self._saved

    def test_a_peer_that_is_no_proxy_is_the_client(self):
        self.assertEqual(server.client_address("198.51.100.9", "203.0.113.7"), "198.51.100.9")

    def test_without_the_header_the_proxy_is_the_client(self):
        self.assertEqual(server.client_address(self.PROXY, None), self.PROXY)

    def test_the_address_the_proxy_added_is_the_client(self):
        self.assertEqual(server.client_address(self.PROXY, "203.0.113.7"), "203.0.113.7")

    def test_addresses_a_client_sent_itself_are_not_believed(self):
        """A proxy appends the address it saw, so only the last untrusted one is known."""
        self.assertEqual(server.client_address(self.PROXY, "6.6.6.6, 203.0.113.7"), "203.0.113.7")

    def test_trusted_proxies_in_a_chain_are_skipped(self):
        self.assertEqual(server.client_address(self.PROXY, "203.0.113.7, 172.18.0.5"), "203.0.113.7")

    def test_an_address_that_does_not_parse_is_not_believed(self):
        self.assertEqual(server.client_address(self.PROXY, "203.0.113.7, not-an-ip"), self.PROXY)

    def test_an_ipv4_mapped_peer_is_matched_as_ipv4(self):
        self.assertEqual(server.client_address("::ffff:172.18.0.1", "203.0.113.7"), "203.0.113.7")

    def test_an_ipv6_client_is_kept(self):
        self.assertEqual(server.client_address(self.PROXY, "2001:db8::7"), "2001:db8::7")


class RequestErrorTests(unittest.TestCase):
    def setUp(self):
        self.http_server = server.ResolverServer(("127.0.0.1", 0), server.Handler)

    def tearDown(self):
        self.http_server.server_close()

    def test_a_client_that_hung_up_is_a_warning_without_a_traceback(self):
        """What an smp-server that gave up after its timeout leaves behind."""
        with self.assertLogs("snrc_resolve", "WARNING") as logs:
            try:
                raise BrokenPipeError
            except BrokenPipeError:
                self.http_server.handle_error(None, ("198.51.100.9", 4000))
        [record] = logs.records
        self.assertEqual((record.levelname, record.getMessage(), record.fields["error"]), ("WARNING", "client_gone", "BrokenPipeError"))
        self.assertIsNone(record.exc_info)

    def test_a_failure_is_an_error_with_its_traceback(self):
        with self.assertLogs("snrc_resolve", "ERROR") as logs:
            try:
                raise KeyError("boom")
            except KeyError:
                self.http_server.handle_error(None, ("198.51.100.9", 4000))
        [record] = logs.records
        self.assertEqual((record.getMessage(), record.fields["client"]), ("request_failed", "198.51.100.9"))
        self.assertIsNotNone(record.exc_info)


class KeepAliveTests(unittest.TestCase):
    """The smp-server keeps a resolver connection only after an HTTP/1.1
    response, and otherwise connects for every lookup."""

    def setUp(self):
        self.http_server = server.ResolverServer(("127.0.0.1", 0), server.Handler)
        threading.Thread(target=self.http_server.serve_forever, args=(0.05,), daemon=True).start()
        self._saved_timeout = server.Handler.timeout
        self._log = contextlib.redirect_stderr(io.StringIO())
        self._log.__enter__()

    def tearDown(self):
        self._log.__exit__(None, None, None)
        server.Handler.timeout = self._saved_timeout
        self.http_server.shutdown()
        self.http_server.server_close()

    def test_requests_share_one_connection_without_delay(self):
        conn = http.client.HTTPConnection(*self.http_server.server_address, timeout=5)
        start = time.monotonic()
        for i in range(20):
            conn.request("GET", "/v2/resolve/x.simplex")
            res = conn.getresponse()
            res.read()
            self.assertEqual((res.version, res.status), (11, 400))
            if i == 0:
                sock = conn.sock
            self.assertIs(conn.sock, sock)
        conn.close()
        # a response held by Nagle for the delayed ACK takes ~40 ms, 20 of them over 0.8 s
        self.assertLess(time.monotonic() - start, 0.5)

    def test_idle_connections_outlast_the_smp_servers(self):
        """http-client drops a connection idle for 30 s, checked every 5 s. A
        resolver that closed sooner would race the client reusing it, and one
        that never closed would keep a thread per dead connection."""
        self.assertIsNotNone(self._saved_timeout)
        self.assertGreater(self._saved_timeout, 35)

    def test_an_idle_connection_is_closed(self):
        server.Handler.timeout = 0.2
        with socket.create_connection(self.http_server.server_address, timeout=5) as sock:
            time.sleep(0.5)
            self.assertEqual(sock.recv(1), b"")


@unittest.skipUnless(sys.platform.startswith("linux"), "reads worker processes from /proc")
class WorkerProcessesTests(unittest.TestCase):
    """Workers share the port, and the service stops as a whole, so the
    container restarts rather than serving on fewer workers."""

    def setUp(self):
        self.node = FakeNode()
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.port = s.getsockname()[1]
        env = dict(os.environ, SNRC_RPC=self.node.url, SNRC_BIND="127.0.0.1", SNRC_PORT=str(self.port), SNRC_WORKERS="2",
                   SNRC_REGISTRY_TESTING=FakeChain.REGISTRY, SNRC_REGISTRAR_TESTING=FakeChain.REGISTRAR, SNRC_CONTROLLER_TESTING=FakeChain.CONTROLLER)
        self.service = subprocess.Popen([sys.executable, "-m", "snrc_resolve"], env=env, stderr=subprocess.PIPE, text=True)
        self.workers = self._wait_for_workers(2)

    def tearDown(self):
        if self.service.poll() is None:
            self.service.kill()
            self.service.wait()
        self.service.stderr.close()
        for pid in self.workers:
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, signal.SIGKILL)
        self.node.stop()

    def _wait_for_workers(self, count):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            workers = [int(p) for p in os.listdir("/proc") if p.isdigit() and self._parent(p) == self.service.pid]
            if len(workers) == count and self._serving():
                return workers
            time.sleep(0.05)
        self.fail("workers did not start")

    @staticmethod
    def _parent(pid):
        try:
            with open(f"/proc/{pid}/stat") as f:
                return int(f.read().rsplit(")", 1)[1].split()[1])
        except (FileNotFoundError, ProcessLookupError):
            return None

    def _serving(self):
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=1):
                return True
        except OSError:
            return False

    def _gone(self, pid):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self._parent(pid) != self.service.pid:
                return True
            time.sleep(0.05)
        return False

    def test_workers_answer_on_the_shared_port(self):
        for _ in range(20):
            with urlopen(f"http://127.0.0.1:{self.port}/v2/resolve/acme.testing", timeout=5) as res:
                self.assertEqual(json.loads(res.read())["registration"]["type"], "registered")

    def test_stopping_the_service_stops_every_worker(self):
        self.service.send_signal(signal.SIGTERM)
        self.assertEqual(self.service.wait(timeout=5), 0)
        self.assertTrue(all(self._gone(pid) for pid in self.workers))
        self.assertRegex(self.service.stderr.read(), r"INFO  stopping  signal=SIGTERM")

    def test_a_worker_exiting_stops_the_service(self):
        os.kill(self.workers[0], signal.SIGKILL)
        self.assertEqual(self.service.wait(timeout=5), 1)
        self.assertTrue(self._gone(self.workers[1]))
