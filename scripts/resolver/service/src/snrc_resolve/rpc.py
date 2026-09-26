"""JSON-RPC to the node: pooled connections, batches, and the reads prefetched for a request."""

import json
import logging
import queue
import threading
from contextlib import contextmanager
from http.client import BadStatusLine, HTTPConnection, HTTPSConnection
from urllib.error import HTTPError
from urllib.parse import urlparse

from . import config, log
from .multicall import decode_aggregate3, encode_aggregate3


RPC_URL = urlparse(config.RPC)
# Set a non-default User-Agent; Cloudflare-fronted public RPCs (drpc,
# publicnode, etc.) reject `Python-urllib/3.x` with 403.
RPC_HEADERS = {"Content-Type": "application/json", "User-Agent": "snrc-resolve/1.0"}

# Idle keep-alive connections to SNRC_RPC. A connection per call costs most of
# a lookup's CPU and leaves a TIME_WAIT socket per call, which exhausts local
# ports at a few dozen lookups per second.
_rpc_pool = queue.LifoQueue()


def _new_rpc_connection():
    conn_class = HTTPSConnection if RPC_URL.scheme == "https" else HTTPConnection
    return conn_class(RPC_URL.hostname, RPC_URL.port, timeout=config.RPC_TIMEOUT_S)


def _post_rpc(conn, body: bytes) -> bytes:
    path = (RPC_URL.path or "/") + (f"?{RPC_URL.query}" if RPC_URL.query else "")
    conn.request("POST", path, body, RPC_HEADERS)
    res = conn.getresponse()
    data = res.read()
    # HTTPError, as urlopen raised: RuntimeError means the call itself failed
    if not 200 <= res.status < 300:
        raise HTTPError(config.RPC, res.status, res.reason, res.headers, None)
    return data


def _post_pooled(conn, body: bytes) -> bytes:
    try:
        data = _post_rpc(conn, body)
    except BaseException:
        conn.close()
        raise
    _rpc_pool.put(conn)
    return data


def _send_rpc(payload) -> object:
    body = json.dumps(payload).encode()
    try:
        idle = _rpc_pool.get_nowait()
    except queue.Empty:
        return json.loads(_post_pooled(_new_rpc_connection(), body))
    try:
        return json.loads(_post_pooled(idle, body))
    except (ConnectionError, BadStatusLine):
        # the node closed the idle connection; every call is a read, so resending is safe
        return json.loads(_post_pooled(_new_rpc_connection(), body))


# Reads prefetched for the request being answered, keyed by _read_key. Only set
# inside request_reads(), so code called outside a request reads one call at a time.
_request = threading.local()
_UNREAD = object()


def _read_key(method, params) -> str:
    return method + json.dumps(params, sort_keys=True)


@contextmanager
def request_reads():
    _request.reads = {}
    try:
        yield
    finally:
        del _request.reads


def call(method, params):
    reads = getattr(_request, "reads", None)
    if reads is not None:
        read = reads.get(_read_key(method, params), _UNREAD)
        if isinstance(read, RuntimeError):
            raise read
        if read is not _UNREAD:
            return read
    res = _send_rpc({"jsonrpc": "2.0", "method": method, "params": params, "id": 1})
    if "error" in res:
        raise RuntimeError(res["error"])
    return res["result"]


def _send_batch(requests):
    """Answers of a JSON-RPC batch in request order, None for a request left
    unanswered; all None when the node does not batch."""
    res = _send_rpc([{"jsonrpc": "2.0", "id": i, "method": m, "params": p} for i, (m, p) in enumerate(requests)])
    # a node that does not batch answers with a single error object
    by_id = {r.get("id"): r for r in res if isinstance(r, dict)} if isinstance(res, list) else {}
    return [by_id.get(i) for i in range(len(requests))]


def _is_latest_call(method, params) -> bool:
    return method == "eth_call" and params[1] == "latest"


_multicall_failed_logged = False


def _remember(reads, requests, answers):
    for (m, p), r in zip(requests, answers, strict=True):
        if r is not None:
            reads[_read_key(m, p)] = RuntimeError(r["error"]) if "error" in r else r.get("result")


def prefetch(requests):
    """Sends reads the request will make in one round trip, with its contract
    reads as one multicall. A read left unanswered is made on its own when the
    code gets to it."""
    global _multicall_failed_logged
    reads = getattr(_request, "reads", None)
    if reads is None:
        return
    todo = [(m, p) for m, p in requests if _read_key(m, p) not in reads]
    if len(todo) < 2:
        return
    calls = [(m, p) for m, p in todo if _is_latest_call(m, p)]
    if len(calls) < 2:
        _remember(reads, todo, _send_batch(todo))
        return
    others = [(m, p) for m, p in todo if not _is_latest_call(m, p)]
    multicall = eth_call_read(config.MULTICALL, encode_aggregate3([(p[0]["to"], p[0]["data"]) for _, p in calls]))
    answers = _send_batch(others + [multicall])
    if all(r is None for r in answers):
        return
    _remember(reads, others, answers[:-1])
    try:
        results = decode_aggregate3(answers[-1]["result"])
        if len(results) != len(calls):
            raise ValueError("multicall answered a different number of calls")
    except (KeyError, TypeError, ValueError) as e:
        if not _multicall_failed_logged:
            _multicall_failed_logged = True
            log.event(logging.WARNING, "multicall_unavailable", multicall=config.MULTICALL, error=repr(e), fallback="batch")
        _remember(reads, calls, _send_batch(calls))
        return
    for (m, p), (success, data) in zip(calls, results, strict=True):
        reads[_read_key(m, p)] = "0x" + data.hex() if success else RuntimeError("execution reverted")


BLOCK_READ = ("eth_getBlockByNumber", ["latest", False])


def eth_call_read(to: str, data: str):
    return "eth_call", [{"to": to, "data": data}, "latest"]


def eth_call(to: str, data: str) -> str:
    result = call(*eth_call_read(to, data))
    if result == "0x":
        raise RuntimeError(f"empty return from {to}: no contract at that address?")
    return result
