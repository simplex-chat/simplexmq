#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "eth-hash[pycryptodome]>=0.7",
# ]
# ///
"""SimpleX Namespace (SNRC) resolver — REST API.

Resolves names like `alice.testing` / `bob.simplex` against the SNRC
deployment on Ethereum mainnet (or any compatible ENS-shaped registry)
and returns a flat JSON document with these fields:

  name, nickname, website, location,
  simplexContact, simplexChannel,    -- list[str], primary first
  eth, btc, xmr, dot,
  owner, resolver

`simplexContact` and `simplexChannel` are arrays so a name can advertise
multiple SMP servers for redundancy. Clients SHOULD try the URLs in the
order returned. The on-chain text record stores them as a single
`LINK_SEPARATOR` (`;`)-joined string; this resolver splits and trims into a list.

All keys are valid Haskell record-field identifiers (lowercase initial,
no dots), so consumers can derive aeson FromJSON instances directly
without a key-rewriting layer.

Usage:
  ./snrc-resolve.py                    # serve on :8000

  curl -s http://127.0.0.1:8000/resolve/foobar.testing | jq .
  curl -s 'http://127.0.0.1:8000/resolve/[<64-hex labelhash>].testing' | jq .
  curl -s http://127.0.0.1:8000/health

Environment:
  SNRC_RPC               JSON-RPC endpoint (default: http://127.0.0.1:8545)
  SNRC_REGISTRY_TESTING  ENSRegistry for the .testing deployment
                         (default: mainnet,
                          0x58fc46996d975c57883564648bda5206d1a0102b)
  SNRC_REGISTRY_SIMPLEX  ENSRegistry for the .simplex deployment
                         (default: empty — TLD not yet deployed)
  SNRC_REGISTRAR_<TLD>   BaseRegistrar (ERC-721) for the TLD; expiry and status
                         (default: mainnet for .testing, empty for .simplex)
  SNRC_CONTROLLER_<TLD>  SimplexController (proxy) for the TLD; reservations,
                         and through its `prices()` oracle what registering costs
                         (default: mainnet for .testing, empty for .simplex)
  SNRC_PORT              Listen port (default: 8000)
  SNRC_BIND              Bind address (default: 0.0.0.0)

Each TLD is a separate SNRC deployment with its own ENSRegistry; the
resolver dispatches by the queried name's rightmost label.

Dependencies are declared inline (PEP 723) at the top of this file. Run with:
  uv run snrc-resolve.py          # uv resolves & caches deps; one-line setup
  python snrc-resolve.py          # if eth-hash[pycryptodome] is already installed

Addresses are returned in each chain's canonical presentation:
  eth  EIP-55 mixed-case checksummed hex      (e.g. 0xEa65A0…1572)
  btc  bech32(m) for segwit/taproot, base58check for P2PKH/P2SH
       (e.g. bc1q…  /  1A1zP1…)
  dot  SS58 with Polkadot network prefix 0    (e.g. 15oF4u…)
  xmr  Monero base58                          (e.g. 4Aux5y…)
Unrecognised payloads fall back to `0x`-prefixed raw hex.
"""

import hashlib
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse
from urllib.request import Request, urlopen

from eth_hash.auto import keccak

RPC = os.environ.get("SNRC_RPC", "http://127.0.0.1:8545")
BIND = os.environ.get("SNRC_BIND", "0.0.0.0")
PORT = int(os.environ.get("SNRC_PORT", "8000"))

# Each TLD is its own SNRC deployment with its own ENSRegistry. Dispatch
# happens on the rightmost label of the queried name. Empty / unset means
# "not deployed" — requests for that TLD return 400 with a clear error.
# `... or "..."` makes the script's defaults the single source of truth:
# unset AND empty-string both fall through to the literal. docker-compose
# can therefore pass `SNRC_REGISTRY_TESTING=${SNRC_REGISTRY_TESTING:-}`
# without duplicating the registry address.
REGISTRIES = {
    "testing": os.environ.get("SNRC_REGISTRY_TESTING", "")
    or "0x58fc46996d975c57883564648bda5206d1a0102b",  # mainnet .testing
    "simplex": os.environ.get("SNRC_REGISTRY_SIMPLEX", ""),  # not deployed yet
}

