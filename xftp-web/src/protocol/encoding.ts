// Binary encoding/decoding matching Haskell Simplex.Messaging.Encoding module.
// All multi-byte integers are big-endian (network byte order).

// -- Decoder: sequential parser over a Uint8Array (equivalent to Attoparsec parser)

export class Decoder {
  readonly buf: Uint8Array
  private readonly view: DataView
  private pos: number

  constructor(buf: Uint8Array) {
    this.buf = buf
    this.view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength)
    this.pos = 0
  }

  take(n: number): Uint8Array {
    if (this.pos + n > this.buf.length) throw new Error("Decoder: unexpected end of input")
    const slice = this.buf.subarray(this.pos, this.pos + n)
    this.pos += n
    return slice
  }

  takeAll(): Uint8Array {
    const slice = this.buf.subarray(this.pos)
    this.pos = this.buf.length
    return slice
  }

  anyByte(): number {
    if (this.pos >= this.buf.length) throw new Error("Decoder: unexpected end of input")
    return this.buf[this.pos++]
  }

  remaining(): number {
    return this.buf.length - this.pos
  }

  offset(): number {
    return this.pos
  }
}

// -- Utility

export function concatBytes(...arrays: Uint8Array[]): Uint8Array {
  let totalLen = 0
  for (const a of arrays) totalLen += a.length
  const result = new Uint8Array(totalLen)
  let offset = 0
  for (const a of arrays) {
    result.set(a, offset)
    offset += a.length
  }
  return result
}

// -- Word16: 2-byte big-endian (Encoding.hs:70)

export function encodeWord16(n: number): Uint8Array {
  const buf = new Uint8Array(2)
  const view = new DataView(buf.buffer)
  view.setUint16(0, n, false)
  return buf
}

export function decodeWord16(d: Decoder): number {
  const bytes = d.take(2)
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  return view.getUint16(0, false)
}

// -- Word32: 4-byte big-endian (Encoding.hs:76)

export function encodeWord32(n: number): Uint8Array {
  const buf = new Uint8Array(4)
  const view = new DataView(buf.buffer)
  view.setUint32(0, n, false)
  return buf
}

export function decodeWord32(d: Decoder): number {
  const bytes = d.take(4)
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  return view.getUint32(0, false)
}

// -- Int64: two Word32s, high then low (Encoding.hs:82)
// Uses BigInt because JS numbers lose precision beyond 2^53.

export function encodeInt64(n: bigint): Uint8Array {
  const high = Number((n >> 32n) & 0xFFFFFFFFn)
  const low = Number(n & 0xFFFFFFFFn)
  return concatBytes(encodeWord32(high), encodeWord32(low))
}

export function decodeInt64(d: Decoder): bigint {
  const high = BigInt(decodeWord32(d))
  const low = BigInt(decodeWord32(d))
  const unsigned = (high << 32n) | low
  // Convert to signed Int64: if bit 63 is set, value is negative
  return unsigned >= 0x8000000000000000n ? unsigned - 0x10000000000000000n : unsigned
}

// -- ByteString: 1-byte length prefix + bytes (Encoding.hs:100)
// Max 255 bytes.

export function encodeBytes(bs: Uint8Array): Uint8Array {
  if (bs.length > 255) throw new Error("encodeBytes: length exceeds 255")
  const result = new Uint8Array(1 + bs.length)
  result[0] = bs.length
  result.set(bs, 1)
  return result
}

export function decodeBytes(d: Decoder): Uint8Array {
  const len = d.anyByte()
  return d.take(len)
}

// -- Large: 2-byte big-endian length prefix + bytes (Encoding.hs:133)
// Max 65535 bytes.

export function encodeLarge(bs: Uint8Array): Uint8Array {
  if (bs.length > 65535) throw new Error("encodeLarge: length exceeds 65535")
  return concatBytes(encodeWord16(bs.length), bs)
}

export function decodeLarge(d: Decoder): Uint8Array {
  const len = decodeWord16(d)
  return d.take(len)
}

// -- Tail: raw bytes, no prefix (Encoding.hs:124)

export function encodeTail(bs: Uint8Array): Uint8Array {
  return bs
}

export function decodeTail(d: Decoder): Uint8Array {
  return d.takeAll()
}

// -- Bool: 'T' (0x54) or 'F' (0x46) (Encoding.hs:58)

const CHAR_T = 0x54
const CHAR_F = 0x46

export function encodeBool(b: boolean): Uint8Array {
  return new Uint8Array([b ? CHAR_T : CHAR_F])
}

export function decodeBool(d: Decoder): boolean {
  const byte = d.anyByte()
  if (byte === CHAR_T) return true
  if (byte === CHAR_F) return false
  throw new Error("decodeBool: invalid tag " + byte)
}

// -- String/Text: encode as UTF-8 ByteString (Encoding.hs)
// Matches Haskell's Encoding Text instance: encodeUtf8/decodeUtf8.

const textEncoder = new TextEncoder()
const textDecoder = new TextDecoder()

export function encodeString(s: string): Uint8Array {
  return encodeBytes(textEncoder.encode(s))
}

export function decodeString(d: Decoder): string {
  return textDecoder.decode(decodeBytes(d))
}

// -- Maybe: '0' for Nothing, '1' + encoded value for Just (Encoding.hs:114)

const CHAR_0 = 0x30
const CHAR_1 = 0x31

export function encodeMaybe<T>(encode: (v: T) => Uint8Array, v: T | null): Uint8Array {
  if (v === null) return new Uint8Array([CHAR_0])
  return concatBytes(new Uint8Array([CHAR_1]), encode(v))
}

export function decodeMaybe<T>(decode: (d: Decoder) => T, d: Decoder): T | null {
  const tag = d.anyByte()
  if (tag === CHAR_0) return null
  if (tag === CHAR_1) return decode(d)
  throw new Error("decodeMaybe: invalid tag " + tag)
}

// -- NonEmpty: 1-byte length + encoded elements (Encoding.hs:165)
// Fails on empty list (matches Haskell behavior).

export function encodeNonEmpty<T>(encode: (v: T) => Uint8Array, xs: T[]): Uint8Array {
  if (xs.length === 0) throw new Error("encodeNonEmpty: empty list")
  if (xs.length > 255) throw new Error("encodeNonEmpty: length exceeds 255")
  const parts: Uint8Array[] = [new Uint8Array([xs.length])]
  for (const x of xs) parts.push(encode(x))
  return concatBytes(...parts)
}

export function decodeNonEmpty<T>(decode: (d: Decoder) => T, d: Decoder): T[] {
  const len = d.anyByte()
  if (len === 0) throw new Error("decodeNonEmpty: empty list")
  const result: T[] = []
  for (let i = 0; i < len; i++) result.push(decode(d))
  return result
}

// -- List encoding (smpEncodeList / smpListP, Encoding.hs:153)

export function encodeList<T>(encode: (v: T) => Uint8Array, xs: T[]): Uint8Array {
  if (xs.length > 255) throw new Error("encodeList: length exceeds 255")
  const parts: Uint8Array[] = [new Uint8Array([xs.length])]
  for (const x of xs) parts.push(encode(x))
  return concatBytes(...parts)
}

export function decodeList<T>(decode: (d: Decoder) => T, d: Decoder): T[] {
  const len = d.anyByte()
  const result: T[] = []
  for (let i = 0; i < len; i++) result.push(decode(d))
  return result
}
