import contextlib
import http.client
import io
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
from urllib.request import urlopen

from snrc_resolve import server
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
    def test_each_request_is_logged_with_its_duration(self):
        http_server = server.ResolverServer(("127.0.0.1", 0), server.Handler)
        threading.Thread(target=http_server.serve_forever, args=(0.05,), daemon=True).start()
        try:
            with contextlib.redirect_stderr(io.StringIO()) as err:
                with self.assertRaises(HTTPError):
                    urlopen(f"http://127.0.0.1:{http_server.server_address[1]}/v2/resolve/x.simplex", timeout=5)
                time.sleep(0.1)
        finally:
            http_server.shutdown()
            http_server.server_close()
        self.assertRegex(err.getvalue(), r'"GET /v2/resolve/x\.simplex HTTP/1\.1" 400 - \d+ms')


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
        self.service = subprocess.Popen([sys.executable, "-m", "snrc_resolve"], env=env, stderr=subprocess.DEVNULL)
        self.workers = self._wait_for_workers(2)

    def tearDown(self):
        if self.service.poll() is None:
            self.service.kill()
            self.service.wait()
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

    def test_a_worker_exiting_stops_the_service(self):
        os.kill(self.workers[0], signal.SIGKILL)
        self.assertEqual(self.service.wait(timeout=5), 1)
        self.assertTrue(self._gone(self.workers[1]))
