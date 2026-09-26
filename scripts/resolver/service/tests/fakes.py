"""Test doubles: an in-memory chain served by a fake JSON-RPC node, and helpers shared by the tests."""

import json
import socket
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

from snrc_resolve import abi, answers, calls, coins, config, multicall, rpc


def registration(name):
    """registration() answers a NameResponse; most tests assert what is in it."""
    status, body = answers.registration(name)
    return status, (body["registration"] if status == 200 else body)


def abi_bytes(value: bytes) -> str:
    """head offset, length, then the payload padded to a 32-byte word."""
    pad = (-len(value)) % 32
    return "0x" + abi.encode_uint(0x20) + abi.encode_uint(len(value)) + (value + b"\x00" * pad).hex()


def prices_return(base: int, exceptions) -> str:
    """What SimplexPriceOracle.prices() returns: the base price and the lengths priced differently."""
    words = [abi.encode_uint(base), abi.encode_uint(0x40), abi.encode_uint(len(exceptions))]
    for length, cents in exceptions.items():
        words += [abi.encode_uint(length), abi.encode_uint(cents)]
    return "0x" + "".join(words)


def _word(value: int) -> bytes:
    return value.to_bytes(32, "big")


def decode_aggregate3_calls(data: str):
    """Multicall3.aggregate3 calldata back to (to, data) pairs, written apart
    from the resolver's encoder so the two check each other."""
    raw = bytes.fromhex(data[len(multicall.AGGREGATE3):])

    def word(at):
        return int.from_bytes(raw[at:at + 32], "big")

    array = word(0)
    base = array + 32
    decoded = []
    for i in range(word(array)):
        item = base + word(base + 32 * i)
        call = item + word(item + 64)
        decoded.append(("0x" + raw[item + 12:item + 32].hex(), "0x" + raw[call + 32:call + 32 + word(call)].hex()))
    return decoded


def encode_aggregate3_results(results) -> str:
    tuples = [
        _word(int(ok)) + _word(0x40) + _word(len(data)) + data + b"\x00" * ((-len(data)) % 32)
        for ok, data in results
    ]
    offsets, at = b"", 32 * len(tuples)
    for t in tuples:
        offsets += _word(at)
        at += len(t)
    return "0x" + (_word(0x20) + _word(len(tuples)) + offsets + b"".join(tuples)).hex()


class FakeChain:
    """Contract state for one registered name and one free name. Any other
    call reverts, as a view function asked for something unset does."""

    REGISTRY = "0x58fc46996d975c57883564648bda5206d1a0102b"
    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"
    CONTROLLER = "0x281ca41311c2aa808c917c4674639d7567b75714"
    ORACLE = "0x1e0c9a2b9d1a4c8f7b3e5d6a9c2f4b8e1d7a3c50"
    OWNER = "0xd83bd7e0e6b8a4c1f2593a7b0c4e8d1a6f9b2c37"
    RESOLVER = "0x80fa2b1c3d4e5f60718293a4b5c6d7e8f9012345"
    GRACE = 90 * 86400
    PRICE_BASE = 200
    PRICE_EXCEPTIONS = {1: 64000, 2: 16000, 3: 1600, 4: 800, 5: 500}
    TEXTS = {"nickname": "Acme", "url": "https://acme.example", "simplex.channel": "https://a.example/c#1;https://b.example/c#2"}

    def __init__(self):
        self.now = int(time.time())
        acme, free = abi.label_token("acme"), abi.label_token("free")
        node = abi.node_of("acme.testing")
        prices = prices_return(self.PRICE_BASE, self.PRICE_EXCEPTIONS)
        self.answers = {
            calls.expires_call(self.REGISTRAR, acme): "0x" + abi.encode_uint(self.now + 3600),
            calls.expires_call(self.REGISTRAR, free): "0x" + abi.encode_uint(0),
            calls.grace_call(self.REGISTRAR): "0x" + abi.encode_uint(self.GRACE),
            calls.label_call(self.REGISTRAR, acme): abi_bytes(b"acme"),
            calls.reserved_call(self.CONTROLLER, acme): "0x" + abi.encode_uint(0),
            calls.reserved_call(self.CONTROLLER, free): "0x" + abi.encode_uint(0),
            calls.resolver_call(self.REGISTRY, node): "0x" + abi.encode_uint(int(self.RESOLVER, 16)),
            calls.owner_call(self.REGISTRY, node): "0x" + abi.encode_uint(int(self.OWNER, 16)),
            calls.addr_call(self.RESOLVER, node, coins.COIN_ETH): abi_bytes(bytes.fromhex(self.OWNER[2:])),
            calls.prices_call(self.CONTROLLER): "0x" + abi.encode_uint(int(self.ORACLE, 16)),
            calls.prices_call(self.ORACLE): prices,
            calls.min_length_call(self.CONTROLLER): "0x" + abi.encode_uint(3),
        }
        for key, value in self.TEXTS.items():
            self.answers[calls.text_call(self.RESOLVER, node, key)] = abi_bytes(value.encode())

    def call(self, to, data):
        answer = self.answers.get((to.lower(), data))
        if answer is None:
            raise RuntimeError("execution reverted")
        return answer