REGISTRARS = {
    "testing": os.environ.get("SNRC_REGISTRAR_TESTING", "")
    or "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a",  # mainnet .testing
    "simplex": os.environ.get("SNRC_REGISTRAR_SIMPLEX", ""),  # not deployed yet
}

CONTROLLERS = {
    "testing": os.environ.get("SNRC_CONTROLLER_TESTING", "")
    # Proxy address, not SimplexControllerImpl: storage is held by the proxy.
    # Recorded in deployments.json as ETHRegistrarController.
    or "0xeeb9b6bf5fb68fb726005f7ba549c2f4b32f2dad",  # mainnet .testing
    "simplex": os.environ.get("SNRC_CONTROLLER_SIMPLEX", ""),  # not deployed yet
}

# `reservedNames` holds a SimplexController.Reason; 0 means not reserved. A
# controller from before the enum stores a bool, whose `true` decodes as 1,
# which is why 1 reads as "internal".
RESERVED_REASONS = {
    1: ("internal", "reserved for SimpleX"),
    2: ("trademark", "reserved to protect a trademark"),
    3: ("community", "reserved for the community"),
}
# a Reason added to the contract after this resolver: still reserved, unworded
UNKNOWN_REASON = ("unknown", "reserved")

# SLIP-44 coin types (https://github.com/satoshilabs/slips/blob/master/slip-0044.md)
COIN_ETH = 60
COIN_BTC = 0
COIN_XMR = 128
COIN_DOT = 354

ZERO_ADDR = "0x0000000000000000000000000000000000000000"

# The registry prices in attoUSD (1e-18 USD); the protocol carries US cents.


# ---------- RPC + ABI helpers (mirrors ens-lookup.py shape) ----------

def rpc(method, params):
    body = json.dumps(
        {"jsonrpc": "2.0", "method": method, "params": params, "id": 1}
    ).encode()
    # Set a non-default User-Agent; Cloudflare-fronted public RPCs (drpc,
    # publicnode, etc.) reject `Python-urllib/3.x` with 403.
    req = Request(
        RPC,
        data=body,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "snrc-resolve/1.0",
        },
    )
    res = json.loads(urlopen(req, timeout=15).read())
    if "error" in res:
        raise RuntimeError(res["error"])
    return res["result"]


def namehash(name: str) -> bytes:
    node = b"\x00" * 32
    if name:
        for label in reversed(name.split(".")):
            node = keccak(node + keccak(label.encode()))
    return node


# ENS's encoding for a label whose preimage is unknown. Brackets are outside
# the normalised character set, so it cannot collide with a registrable name.
ENCODED_LABELHASH_LEN = 66  # "[" + 64 hex + "]"


def is_encoded_labelhash(label: str) -> bool:
    return (
        len(label) == ENCODED_LABELHASH_LEN
        and label.startswith("[")
        and label.endswith("]")
        and all(c in "0123456789abcdef" for c in label[1:-1])
    )


def node_of(name: str) -> bytes:
    """namehash, decoding a second-level labelhash so `[hash].tld` reaches the
    node its name does. Only a second-level name is ever hashed; a bracket
    anywhere else is hashed as written."""
    labels = name.split(".")
    if len(labels) != 2 or not is_encoded_labelhash(labels[0]):
        return namehash(name)
    return keccak(namehash(labels[1]) + bytes.fromhex(labels[0][1:-1]))


# ---------- Registration status ----------


def head_block():
    """How far behind the node is. Unlike expiry, this is the one thing that has
    to be measured against the host clock: a node that stops still has a block."""
    try:
        block = rpc("eth_getBlockByNumber", ["latest", False])
        return {
            "blockNumber": decode_uint(block["number"]),
            "chainLagSeconds": int(time.time()) - decode_uint(block["timestamp"]),
        }
    except Exception:
        return {"blockNumber": None, "chainLagSeconds": None}


def chain_now() -> int:
    """Expiry is compared against the block timestamp, never the host clock."""
    block = rpc("eth_getBlockByNumber", ["latest", False])
    return decode_uint(block["timestamp"])


def grace_period(registrar: str) -> int:
    """A deployment can configure a different window, so it is read on chain."""
    return decode_uint(eth_call(registrar, selector("GRACE_PERIOD()")))


