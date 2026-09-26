"""Solidity ABI words and bytes, selectors, and ENS name hashing."""

from functools import lru_cache

from eth_hash.auto import keccak


ZERO_ADDR = "0x0000000000000000000000000000000000000000"


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


@lru_cache(maxsize=None)
def selector(signature: str) -> str:
    return "0x" + keccak(signature.encode())[:4].hex()


def decode_address(hex_data: str) -> str:
    return "0x" + hex_data[-40:]


def decode_bytes(hex_data: str) -> bytes:
    raw = bytes.fromhex(hex_data[2:] if hex_data.startswith("0x") else hex_data)
    if len(raw) < 64:
        return b""
    length = int.from_bytes(raw[32:64], "big")
    return raw[64:64 + length]


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


def encode_addr_multicoin_call(node: bytes, coin_type: int) -> str:
    """ENSIP-9 addr(bytes32 node, uint256 coinType) — both static, no offsets."""
    return (
        selector("addr(bytes32,uint256)")
        + node.hex()
        + coin_type.to_bytes(32, "big").hex()
    )
