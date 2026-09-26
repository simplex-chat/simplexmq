"""Address encoders: each takes raw bytes as stored under ENSIP-9 and returns the canonical
user-facing string for that chain (EIP-55 for ETH, bech32/base58check for BTC, SS58 for DOT,
Monero-base58 for XMR)."""

import hashlib

from eth_hash.auto import keccak


# SLIP-44 coin types (https://github.com/satoshilabs/slips/blob/master/slip-0044.md)
COIN_ETH = 60
COIN_BTC = 0
COIN_XMR = 128
COIN_DOT = 354
RECORD_COINS = (COIN_ETH, COIN_BTC, COIN_XMR, COIN_DOT)


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
