"""Multicall3.aggregate3 calldata and results."""


AGGREGATE3 = "0x82ad56cb"  # aggregate3((address,bool,bytes)[])


def encode_aggregate3(calls) -> str:
    """Calldata for Multicall3.aggregate3 with every call allowed to fail."""
    tuples = []
    for to, data in calls:
        b = bytes.fromhex(data[2:])
        tuples.append(
            int(to, 16).to_bytes(32, "big")
            + (1).to_bytes(32, "big")
            + (0x60).to_bytes(32, "big")
            + len(b).to_bytes(32, "big")
            + b
            + b"\x00" * ((-len(b)) % 32)
        )
    offsets, at = [], 32 * len(tuples)
    for t in tuples:
        offsets.append(at.to_bytes(32, "big"))
        at += len(t)
    body = (0x20).to_bytes(32, "big") + len(tuples).to_bytes(32, "big") + b"".join(offsets) + b"".join(tuples)
    return AGGREGATE3 + body.hex()


def decode_aggregate3(hex_data: str):
    """Multicall3.aggregate3's (bool success, bytes returnData)[]."""
    raw = bytes.fromhex(hex_data[2:] if hex_data.startswith("0x") else hex_data)

    def word(at: int) -> int:
        if at + 32 > len(raw):
            raise ValueError("multicall answer is truncated")
        return int.from_bytes(raw[at:at + 32], "big")

    array = word(0)
    base = array + 32
    out = []
    for i in range(word(array)):
        item = base + word(base + 32 * i)
        data = item + word(item + 32)
        length = word(data)
        if data + 32 + length > len(raw):
            raise ValueError("multicall answer is truncated")
        out.append((word(item) != 0, raw[data + 32:data + 32 + length]))
    return out