def expiry_status(expires: int, grace: int, now: int) -> str:
    """The registrar's `available(id)` is not enough on its own: it is also
    true for a name nobody registered, since 0 + GRACE_PERIOD < now."""
    if expires == 0:
        return "unregistered"
    if expires > now:
        return "registered"
    if expires + grace >= now:
        return "grace"
    return "expired"


def reservation_reason(tld: str, token: int) -> int:
    """The SimplexController.Reason held for the name, 0 when not reserved."""
    controller = CONTROLLERS.get(tld)
    if not controller:
        return 0
    raw = eth_call(controller, selector("reservedNames(bytes32)") + encode_uint(token))
    return decode_uint(raw)


def pricing_params(tld: str):
    """What it costs to register a name under this TLD, in US cents, or None
    when no controller or price oracle is configured."""
    controller = CONTROLLERS.get(tld)
    if not controller:
        return None
    oracle = decode_address(eth_call(controller, selector("prices()")))
    if oracle == ZERO_ADDR:
        return None
    try:
        return read_oracle_prices(controller, oracle)
    except RuntimeError:
        # An oracle that does not expose its curve cannot be quoted from. The
        # name is still registrable; the price is simply not ours to state.
        return None


SECONDS_PER_YEAR = 31536000
ATTO_PER_CENT = 10**16


def read_oracle_prices(controller: str, oracle: str):
    """SimplexPriceOracle keeps the curve in US cents per year, the unit the SMP
    protocol carries. An ENS-shaped oracle prices in attoUSD per second and
    charges a premium on lapsed names that it does not expose, so a quote from
    it is only safe for a name that was never registered."""
    try:
        base, tiers = decode_prices(eth_call(oracle, selector("prices()")))
        premium_unknown = False
    except RuntimeError:
        base, tiers = decode_letter_prices(oracle)
        premium_unknown = True
    min_len = decode_uint(eth_call(controller, selector("minCharLength()")))
    return {
        # lengths the registry refuses are left out rather than priced at zero
        "registrationPrices": {n: c for n, c in tiers.items() if n >= min_len},
        "basePrice": base,
        "minLabelLength": min_len,
        "_premiumUnknown": premium_unknown,
    }


def decode_letter_prices(oracle: str):
    """`price1Letter()`..`price6Letter()`, in attoUSD per second. Quotes round
    up, so one is never below what the registry charges. An oracle built before
    the six-letter tier stops at five, and charges its highest tier for anything
    longer, which is what basePrice means here."""
    tiers = {}
    for n in range(1, 7):
        try:
            rate = decode_uint(eth_call(oracle, selector(f"price{n}Letter()")))
        except RuntimeError:
            if n <= 5:
                raise
            break
        tiers[n] = ceil_div(rate * SECONDS_PER_YEAR, ATTO_PER_CENT)
    return tiers.pop(max(tiers)), tiers