class FakeNode(ThreadingHTTPServer):
    """A JSON-RPC node over HTTP/1.1 keep-alive, serving FakeChain, with
    batches and Multicall3, each of which a test can take away."""

    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), _FakeNodeHandler)
        self.chain = FakeChain()
        self.block = 100
        self.requests = 0
        self.connections = 0
        self.batch = True
        self.multicall = True
        self.status = 200
        self.hang_up = False
        self.drop_after_reply = False
        threading.Thread(target=self.serve_forever, args=(0.05,), daemon=True).start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server_address[1]}/"

    def stop(self):
        self.shutdown()
        self.server_close()

    def answer(self, req):
        out = {"jsonrpc": "2.0", "id": req.get("id")}
        method, params = req["method"], req["params"]
        if method == "eth_blockNumber":
            out["result"] = hex(self.block)
        elif method == "eth_getBlockByNumber":
            out["result"] = {"number": hex(self.block), "timestamp": hex(self.chain.now)}
        elif method == "eth_call" and params[0]["to"].lower() == config.MULTICALL.lower():
            if not self.multicall:
                out["error"] = {"code": -32000, "message": "no contract code"}
            else:
                results = []
                for to, data in decode_aggregate3_calls(params[0]["data"]):
                    try:
                        results.append((True, bytes.fromhex(self.chain.call(to, data)[2:])))
                    except RuntimeError:
                        results.append((False, b""))
                out["result"] = encode_aggregate3_results(results)
        elif method == "eth_call":
            try:
                out["result"] = self.chain.call(params[0]["to"], params[0]["data"])
            except RuntimeError:
                out["error"] = {"code": 3, "message": "execution reverted"}
        else:
            out["error"] = {"code": -32601, "message": "method not found"}
        return out


class _FakeNodeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        # headers and body go out in separate writes, which Nagle holds for the client's delayed ACK
        self.request.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.server.connections += 1

    def do_POST(self):  # noqa: N802 - http.server contract
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        node = self.server
        node.requests += 1
        if node.hang_up:
            self.close_connection = True
            return
        if node.status != 200:
            reply = {"error": "unavailable"}
        elif isinstance(request, list):
            reply = [node.answer(r) for r in request] if node.batch else {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "batch not supported"}}
        else:
            reply = node.answer(request)
        data = json.dumps(reply).encode()
        self.send_response(node.status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        # closes without `Connection: close`, as a node dropping an idle connection does
        self.close_connection = node.drop_after_reply

    def log_message(self, fmt, *args):
        pass


class FakeNodeTestCase(unittest.TestCase):
    """Points the resolver at a FakeNode and at FakeChain's contracts."""

    def setUp(self):
        self.node = FakeNode()
        self._saved = (config.RPC, rpc.RPC_URL, config.REGISTRIES, config.REGISTRARS, config.CONTROLLERS)
        config.RPC = self.node.url
        rpc.RPC_URL = urlparse(config.RPC)
        config.REGISTRIES = {"testing": FakeChain.REGISTRY, "simplex": ""}
        config.REGISTRARS = {"testing": FakeChain.REGISTRAR}
        config.CONTROLLERS = {"testing": FakeChain.CONTROLLER}
        rpc._multicall_failed_logged = False
        self._drain_pool()

    def tearDown(self):
        self._drain_pool()
        config.RPC, rpc.RPC_URL, config.REGISTRIES, config.REGISTRARS, config.CONTROLLERS = self._saved
        self.node.stop()

    def _drain_pool(self):
        while not rpc._rpc_pool.empty():
            rpc._rpc_pool.get_nowait().close()

    def requests_made(self, action):
        before = self.node.requests
        result = action()
        return result, self.node.requests - before
