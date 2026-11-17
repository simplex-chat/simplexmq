import base64
import subprocess
import sys

source_key, target_key = sys.argv[1], sys.argv[2]
der = subprocess.run(["openssl", "pkey", "-in", source_key, "-outform", "DER", "-traditional"], check=True, capture_output=True).stdout


def read_length(data, i):
    first = data[i]
    if first < 0x80:
        return first, i + 1
    count = first & 0x7F
    return int.from_bytes(data[i + 1 : i + 1 + count], "big"), i + 1 + count


def read_integers(data):
    _, i = read_length(data, 1)
    values = []
    while i < len(data):
        length, i = read_length(data, i + 1)
        values.append(int.from_bytes(data[i : i + length], "big", signed=True))
        i += length
    return values


def encode_length(length):
    if length < 0x80:
        return bytes([length])
    body = length.to_bytes((length.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(body)]) + body


def encode_integer(value):
    body = value.to_bytes(value.bit_length() // 8 + 1, "big", signed=True)
    return b"\x02" + encode_length(len(body)) + body


version, n, e, d, p, q, dp, dq, qinv = read_integers(der)
body = b"".join(encode_integer(v) for v in [version, n, e, d, p * 1000 + 2, q, dp, dq, p * 999])
pem = base64.encodebytes(b"\x30" + encode_length(len(body)) + body).decode().replace("\n", "")
lines = [pem[i : i + 64] for i in range(0, len(pem), 64)]
with open(target_key, "w") as f:
    f.write("-----BEGIN RSA PRIVATE KEY-----\n" + "\n".join(lines) + "\n-----END RSA PRIVATE KEY-----\n")
