"""HTTP server, worker processes and the entry point."""

import ipaddress
import json
import logging
import os
import signal
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

from . import config, log, rpc
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
        # send_response logs the request, so the size is known before it
        self._sent = len(data)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def address_string(self) -> str:
        headers = getattr(self, "headers", None)
        forwarded = headers.get_all("X-Forwarded-For") if headers else None
        return client_address(self.client_address[0], ",".join(forwarded) if forwarded else None)

    def log_request(self, code="-", size="-"):
        started = getattr(self, "_started", None)
        path = urlparse(self.path).path if getattr(self, "path", None) else None
        log.event(
            # the container's health check runs every 30 s
            logging.DEBUG if path == "/health" else logging.INFO,
            "request",
            client=self.address_string(),
            worker=os.getpid(),
            method=getattr(self, "command", None),
            path=unquote(self.path) if getattr(self, "path", None) else None,
            status=getattr(code, "value", code),
            bytes=getattr(self, "_sent", None),
            ms=round((time.monotonic() - started) * 1000) if started else None,
        )

    def log_error(self, fmt, *args):
        message = fmt % args
        # a kept-alive connection left idle is closed on purpose
        level = logging.DEBUG if message.startswith("Request timed out") else logging.WARNING
        log.event(level, "http_error", client=self.address_string(), worker=os.getpid(), message=message)

    def log_message(self, fmt, *args):
        log.event(logging.INFO, "http", client=self.address_string(), message=fmt % args)


class ResolverServer(ThreadingHTTPServer):
    # socketserver's default of 5 drops simultaneous connections, each retried by
    # TCP after 1 s, and the smp-server gives up after 3 s. The kernel caps it at somaxconn.
    request_queue_size = 128

    def handle_error(self, request, client_address):
        error = sys.exc_info()[1]
        if isinstance(error, ConnectionError):
            # the smp-server hung up, usually after its own timeout
            log.event(logging.WARNING, "client_gone", client=client_address[0], worker=os.getpid(), error=type(error).__name__)
        else:
            log.event(logging.ERROR, "request_failed", client=client_address[0], worker=os.getpid(), exc_info=True)


def client_address(peer: str, forwarded_for: str | None) -> str:
    """The peer, or behind trusted proxies the last X-Forwarded-For address none of them added."""
    if not forwarded_for or not _trusted(peer):
        return peer
    hops = [hop.strip() for hop in forwarded_for.split(",")]
    for hop in reversed(hops):
        # an address it cannot read, and anything claimed before it, is not believed
        if _address(hop) is None:
            return peer
        if not _trusted(hop):
            return hop
    return hops[0]


def _address(text: str):
    try:
        ip = ipaddress.ip_address(text)
    except ValueError:
        return None
    return ip.ipv4_mapped or ip if ip.version == 6 else ip


def _trusted(text: str) -> bool:
    ip = _address(text)
    return ip is not None and any(ip in net for net in config.TRUSTED_PROXIES)


def serve(reuse_port: bool):
    server = ResolverServer((config.BIND, config.PORT), Handler, bind_and_activate=False)
    server.allow_reuse_port = reuse_port
    try:
        server.server_bind()
        server.server_activate()
        server.serve_forever()
    finally:
        server.server_close()


def stop_on(signum, _frame):
    log.event(logging.INFO, "stopping", signal=signal.Signals(signum).name)
    sys.exit(0)


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

    def stop_and_exit(signum, frame):
        stop()
        stop_on(signum, frame)

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
                log.event(logging.ERROR, "worker_failed", worker=os.getpid(), exc_info=True)
                code = 1
            os._exit(code)
        children.append(pid)
    pid, status = os.wait()
    log.event(logging.ERROR, "worker_exited", worker=pid, status=status, action="stopping")
    stop()
    sys.exit(1)


def main():
    log.setup()
    log.event(
        logging.INFO,
        "listening",
        bind=config.BIND,
        port=config.PORT,
        workers=config.WORKERS,
        rpc=config.RPC,
        registries=",".join(f"{tld}={addr or '-'}" for tld, addr in config.REGISTRIES.items()),
        trusted_proxies=",".join(map(str, config.TRUSTED_PROXIES)) or None,
    )
    if config.WORKERS > 1:
        supervise(config.WORKERS)
    else:
        signal.signal(signal.SIGTERM, stop_on)
        signal.signal(signal.SIGINT, stop_on)
        serve(reuse_port=False)