def ceil_div(a: int, b: int) -> int:
    return -(-a // b)


def decode_prices(hex_data: str):
    """`prices()` returns the base price and the lengths priced differently."""
    raw = bytes.fromhex(hex_data[2:] if hex_data.startswith("0x") else hex_data)
    # a short answer is not a curve: decoding it would quote every name as free
    if len(raw) < 96:
        raise RuntimeError("prices(): short response")
    base = int.from_bytes(raw[:32], "big")
    at = int.from_bytes(raw[32:64], "big")
    count = int.from_bytes(raw[at:at + 32], "big")
    tiers = {}
    for i in range(count):
        item = at + 32 + i * 64
        length = int.from_bytes(raw[item:item + 32], "big")
        tiers[length] = int.from_bytes(raw[item + 32:item + 64], "big")
    return base, tiers


def name_status(name: str):
    labels = name.split(".")
    tld = labels[-1]
    registrar = REGISTRARS.get(tld)
    if not registrar or len(labels) < 2:
        return {
            "status": "unknown",
            # nothing was read, so there is no block to report
            "readAt": None,
            "expires": None,
            "graceEnds": None,
            "reasonCode": None,
            "reason": None,
        }

    # nameExpires and reservedNames are keyed on uint256(keccak(label)).
    # The 2LD's label is that key at any depth. node_of decodes a bracket only
    # in a two-label name, so a bracket subname gets a status but no record.
    token = label_token(labels[-2])
    expires = decode_uint(
        eth_call(registrar, selector("nameExpires(uint256)") + encode_uint(token))
    )
    grace = grace_period(registrar) if expires else 0
    now = chain_now()
    status = expiry_status(expires, grace, now)

    # A reservation is orthogonal to the registration: a registered name can be
    # held back too.
    code = reservation_reason(tld, token)
    reason = RESERVED_REASONS.get(code, UNKNOWN_REASON) if code else None

    out = {
        "status": status,
        # the block this was read at
        "readAt": now,
        "expires": expires or None,
        "graceEnds": (expires + grace) if expires else None,
        "reasonCode": reason[0] if reason else None,
        "reason": reason[1] if reason else None,
    }
    if status in ("unregistered", "expired"):
        pricing = pricing_params(tld)
        # a lapsed name may carry a premium this resolver cannot read, and a
        # quote without it would be below what the registry charges
        if pricing and not (status == "expired" and pricing["_premiumUnknown"]):
            out.update({k: v for k, v in pricing.items() if not k.startswith("_")})
    return out


def selector(signature: str) -> str:
    return "0x" + keccak(signature.encode())[:4].hex()


def eth_call(to: str, data: str) -> str:
    result = rpc("eth_call", [{"to": to, "data": data}, "latest"])
    if result == "0x":
        raise RuntimeError(f"empty return from {to}: no contract at that address?")
    return result


def decode_address(hex_data: str) -> str:
    return "0x" + hex_data[-40:]


def decode_bytes(hex_data: str) -> bytes:
    raw = bytes.fromhex(hex_data[2:] if hex_data.startswith("0x") else hex_data)
    if len(raw) < 64:
        return b""
    length = int.from_bytes(raw[32:64], "big")
    return raw[64:64 + length]


def registered_label(registrar: str, token: int):
    """The plaintext label the registrar recorded at registration, keyed by the
    hash of that label. None when the name was registered without
    registerWithLabel, so the registrar cannot name it."""
    raw = decode_bytes(eth_call(registrar, selector("labelOf(uint256)") + encode_uint(token)))
    return raw.decode("utf-8", errors="replace") if raw else None


def canonical_name(name: str):
    """The name to answer with: a hashed query does not carry one, so the
    registrar's record of the label fills it in. None when it recorded none."""
    labels = name.split(".")
    registrar = REGISTRARS.get(labels[-1])
    if not registrar or len(labels) != 2 or not is_encoded_labelhash(labels[0]):
        return name
    label = registered_label(registrar, label_token(labels[0]))
    return label + "." + labels[1] if label else None


def label_token(label: str) -> int:
    """The registry key for a second-level label, whether it arrived as text or
    already hashed."""
    if is_encoded_labelhash(label):
        return int(label[1:-1], 16)
    return int.from_bytes(keccak(label.encode()), "big")


def decode_uint(hex_data: str) -> int:
    raw = hex_data[2:] if hex_data.startswith("0x") else hex_data
    return int(raw[-64:], 16) if raw else 0


def encode_uint(value: int) -> str:
    return value.to_bytes(32, "big").hex()


def encode_text_call(node: bytes, key: str) -> str:
    sel = selector("text(bytes32,string)")
    head = node.hex() + (0x40).to_bytes(32, "big").hex()
    key_bytes = key.encode()
    body = len(key_bytes).to_bytes(32, "big").hex() + key_bytes.hex()
    body += "00" * ((-len(key_bytes)) % 32)
    return sel + head + body


def text(resolver: str, node: bytes, key: str) -> str:
    raw = decode_bytes(eth_call(resolver, encode_text_call(node, key)))
    return raw.decode("utf-8", errors="replace") if raw else ""


def encode_addr_multicoin_call(node: bytes, coin_type: int) -> str:
    """ENSIP-9 addr(bytes32 node, uint256 coinType) — both static, no offsets."""
    return (
        selector("addr(bytes32,uint256)")
        + node.hex()
        + coin_type.to_bytes(32, "big").hex()
    )


def addr_multicoin(resolver: str, node: bytes, coin_type: int):
    """Read ENSIP-9 raw bytes for `coinType`, then encode to that chain's
    canonical presentation form. Falls back to `0x`-prefixed hex if the
    payload doesn't match any recognised on-chain shape. Returns None when
    the record is unset."""
    try:
        raw = decode_bytes(eth_call(resolver, encode_addr_multicoin_call(node, coin_type)))
    except RuntimeError:
        return None
    if not raw:
        return None
    # An all-zero payload is the ENS convention for "unset" — many tools
    # write 20 zero bytes for coinType=60 instead of clearing the slot.
    # Treat it as null so the response doesn't surface a zero address.
    if raw == b"\x00" * len(raw):
        return None
    encoder = COIN_ENCODERS.get(coin_type)
    if encoder is None:
        return "0x" + raw.hex()
    try:
        return encoder(raw) or ("0x" + raw.hex())
    except Exception:
        return "0x" + raw.hex()


# ---------- Coin-specific address encoders ----------
# Each takes raw bytes as stored under ENSIP-9 and returns the canonical
# user-facing string for that chain (EIP-55 for ETH, bech32/base58check
# for BTC, SS58 for DOT, Monero-base58 for XMR). All stdlib + eth_hash.


B58_ALPHA = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def _b58_encode(b: bytes) -> str:
    n = int.from_bytes(b, "big")
    out = ""
    while n:
        n, r = divmod(n, 58)
        out = B58_ALPHA[r] + out
    # leading zero bytes → leading '1's
    pad = len(b) - len(b.lstrip(b"\x00"))
    return "1" * pad + out


def _b58check_encode(payload: bytes) -> str:
    """Base58Check used by BTC legacy/P2SH: payload + dSHA256(payload)[:4]."""
    chk = hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
    return _b58_encode(payload + chk)


# ---- Bech32 / Bech32m (BIP-173 / BIP-350) ----

_BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
_BECH32_GEN = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]


