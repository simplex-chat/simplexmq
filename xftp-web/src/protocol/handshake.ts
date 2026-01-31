// XFTP handshake encoding/decoding — Simplex.FileTransfer.Transport
//
// Handles XFTP client/server handshake messages and version negotiation.

import {
  Decoder, concatBytes,
  encodeWord16, decodeWord16,
  encodeBytes, decodeBytes,
  decodeLarge, decodeNonEmpty
} from "./encoding.js"
import {sha256} from "../crypto/digest.js"
import {decodePubKeyX25519} from "../crypto/keys.js"
import {blockPad, blockUnpad, XFTP_BLOCK_SIZE} from "./transmission.js"

// ── Version types ──────────────────────────────────────────────────

export interface VersionRange {
  minVersion: number  // Word16
  maxVersion: number  // Word16
}

// Encode version range as two big-endian Word16s.
// Matches Haskell: smpEncode (VRange v1 v2) = smpEncode (v1, v2)
export function encodeVersionRange(vr: VersionRange): Uint8Array {
  return concatBytes(encodeWord16(vr.minVersion), encodeWord16(vr.maxVersion))
}

export function decodeVersionRange(d: Decoder): VersionRange {
  const minVersion = decodeWord16(d)
  const maxVersion = decodeWord16(d)
  if (minVersion > maxVersion) throw new Error("invalid version range: min > max")
  return {minVersion, maxVersion}
}

// Version negotiation: intersection of two version ranges, or null if incompatible.
// Matches Haskell compatibleVRange.
export function compatibleVRange(a: VersionRange, b: VersionRange): VersionRange | null {
  const min = Math.max(a.minVersion, b.minVersion)
  const max = Math.min(a.maxVersion, b.maxVersion)
  if (min > max) return null
  return {minVersion: min, maxVersion: max}
}

// ── Client handshake ───────────────────────────────────────────────

export interface XFTPClientHandshake {
  xftpVersion: number    // Word16 — negotiated version
  keyHash: Uint8Array    // SHA-256 CA certificate fingerprint (32 bytes)
}

// Encode and pad client handshake to XFTP_BLOCK_SIZE.
// Wire format: pad(smpEncode (xftpVersion, keyHash), 16384)
export function encodeClientHandshake(ch: XFTPClientHandshake): Uint8Array {
  const body = concatBytes(encodeWord16(ch.xftpVersion), encodeBytes(ch.keyHash))
  return blockPad(body, XFTP_BLOCK_SIZE)
}

// ── Server handshake ───────────────────────────────────────────────

export interface XFTPServerHandshake {
  xftpVersionRange: VersionRange
  sessionId: Uint8Array
  certChainDer: Uint8Array[]    // raw DER certificate blobs (NonEmpty)
  signedKeyDer: Uint8Array      // raw DER SignedExact blob
}

// Decode padded server handshake block.
// Wire format: unpad(block) → (versionRange, sessionId, certChainPubKey)
//   where certChainPubKey = (NonEmpty Large certChain, Large signedKey)
// Trailing bytes (Tail) are ignored for forward compatibility.
export function decodeServerHandshake(block: Uint8Array): XFTPServerHandshake {
  const raw = blockUnpad(block)
  const d = new Decoder(raw)
  const xftpVersionRange = decodeVersionRange(d)
  const sessionId = decodeBytes(d)
  // CertChainPubKey: smpEncode (encodeCertChain certChain, SignedObject signedPubKey)
  const certChainDer = decodeNonEmpty(decodeLarge, d)
  const signedKeyDer = decodeLarge(d)
  // Remaining bytes are Tail (ignored for forward compatibility)
  return {xftpVersionRange, sessionId, certChainDer, signedKeyDer}
}

// ── Certificate utilities ──────────────────────────────────────────

// SHA-256 fingerprint of the CA certificate (last cert in chain).
// Matches Haskell: XV.getFingerprint ca X.HashSHA256
export function caFingerprint(certChainDer: Uint8Array[]): Uint8Array {
  if (certChainDer.length < 2) throw new Error("caFingerprint: need at least 2 certs (leaf + CA)")
  return sha256(certChainDer[certChainDer.length - 1])
}

// ── SignedExact DER parsing ────────────────────────────────────────

// Parsed components of an X.509 SignedExact structure.
export interface SignedKey {
  objectDer: Uint8Array   // raw DER of the signed object (SubjectPublicKeyInfo)
  dhKey: Uint8Array       // extracted 32-byte X25519 public key
  algorithm: Uint8Array   // AlgorithmIdentifier DER bytes
  signature: Uint8Array   // raw Ed25519 signature bytes (64 bytes)
}

// Parse ASN.1 DER length (short and long form).
function derLength(d: Decoder): number {
  const first = d.anyByte()
  if (first < 0x80) return first
  const numBytes = first & 0x7f
  if (numBytes === 0 || numBytes > 4) throw new Error("DER: unsupported length encoding")
  let len = 0
  for (let i = 0; i < numBytes; i++) {
    len = (len << 8) | d.anyByte()
  }
  return len
}

// Read a complete TLV element, returning the full DER bytes (tag + length + value).
function derElement(d: Decoder): Uint8Array {
  const start = d.offset()
  d.anyByte()           // tag
  const len = derLength(d)
  d.take(len)           // value
  return d.buf.subarray(start, d.offset())
}

// Extract components from a SignedExact X.PubKey DER structure.
// ASN.1 layout:
//   SEQUENCE {
//     SubjectPublicKeyInfo (SEQUENCE)  — the signed object
//     AlgorithmIdentifier  (SEQUENCE)  — signature algorithm
//     BIT STRING                       — signature
//   }
export function extractSignedKey(signedDer: Uint8Array): SignedKey {
  const outer = new Decoder(signedDer)
  const outerTag = outer.anyByte()
  if (outerTag !== 0x30) throw new Error("SignedExact: expected SEQUENCE tag 0x30, got 0x" + outerTag.toString(16))
  derLength(outer) // consume total content length

  // First element: SubjectPublicKeyInfo
  const objectDer = derElement(outer)

  // Second element: AlgorithmIdentifier
  const algorithm = derElement(outer)

  // Third element: BIT STRING (signature)
  const sigTag = outer.anyByte()
  if (sigTag !== 0x03) throw new Error("SignedExact: expected BIT STRING tag 0x03, got 0x" + sigTag.toString(16))
  const sigLen = derLength(outer)
  const unusedBits = outer.anyByte()
  if (unusedBits !== 0) throw new Error("SignedExact: expected 0 unused bits in signature")
  const signature = outer.take(sigLen - 1)

  // Extract X25519 key from SubjectPublicKeyInfo
  const dhKey = decodePubKeyX25519(objectDer)

  return {objectDer, dhKey, algorithm, signature}
}
