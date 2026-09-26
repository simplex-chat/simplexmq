"""A name's record, read from its resolver."""

from . import config, rpc
from .abi import ZERO_ADDR, decode_address, decode_bytes, is_encoded_labelhash, label_token, node_of
from .calls import addr_call, label_call, owner_call, resolver_call, text_call
from .coins import COIN_BTC, COIN_DOT, COIN_ENCODERS, COIN_ETH, COIN_XMR, RECORD_COINS


def registered_label(registrar: str, token: int):
    """The plaintext label the registrar recorded at registration, keyed by the
    hash of that label. None when the name was registered without
    registerWithLabel, so the registrar cannot name it."""
    raw = decode_bytes(rpc.eth_call(*label_call(registrar, token)))
    return raw.decode("utf-8", errors="replace") if raw else None


def canonical_name(name: str):
    """The name to answer with: a hashed query does not carry one, so the
    registrar's record of the label fills it in. None when it recorded none."""
    labels = name.split(".")
    registrar = config.REGISTRARS.get(labels[-1])
    if not registrar or len(labels) != 2 or not is_encoded_labelhash(labels[0]):
        return name
    label = registered_label(registrar, label_token(labels[0]))
    return label + "." + labels[1] if label else None


def text(resolver: str, node: bytes, key: str) -> str:
    raw = decode_bytes(rpc.eth_call(*text_call(resolver, node, key)))
    return raw.decode("utf-8", errors="replace") if raw else ""


def addr_multicoin(resolver: str, node: bytes, coin_type: int):
    """Read ENSIP-9 raw bytes for `coinType`, then encode to that chain's
    canonical presentation form. Falls back to `0x`-prefixed hex if the
    payload doesn't match any recognised on-chain shape. Returns None when
    the record is unset."""
    try:
        raw = decode_bytes(rpc.eth_call(*addr_call(resolver, node, coin_type)))
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


def record_reads(resolver: str, node: bytes):
    """The reads of a name's record from its resolver."""
    return [rpc.eth_call_read(*text_call(resolver, node, k)) for k in TEXT_KEYS] + [
        rpc.eth_call_read(*addr_call(resolver, node, coin)) for coin in RECORD_COINS
    ]


# Text-record keys we read from the resolver. Surfaced under the response
# field names listed in the package docstring. `name` and `description` are
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


def name_record(name: str):
    """The NameRecord for a registered name. A name with no resolver set still
    has one, with every field unset."""
    registry = config.REGISTRIES[name.rsplit(".", 1)[-1]]
    node = node_of(name)
    resolver_addr = decode_address(rpc.eth_call(*resolver_call(registry, node)))
    owner = decode_address(rpc.eth_call(*owner_call(registry, node)))
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
    rpc.prefetch(record_reads(resolver_addr, node))
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