def _bech32_polymod(values):
    chk = 1
    for v in values:
        b = chk >> 25
        chk = ((chk & 0x1FFFFFF) << 5) ^ v
        for i in range(5):
            if (b >> i) & 1:
                chk ^= _BECH32_GEN[i]
    return chk


def _bech32_hrp_expand(hrp):
    return [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]


def _bech32_create_checksum(hrp, data, spec):
    const = 1 if spec == "bech32" else 0x2BC830A3  # bech32m
    values = _bech32_hrp_expand(hrp) + data + [0] * 6
    polymod = _bech32_polymod(values) ^ const
    return [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]


def _bech32_encode(hrp, data, spec):
    combined = data + _bech32_create_checksum(hrp, data, spec)
    return hrp + "1" + "".join(_BECH32_CHARSET[d] for d in combined)


def _convertbits(data, frombits, tobits, pad=True):
    acc = 0
    bits = 0
    ret = []
    maxv = (1 << tobits) - 1
    max_acc = (1 << (frombits + tobits - 1)) - 1
    for value in data:
        if value < 0 or (value >> frombits):
            return None
        acc = ((acc << frombits) | value) & max_acc
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad and bits:
        ret.append((acc << (tobits - bits)) & maxv)
    elif not pad and (bits >= frombits or ((acc << (tobits - bits)) & maxv)):
        return None
    return ret


def _segwit_encode(hrp: str, witver: int, witprog: bytes) -> str:
    spec = "bech32" if witver == 0 else "bech32m"
    data = [witver] + _convertbits(list(witprog), 8, 5)
    return _bech32_encode(hrp, data, spec)


# ---- BTC scriptPubKey → address ----
# ENSIP-9 stores the raw output script. Dispatch by length + opcode prefix.

def _btc_encode(raw: bytes) -> str | None:
    hrp = "bc"  # mainnet
    if len(raw) == 25 and raw[:3] == b"\x76\xa9\x14" and raw[23:25] == b"\x88\xac":
        return _b58check_encode(b"\x00" + raw[3:23])  # P2PKH
    if len(raw) == 23 and raw[:2] == b"\xa9\x14" and raw[22:23] == b"\x87":
        return _b58check_encode(b"\x05" + raw[2:22])  # P2SH
    if len(raw) == 22 and raw[:2] == b"\x00\x14":
        return _segwit_encode(hrp, 0, raw[2:22])  # P2WPKH
    if len(raw) == 34 and raw[:2] == b"\x00\x20":
        return _segwit_encode(hrp, 0, raw[2:34])  # P2WSH
    if len(raw) == 34 and raw[:2] == b"\x51\x20":
        return _segwit_encode(hrp, 1, raw[2:34])  # P2TR
    return None


