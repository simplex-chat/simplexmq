// Streaming XSalsa20-Poly1305 -- Simplex.Messaging.Crypto / Crypto.Lazy
//
// Libsodium-wrappers-sumo does not expose crypto_stream_xsalsa20_xor_ic,
// so the Salsa20/20 stream cipher core is implemented here.
// HSalsa20 uses libsodium's crypto_core_hsalsa20.
// Poly1305 uses libsodium's streaming crypto_onetimeauth_* API.

import sodium, {StateAddress} from "libsodium-wrappers-sumo"
import {concatBytes} from "../protocol/encoding.js"
import {pad, unPad, padLazy, unPadLazy} from "./padding.js"

// crypto_core_hsalsa20 exists at runtime but is missing from @types/libsodium-wrappers-sumo
const _sodium = sodium as unknown as {
  crypto_core_hsalsa20(input: Uint8Array, key: Uint8Array, constant?: Uint8Array): Uint8Array
} & typeof sodium

// -- Salsa20/20 stream cipher core

function readU32LE(buf: Uint8Array, off: number): number {
  return ((buf[off] | (buf[off + 1] << 8) | (buf[off + 2] << 16) | (buf[off + 3] << 24)) >>> 0)
}

function writeU32LE(buf: Uint8Array, off: number, val: number): void {
  buf[off] = val & 0xff
  buf[off + 1] = (val >>> 8) & 0xff
  buf[off + 2] = (val >>> 16) & 0xff
  buf[off + 3] = (val >>> 24) & 0xff
}

function rotl32(v: number, n: number): number {
  return ((v << n) | (v >>> (32 - n))) >>> 0
}

const SIGMA_0 = 0x61707865
const SIGMA_1 = 0x3320646e
const SIGMA_2 = 0x79622d32
const SIGMA_3 = 0x6b206574

