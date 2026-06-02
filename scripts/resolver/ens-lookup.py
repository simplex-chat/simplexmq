#!/usr/bin/env python3
"""Resolve an ENS name via local Reth (the same shape SNRC will use).

Usage:
  ./ens-lookup.py                     # defaults to simplexchat.eth
  ./ens-lookup.py vitalik.eth
  ./ens-lookup.py corevo.eth

Requires:  pip install --break-system-packages 'eth-hash[pycryptodome]'
"""

import base64
import json
import sys
from urllib.request import Request, urlopen

from eth_hash.auto import keccak

RPC = "http://127.0.0.1:8545"
# ENS Registry (current, post-2020 migration)
ENS_REGISTRY = "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e"


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
    req = Request(RPC, data=body, headers={"Content-Type": "application/json"})
    res = json.loads(urlopen(req, timeout=15).read())
    if "error" in res:
        raise RuntimeError(res["error"])
    return res["result"]


def namehash(name: str) -> bytes:
    """ENS namehash — recursive keccak256 over reversed labels."""
    node = b"\x00" * 32
    if name:
        for label in reversed(name.split(".")):
            node = keccak(node + keccak(label.encode()))
    return node


def selector(signature: str) -> str:
    return "0x" + keccak(signature.encode())[:4].hex()


def eth_call(to: str, data: str) -> str:
    return rpc("eth_call", [{"to": to, "data": data}, "latest"])


def decode_address(hex_data: str) -> str:
    return "0x" + hex_data[-40:]


def decode_bytes(hex_data: str) -> bytes:
    raw = bytes.fromhex(hex_data[2:] if hex_data.startswith("0x") else hex_data)
    if len(raw) < 64:
        return b""
    length = int.from_bytes(raw[32:64], "big")
    return raw[64:64 + length]


def encode_text_call(node: bytes, key: str) -> str:
    """ABI-encode text(bytes32 node, string key). String arg is dynamic:
    offset (=0x40) + length + right-padded data."""
    sel = selector("text(bytes32,string)")
    head = node.hex() + (0x40).to_bytes(32, "big").hex()
    key_bytes = key.encode()
    body = len(key_bytes).to_bytes(32, "big").hex() + key_bytes.hex()
    # right-pad to 32-byte boundary
    pad = (-len(key_bytes)) % 32
    body += "00" * pad
    return sel + head + body


def text(resolver: str, node: bytes, key: str) -> str:
    raw = decode_bytes(eth_call(resolver, encode_text_call(node, key)))
    return raw.decode("utf-8", errors="replace") if raw else ""


# Common ENS text keys (ENSIP-5). Resolvers may return empty for any of these.
TEXT_KEYS = [
    "url",
    "avatar",
    "description",
    "email",
    "notice",
    "keywords",
    "com.twitter",
    "com.github",
    "com.discord",
    "org.telegram",
    "io.keybase",
    "xyz.farcaster",
]


def decode_contenthash(raw: bytes) -> str:
    """ENS contenthash → human-readable URI (best-effort)."""
    if not raw:
        return "(empty)"
    # Multicodec prefixes:
    #   0xe301 = ipfs-ns + dag-pb (CIDv0/v1)
    #   0xe501 = ipns-ns
    #   0xe40101701b... = swarm
    if raw[:2] == b"\xe3\x01":
        cid_bytes = raw[2:]
        # Base32 lowercase + 'b' prefix per CIDv1 spec
        b32 = base64.b32encode(cid_bytes).decode().lower().rstrip("=")
        return f"ipfs://b{b32}"
    if raw[:2] == b"\xe5\x01":
        cid_bytes = raw[2:]
        b32 = base64.b32encode(cid_bytes).decode().lower().rstrip("=")
        return f"ipns://b{b32}"
    return "0x" + raw.hex()


def main():
    name = sys.argv[1] if len(sys.argv) > 1 else "simplexchat.eth"

    print(f"  name:       {name}")
    node = namehash(name)
    print(f"  namehash:   0x{node.hex()}")

    # 1. Ask the registry which resolver is responsible for this name
    resolver_data = selector("resolver(bytes32)") + node.hex()
    resolver_raw = eth_call(ENS_REGISTRY, resolver_data)
    resolver = decode_address(resolver_raw)
    print(f"  resolver:   {resolver}")
    if resolver == "0x0000000000000000000000000000000000000000":
        print("  → no resolver set for this name")
        return

    node_hex = node.hex()

    # 2. Ask the resolver for the address
    try:
        addr = decode_address(eth_call(resolver, selector("addr(bytes32)") + node_hex))
        print(f"  address:    {addr}")
    except Exception as e:
        print(f"  address:    (error: {e})")

    # 3. Ask the resolver for the content hash (IPFS pointer)
    try:
        ch = decode_bytes(eth_call(resolver, selector("contenthash(bytes32)") + node_hex))
        print(f"  contenthash: {decode_contenthash(ch)}")
    except Exception as e:
        print(f"  contenthash: (not supported: {e})")

    # 4. Owner from the registry
    try:
        owner = decode_address(eth_call(ENS_REGISTRY, selector("owner(bytes32)") + node_hex))
        print(f"  owner:      {owner}")
    except Exception as e:
        print(f"  owner:      (error: {e})")

    # 5. Text records (EIP-634). Print only the non-empty ones.
    print("  text records:")
    for key in TEXT_KEYS:
        try:
            v = text(resolver, node, key)
            if v:
                print(f"    {key:<16s} {v}")
        except Exception as e:
            print(f"    {key:<16s} (error: {e})")


if __name__ == "__main__":
    main()