# ---- Polkadot SS58 ----
# Per SS58 spec: base58( prefix_byte + pubkey + blake2b-512("SS58PRE" + body)[:2] )
# Polkadot mainnet uses network prefix 0 (single byte); Kusama uses 2.

_SS58_PRE = b"SS58PRE"


def _ss58_encode(pubkey: bytes, network_prefix: int = 0) -> str:
    if len(pubkey) != 32:
        return None
    body = bytes([network_prefix]) + pubkey
    checksum = hashlib.blake2b(_SS58_PRE + body, digest_size=64).digest()[:2]
    return _b58_encode(body + checksum)


def _dot_encode(raw: bytes) -> str | None:
    return _ss58_encode(raw, network_prefix=0)


# ---- Monero base58 ----
# Monero base58 encodes in 8-byte blocks; each full block → 11 chars, partial
# block sizes per fixed table. Alphabet is identical to Bitcoin's.

_XMR_BLOCK_SIZES = [0, 2, 3, 5, 6, 7, 9, 10, 11]


def _xmr_encode(raw: bytes) -> str:
    out = []
    for i in range(0, len(raw), 8):
        chunk = raw[i:i + 8]
        n = int.from_bytes(chunk, "big")
        width = 11 if len(chunk) == 8 else _XMR_BLOCK_SIZES[len(chunk)]
        block = []
        for _ in range(width):
            n, r = divmod(n, 58)
            block.append(B58_ALPHA[r])
        out.append("".join(reversed(block)))
    return "".join(out)


# ---- ETH EIP-55 mixed-case checksum ----

def _eth_encode(raw: bytes) -> str | None:
    if len(raw) != 20:
        return None
    hex_addr = raw.hex()
    hash_hex = keccak(hex_addr.encode()).hex()
    return "0x" + "".join(
        c.upper() if c.isalpha() and int(hash_hex[i], 16) >= 8 else c
        for i, c in enumerate(hex_addr)
    )


COIN_ENCODERS = {
    COIN_ETH: _eth_encode,
    COIN_BTC: _btc_encode,
    COIN_XMR: _xmr_encode,
    COIN_DOT: _dot_encode,
}


# ---------- Resolution logic ----------

# Text-record keys we read from the resolver. Surfaced under the response
# field names listed in the docstring above. `name` and `description` are
# common ENS fallbacks for a human-readable nickname.
TEXT_KEYS = [
    "name",
    "nickname",
    "description",
    "url",
    "location",
    "simplex.contact",
    "simplex.channel",
]


# Separator that joins the SMP-server URL list inside a simplex.contact /
# simplex.channel text record. MUST match SIMPLEX_LINK_SEPARATOR in the dApp
# (ens-app-v3 src/constants/simplex.ts) — the two sides decode the same record.
LINK_SEPARATOR = ";"


def split_links(value: str) -> list:
    """Split a separator-joined text record into an ordered list of entries.

    Trims whitespace around each element and drops empties so trailing
    separators, doubled separators, and all-whitespace inputs all yield clean
    output. Single-value records yield a 1-element list; empty inputs
    yield `[]`. Used for `simplex.contact` / `simplex.channel`, which
    store one-or-more SMP-server URLs as a single `LINK_SEPARATOR`-joined string.
    """
    return [item.strip() for item in value.split(LINK_SEPARATOR) if item.strip()]


def upstream_error(subject: dict, e: Exception) -> dict:
    """urlopen puts the failing URL into its message and SNRC_RPC can carry a
    provider key, so the text goes to the log and only the type to the caller."""
    print(f"upstream error: {type(e).__name__}: {e}", file=sys.stderr)
    return {
        **subject,
        "error": "upstreamError",
        "message": f"upstream RPC failed ({type(e).__name__})",
    }