function salsa20Block(key: Uint8Array, nonce8: Uint8Array, counter: number): Uint8Array {
  const k0 = readU32LE(key, 0),  k1 = readU32LE(key, 4)
  const k2 = readU32LE(key, 8),  k3 = readU32LE(key, 12)
  const k4 = readU32LE(key, 16), k5 = readU32LE(key, 20)
  const k6 = readU32LE(key, 24), k7 = readU32LE(key, 28)
  const n0 = readU32LE(nonce8, 0), n1 = readU32LE(nonce8, 4)

  const s0  = SIGMA_0, s1  = k0, s2  = k1, s3  = k2
  const s4  = k3, s5  = SIGMA_1, s6  = n0, s7  = n1
  const s8  = counter >>> 0, s9 = 0, s10 = SIGMA_2, s11 = k4
  const s12 = k5, s13 = k6, s14 = k7, s15 = SIGMA_3

  let x0 = s0, x1 = s1, x2 = s2, x3 = s3
  let x4 = s4, x5 = s5, x6 = s6, x7 = s7
  let x8 = s8, x9 = s9, x10 = s10, x11 = s11
  let x12 = s12, x13 = s13, x14 = s14, x15 = s15

  for (let i = 0; i < 10; i++) {
    // Column round
    x4  ^= rotl32((x0  + x12) >>> 0, 7);  x8  ^= rotl32((x4  + x0)  >>> 0, 9)
    x12 ^= rotl32((x8  + x4)  >>> 0, 13); x0  ^= rotl32((x12 + x8)  >>> 0, 18)
    x9  ^= rotl32((x5  + x1)  >>> 0, 7);  x13 ^= rotl32((x9  + x5)  >>> 0, 9)
    x1  ^= rotl32((x13 + x9)  >>> 0, 13); x5  ^= rotl32((x1  + x13) >>> 0, 18)
    x14 ^= rotl32((x10 + x6)  >>> 0, 7);  x2  ^= rotl32((x14 + x10) >>> 0, 9)
    x6  ^= rotl32((x2  + x14) >>> 0, 13); x10 ^= rotl32((x6  + x2)  >>> 0, 18)
    x3  ^= rotl32((x15 + x11) >>> 0, 7);  x7  ^= rotl32((x3  + x15) >>> 0, 9)
    x11 ^= rotl32((x7  + x3)  >>> 0, 13); x15 ^= rotl32((x11 + x7)  >>> 0, 18)
    // Row round
    x1  ^= rotl32((x0  + x3)  >>> 0, 7);  x2  ^= rotl32((x1  + x0)  >>> 0, 9)
    x3  ^= rotl32((x2  + x1)  >>> 0, 13); x0  ^= rotl32((x3  + x2)  >>> 0, 18)
    x6  ^= rotl32((x5  + x4)  >>> 0, 7);  x7  ^= rotl32((x6  + x5)  >>> 0, 9)
    x4  ^= rotl32((x7  + x6)  >>> 0, 13); x5  ^= rotl32((x4  + x7)  >>> 0, 18)
    x11 ^= rotl32((x10 + x9)  >>> 0, 7);  x8  ^= rotl32((x11 + x10) >>> 0, 9)
    x9  ^= rotl32((x8  + x11) >>> 0, 13); x10 ^= rotl32((x9  + x8)  >>> 0, 18)
    x12 ^= rotl32((x15 + x14) >>> 0, 7);  x13 ^= rotl32((x12 + x15) >>> 0, 9)
    x14 ^= rotl32((x13 + x12) >>> 0, 13); x15 ^= rotl32((x14 + x13) >>> 0, 18)
  }

  const out = new Uint8Array(64)
  writeU32LE(out, 0,  (x0  + s0)  >>> 0); writeU32LE(out, 4,  (x1  + s1)  >>> 0)
  writeU32LE(out, 8,  (x2  + s2)  >>> 0); writeU32LE(out, 12, (x3  + s3)  >>> 0)
  writeU32LE(out, 16, (x4  + s4)  >>> 0); writeU32LE(out, 20, (x5  + s5)  >>> 0)
  writeU32LE(out, 24, (x6  + s6)  >>> 0); writeU32LE(out, 28, (x7  + s7)  >>> 0)
  writeU32LE(out, 32, (x8  + s8)  >>> 0); writeU32LE(out, 36, (x9  + s9)  >>> 0)
  writeU32LE(out, 40, (x10 + s10) >>> 0); writeU32LE(out, 44, (x11 + s11) >>> 0)
  writeU32LE(out, 48, (x12 + s12) >>> 0); writeU32LE(out, 52, (x13 + s13) >>> 0)
  writeU32LE(out, 56, (x14 + s14) >>> 0); writeU32LE(out, 60, (x15 + s15) >>> 0)
  return out
}

// -- Streaming state

export interface SbState {
  _subkey: Uint8Array
  _nonce8: Uint8Array
  _counter: number
  _ksBuf: Uint8Array
  _ksOff: number
  _authState: StateAddress
}

export function sbInit(key: Uint8Array, nonce: Uint8Array): SbState {
  // Double HSalsa20 cascade matching Haskell cryptonite XSalsa20 (Crypto.hs:xSalsa20):
  //   subkey1 = HSalsa20(key, zeros16)
  //   subkey2 = HSalsa20(subkey1, nonce[0:16])
  //   keystream = Salsa20(subkey2, nonce[16:24])
  const zeros16 = new Uint8Array(16)
  const subkey1 = _sodium.crypto_core_hsalsa20(zeros16, key)
  const subkey = _sodium.crypto_core_hsalsa20(nonce.subarray(0, 16), subkey1)
  const nonce8 = new Uint8Array(nonce.subarray(16, 24))
  const block0 = salsa20Block(subkey, nonce8, 0)
  const poly1305Key = block0.subarray(0, 32)
  const ksBuf = new Uint8Array(block0.subarray(32))
  const authState = sodium.crypto_onetimeauth_init(poly1305Key)
  return {_subkey: subkey, _nonce8: nonce8, _counter: 1, _ksBuf: ksBuf, _ksOff: 0, _authState: authState}
}

