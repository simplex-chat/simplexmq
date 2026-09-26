"""HTTP server, worker processes and the entry point."""

import json
import os
import signal
import socket
import sys
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

from . import config, rpc
from .answers import registration, resolve, upstream_error
from .registration_status import head_block


class Handler(BaseHTTPRequestHandler):
    # the smp-server reuses a connection only after an HTTP/1.1 response
    protocol_version = "HTTP/1.1"
    # idle seconds before a kept-alive connection is closed; the smp-server closes
    # its idle ones after 30-35 s, so it is the one to close them
    timeout = 60

    def setup(self):
        super().setup()
        # headers and body go out in separate writes, which Nagle holds for the client's delayed ACK
        self.request.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def do_GET(self):  # noqa: N802 - http.server contract
        self._started = time.monotonic()
        path = urlparse(self.path).path
        parts = [unquote(p) for p in path.split("/") if p]

        if parts == ["health"]:
            self._respond(200, {"ok": True, "rpc": config.RPC, "registries": config.REGISTRIES, **head_block()})
            return

        if len(parts) == 3 and parts[0] == "v2" and parts[1] == "resolve":
            name = parts[2].strip().lower()
            if not name or "." not in name:
                self._respond(400, {"name": name, "error": "notFullyQualified"})
                return
            try:
                with rpc.request_reads():
                    status, body = registration(name)
            except Exception as e:  # surface upstream errors as 502
                status, body = 502, upstream_error({"name": name}, e)
            self._respond(status, body)
            return

        # /v1/resolve is an alias: relays before SMP v22 call /resolve
        if parts[:2] == ["v1", "resolve"] and len(parts) == 3:
            parts = ["resolve", parts[2]]

        if len(parts) == 2 and parts[0] == "resolve":
            name = parts[1].strip().lower()
            if not name or "." not in name:
                self._respond(
                    400,
                    {
                        "name": name,
                        "error": "notFullyQualified",
                        "message": "expected a fully-qualified name, e.g. alice.testing",
                    },
                )
                return
            try:
                with rpc.request_reads():
                    status, body = resolve(name)
            except Exception as e:  # surface upstream errors as 502
                status, body = 502, upstream_error({"name": name}, e)
            self._respond(status, body)
            return

        self._respond(
            404,
            {
                "error": "noSuchRoute",
                "message": "not found",
                "routes": ["/health", "/v2/resolve/<query>", "/v1/resolve/<name>", "/resolve/<name>"],
            },
        )

    def _respond(self, status: int, body: dict):
        data = json.dumps(body, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_request(self, code="-", size="-"):
        started = getattr(self, "_started", None)
        took = f" {(time.monotonic() - started) * 1000:.0f}ms" if started else ""
        self.log_message('"%s" %s %s%s', self.requestline, getattr(code, "value", code), size, took)

    def log_message(self, fmt, *args):
        # Quiet the default per-request access log; route to stderr in one line.
        sys.stderr.write(f"{self.address_string()} - {fmt % args}\n")


class ResolverServer(ThreadingHTTPServer):
    # socketserver's default of 5 drops simultaneous connections, each retried by
    # TCP after 1 s, and the smp-server gives up after 3 s. The kernel caps it at somaxconn.
    request_queue_size = 128


def serve(reuse_port: bool):
    server = ResolverServer((config.BIND, config.PORT), Handler, bind_and_activate=False)
    server.allow_reuse_port = reuse_port
    try:
        server.server_bind()
        server.server_activate()
        server.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("\nshutting down\n")
    finally:
        server.server_close()


def supervise(workers: int):
    """Runs the workers, each with its own socket on the shared port. One worker
    exiting stops the others, so the container restarts instead of running short."""
    children = []

    def stop(*_):
        for pid in children:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    def stop_and_exit(*_):
        stop()
        sys.exit(0)

    # before forking, so a signal during startup cannot orphan the workers
    signal.signal(signal.SIGTERM, stop_and_exit)
    signal.signal(signal.SIGINT, stop_and_exit)
    for _ in range(workers):
        pid = os.fork()
        if pid == 0:
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            signal.signal(signal.SIGINT, signal.SIG_DFL)
            code = 0
            try:
                serve(reuse_port=True)
            except BaseException:
                traceback.print_exc()
                code = 1
            os._exit(code)
        children.append(pid)
    pid, status = os.wait()
    sys.stderr.write(f"worker {pid} exited with status {status}, stopping\n")
    stop()
    sys.exit(1)


def main():
    sys.stderr.write(
        f"snrc-resolve listening on {config.BIND}:{config.PORT} with {config.WORKERS} worker(s)\n"
        f"  RPC = {config.RPC}\n"
        f"  Registries:\n"
    )
    for tld, addr in config.REGISTRIES.items():
        sys.stderr.write(f"    .{tld:<8s} = {addr or '(not configured)'}\n")
    sys.stderr.write("  GET /v2/resolve/<name>   GET /v1/resolve/<name>   GET /health\n")
    if config.WORKERS > 1:
        supervise(config.WORKERS)
    else:
        serve(reuse_port=False)