def name_record(name: str):
    """The NameRecord for a registered name. A name with no resolver set still
    has one, with every field unset."""
    registry = REGISTRIES[name.rsplit(".", 1)[-1]]
    node = node_of(name)
    node_hex = node.hex()
    resolver_addr = decode_address(eth_call(registry, selector("resolver(bytes32)") + node_hex))
    owner = decode_address(eth_call(registry, selector("owner(bytes32)") + node_hex))
    rec = {
        "name": canonical_name(name),
        "nickname": "",
        "website": "",
        "location": "",
        "simplexContact": [],
        "simplexChannel": [],
        "eth": None,
        "btc": None,
        "xmr": None,
        "dot": None,
        "owner": owner,
        "resolver": resolver_addr,
    }
    if resolver_addr == ZERO_ADDR:
        return rec
    texts = {}
    for k in TEXT_KEYS:
        try:
            v = text(resolver_addr, node, k)
        except RuntimeError:
            v = ""
        if v:
            texts[k] = v
    rec.update(
        {
            "nickname": texts.get("nickname") or texts.get("name") or texts.get("description") or "",
            "website": texts.get("url", ""),
            "location": texts.get("location", ""),
            "simplexContact": split_links(texts.get("simplex.contact", "")),
            "simplexChannel": split_links(texts.get("simplex.channel", "")),
            "eth": addr_multicoin(resolver_addr, node, COIN_ETH),
            "btc": addr_multicoin(resolver_addr, node, COIN_BTC),
            "xmr": addr_multicoin(resolver_addr, node, COIN_XMR),
            "dot": addr_multicoin(resolver_addr, node, COIN_DOT),
        }
    )
    return rec


def resolution(reg, registration_body):
    """The SMP protocol's NameResolution: the registration and the block read at."""
    return 200, {"readAt": reg["readAt"], "registration": registration_body}


def registration(name: str):
    """The SMP protocol's NameRegistration, which the relay decodes as is.
    Translating the contract's model to it is this resolver's job."""
    tld = name.rsplit(".", 1)[-1]
    if not REGISTRIES.get(tld):
        return 400, {"name": name, "error": "tldNotConfigured"}
    reg = name_status(name)
    status = reg["status"]
    if status in ("registered", "grace"):
        rec = name_record(name)
        # the client checks that the record names what it asked about, so a
        # hashed query the registrar cannot name is refused rather than answered
        if rec["name"] is None:
            return 502, {"name": name, "error": "labelNotRecorded"}
        # a subname inherits the 2LD's status, so only its node's owner says
        # whether anyone created it
        if len(name.split(".")) > 2 and rec["owner"] == ZERO_ADDR:
            # name_status reads pricing only when the name was already
            # unregistered, so read it here
            status = "unregistered"
            pricing = pricing_params(tld)
            if pricing:
                reg.update({k: v for k, v in pricing.items() if not k.startswith("_")})
        else:
            return resolution(reg, {
                "type": "registered",
                "expires": reg["expires"],
                "graceUntil": reg["graceEnds"],
                "reservedReason_": reg["reasonCode"],
                "nameRecord": rec,
            })
    if reg["reasonCode"]:
        return resolution(reg, {"type": "reserved", "reservedReason": reg["reasonCode"]})
    if status in ("unregistered", "expired"):
        if "basePrice" not in reg:
            return 502, {"name": name, "error": "noPriceOracle"}
        return resolution(reg, {
            "type": "available",
            "pricing": {
                "registrationPrices": reg["registrationPrices"],
                "basePrice": reg["basePrice"],
                "minLabelLength": reg["minLabelLength"],
            },
        })
    return 502, {"name": name, "error": status}