export function cbInit(dhSecret: Uint8Array, nonce: Uint8Array): SbState {
  return sbInit(dhSecret, nonce)
}

export function sbEncryptChunk(state: SbState, chunk: Uint8Array): Uint8Array {
  const cipher = xorKeystream(state, chunk)
  sodium.crypto_onetimeauth_update(state._authState, cipher)
  return cipher
}

export function sbDecryptChunk(state: SbState, chunk: Uint8Array): Uint8Array {
  sodium.crypto_onetimeauth_update(state._authState, chunk)
  return xorKeystream(state, chunk)
}

export function sbAuth(state: SbState): Uint8Array {
  return sodium.crypto_onetimeauth_final(state._authState)
}

// -- High-level: tail tag (tag appended)

export function sbEncryptTailTag(
  key: Uint8Array, nonce: Uint8Array,
  data: Uint8Array, len: bigint, padLen: bigint
): Uint8Array {
  const padded = padLazy(data, len, padLen)
  const state = sbInit(key, nonce)
  const cipher = sbEncryptChunk(state, padded)
  const tag = sbAuth(state)
  return concatBytes(cipher, tag)
}

export function sbDecryptTailTag(
  key: Uint8Array, nonce: Uint8Array,
  paddedLen: bigint, data: Uint8Array
): {valid: boolean; content: Uint8Array} {
  const pLen = Number(paddedLen)
  const cipher = data.subarray(0, pLen)
  const providedTag = data.subarray(pLen)
  const state = sbInit(key, nonce)
  const plaintext = sbDecryptChunk(state, cipher)
  const computedTag = sbAuth(state)
  const valid = providedTag.length === 16 && constantTimeEqual(providedTag, computedTag)
  const content = unPadLazy(plaintext)
  return {valid, content}
}

// -- Tag-prepended secretbox (Haskell Crypto.hs:cryptoBox)

export function cryptoBox(key: Uint8Array, nonce: Uint8Array, msg: Uint8Array): Uint8Array {
  const state = sbInit(key, nonce)
  const cipher = sbEncryptChunk(state, msg)
  const tag = sbAuth(state)
  return concatBytes(tag, cipher)
}

export function cbEncrypt(
  dhSecret: Uint8Array, nonce: Uint8Array,
  msg: Uint8Array, padLen: number
): Uint8Array {
  return cryptoBox(dhSecret, nonce, pad(msg, padLen))
}

export function cbDecrypt(
  dhSecret: Uint8Array, nonce: Uint8Array,
  packet: Uint8Array
): Uint8Array {
  const tag = packet.subarray(0, 16)
  const cipher = packet.subarray(16)
  const state = sbInit(dhSecret, nonce)
  const plaintext = sbDecryptChunk(state, cipher)
  const computedTag = sbAuth(state)
  if (!constantTimeEqual(tag, computedTag)) throw new Error("secretbox: authentication failed")
  return unPad(plaintext)
}

// -- Internal

function xorKeystream(state: SbState, data: Uint8Array): Uint8Array {
  const result = new Uint8Array(data.length)
  let off = 0
  while (off < data.length) {
    if (state._ksOff >= state._ksBuf.length) {
      state._ksBuf = salsa20Block(state._subkey, state._nonce8, state._counter++)
      state._ksOff = 0
    }
    const available = state._ksBuf.length - state._ksOff
    const needed = data.length - off
    const n = Math.min(available, needed)
    for (let i = 0; i < n; i++) {
      result[off + i] = data[off + i] ^ state._ksBuf[state._ksOff + i]
    }
    state._ksOff += n
    off += n
  }
  return result
}

function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i]
  return diff === 0
}