def resolve(name: str):
    tld = name.rsplit(".", 1)[-1]
    registry = REGISTRIES.get(tld)
    if not registry:
        configured = [k for k, v in REGISTRIES.items() if v]
        return 400, {
            "name": name,
            "error": "tldNotConfigured",
            "message": f"TLD '{tld}' is not configured on this resolver",
            "configuredTlds": configured,
        }

    node = node_of(name)
    node_hex = node.hex()

    # Before the resolver lookup, so a lapsed name is not reported as noResolver.
    reg = name_status(name)
    if reg["status"] in ("unregistered", "expired"):
        # A name in grace is not here: its record still resolves.
        body = {
            "name": name,
            **reg,
            "error": reg["status"],
            "message": (
                "this name has never been registered"
                if reg["status"] == "unregistered"
                else "this registration expired and is open to anyone"
            ),
        }
        return (404 if reg["status"] == "unregistered" else 410), body

    resolver_raw = eth_call(registry, selector("resolver(bytes32)") + node_hex)
    resolver_addr = decode_address(resolver_raw)
    if resolver_addr == ZERO_ADDR:
        # A registered name always resolves: with no resolver set the record is
        # still returned with every field unset, so "taken until <date>" stays
        # answerable. For a subname, no owner means nobody created it.
        owner = decode_address(eth_call(registry, selector("owner(bytes32)") + node_hex))
        if len(name.split(".")) > 2 and owner == ZERO_ADDR:
            return 404, {
                "name": name,
                **reg,
                "status": "unregistered",
                "error": "unregistered",
                "message": "this subname has never been created",
            }
        return 200, {
            "name": canonical_name(name) or name,
            "nickname": "",
            "website": "",
            "location": "",
            "simplexContact": [],
            "simplexChannel": [],
            "eth": None,
            "btc": None,
            "xmr": None,
            "dot": None,
            "owner": owner,
            "resolver": ZERO_ADDR,
            **reg,
        }

    owner_raw = eth_call(registry, selector("owner(bytes32)") + node_hex)
    owner = decode_address(owner_raw)

    texts = {}
    for k in TEXT_KEYS:
        try:
            v = text(resolver_addr, node, k)
        except RuntimeError:
            v = ""
        if v:
            texts[k] = v

    # The user-facing "nickname" prefers an explicit `nickname` record,
    # falls back to `name`, then `description` (ENSIP-5 convention).
    nickname = texts.get("nickname") or texts.get("name") or texts.get("description") or ""

    # Keys chosen to be valid Haskell record-field identifiers (lowercase
    # initial, no dots) so consumers can derive aeson FromJSON instances
    # without a key-rewriting layer. On-chain text-record names still
    # use the ENSIP-5 dot convention (e.g. "simplex.contact") — only the
    # resolver's JSON surface camelCases them.
    return 200, {
        "name": canonical_name(name) or name,
        "nickname": nickname,
        "website": texts.get("url", ""),
        "location": texts.get("location", ""),
        "simplexContact": split_links(texts.get("simplex.contact", "")),
        "simplexChannel": split_links(texts.get("simplex.channel", "")),
        "eth": addr_multicoin(resolver_addr, node, COIN_ETH),
        "btc": addr_multicoin(resolver_addr, node, COIN_BTC),
        "xmr": addr_multicoin(resolver_addr, node, COIN_XMR),
        "dot": addr_multicoin(resolver_addr, node, COIN_DOT),
        "owner": owner,
        "resolver": resolver_addr,
        **reg,
    }


# ---------- HTTP layer ----------

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - http.server contract
        path = urlparse(self.path).path
        parts = [unquote(p) for p in path.split("/") if p]

        if parts == ["health"]:
            self._respond(200, {"ok": True, "rpc": RPC, "registries": REGISTRIES, **head_block()})
            return

        if len(parts) == 3 and parts[0] == "v2" and parts[1] == "resolve":
            name = parts[2].strip().lower()
            if not name or "." not in name:
                self._respond(400, {"name": name, "error": "notFullyQualified"})
                return
            try:
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

    def log_message(self, fmt, *args):
        # Quiet the default per-request access log; route to stderr in one line.
        sys.stderr.write(f"{self.address_string()} - {fmt % args}\n")


def main():
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    sys.stderr.write(
        f"snrc-resolve listening on {BIND}:{PORT}\n"
        f"  RPC = {RPC}\n"
        f"  Registries:\n"
    )
    for tld, addr in REGISTRIES.items():
        sys.stderr.write(f"    .{tld:<8s} = {addr or '(not configured)'}\n")
    sys.stderr.write("  GET /v2/resolve/<name>   GET /v1/resolve/<name>   GET /health\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("\nshutting down\n")
        server.server_close()


if __name__ == "__main__":
    main()
