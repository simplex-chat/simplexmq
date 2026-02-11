// XFTP handshake encoding/decoding -- Simplex.FileTransfer.Transport
//
// Handles XFTP client/server handshake messages and version negotiation.

import {
  Decoder, concatBytes,
  encodeWord16, decodeWord16,
  encodeBytes, decodeBytes,
  encodeMaybe,
  decodeLarge, decodeNonEmpty
} from "./encoding.js"
import {sha256} from "../crypto/digest.js"
import {decodePubKeyX25519} from "../crypto/keys.js"
import {blockPad, blockUnpad, XFTP_BLOCK_SIZE} from "./transmission.js"

// -- Version types

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

// -- Client hello

export interface XFTPClientHello {
  webChallenge: Uint8Array | null  // 32 random bytes for web handshake, or null for standard
}

// Encode client hello (padded to XFTP_BLOCK_SIZE for web clients).
// Wire format: smpEncode (Maybe ByteString), padded when webChallenge present
export function encodeClientHello(hello: XFTPClientHello): Uint8Array {
  const body = encodeMaybe(encodeBytes, hello.webChallenge)
  return hello.webChallenge ? blockPad(body, XFTP_BLOCK_SIZE) : body
}

// -- Client handshake

export interface XFTPClientHandshake {
  xftpVersion: number    // Word16 -- negotiated version
  keyHash: Uint8Array    // SHA-256 CA certificate fingerprint (32 bytes)
}

// Encode and pad client handshake to XFTP_BLOCK_SIZE.
// Wire format: pad(smpEncode (xftpVersion, keyHash), 16384)
export function encodeClientHandshake(ch: XFTPClientHandshake): Uint8Array {
  const body = concatBytes(encodeWord16(ch.xftpVersion), encodeBytes(ch.keyHash))
  return blockPad(body, XFTP_BLOCK_SIZE)
}

// -- Server handshake

export interface XFTPServerHandshake {
  xftpVersionRange: VersionRange
  sessionId: Uint8Array
  certChainDer: Uint8Array[]    // raw DER certificate blobs (NonEmpty)
  signedKeyDer: Uint8Array      // raw DER SignedExact blob
  webIdentityProof: Uint8Array | null  // signature bytes, or null if absent/empty
}

// Decode padded server handshake block.
// Wire format: unpad(block) -> (versionRange, sessionId, certChainPubKey, sigBytes)
//   where certChainPubKey = (NonEmpty Large certChain, Large signedKey)
//         sigBytes = ByteString (1-byte len prefix, empty for Nothing)
// Trailing bytes (Tail) are ignored for forward compatibility.
export function decodeServerHandshake(block: Uint8Array): XFTPServerHandshake {
  console.log('[DEBUG decodeServerHandshake] block.length=%d', block.length)
  const raw = blockUnpad(block)
  console.log('[DEBUG decodeServerHandshake] unpadded.length=%d content=%s', raw.length, String.fromCharCode(...raw.subarray(0, Math.min(40, raw.length))))
  // Detect error responses (server sends padded error string like "HANDSHAKE")
  if (raw.length < 20) {
    const text = String.fromCharCode(...raw)
    if (/^[A-Z_]+$/.test(text)) {
      throw new Error("server handshake error: " + text)
    }
  }
  const d = new Decoder(raw)
  const xftpVersionRange = decodeVersionRange(d)
  console.log('[DEBUG decodeServerHandshake] versionRange=%o offset=%d', xftpVersionRange, d.offset())
  const sessionId = decodeBytes(d)
  console.log('[DEBUG decodeServerHandshake] sessionId.length=%d offset=%d', sessionId.length, d.offset())
  // CertChainPubKey: smpEncode (encodeCertChain certChain, SignedObject signedPubKey)
  const certChainDer = decodeNonEmpty(decodeLarge, d)
  console.log('[DEBUG decodeServerHandshake] certChain.length=%d offset=%d', certChainDer.length, d.offset())
  const signedKeyDer = decodeLarge(d)
  console.log('[DEBUG decodeServerHandshake] signedKey.length=%d offset=%d remaining=%d', signedKeyDer.length, d.offset(), d.remaining())
  // webIdentityProof: 1-byte length-prefixed ByteString (empty = Nothing)
  let webIdentityProof: Uint8Array | null = null
  if (d.remaining() > 0) {
    const sigBytes = decodeBytes(d)
    console.log('[DEBUG decodeServerHandshake] webProof.length=%d', sigBytes.length)
    webIdentityProof = sigBytes.length === 0 ? null : sigBytes
  } else {
    console.log('[DEBUG decodeServerHandshake] no webIdentityProof (remaining=0)')
  }
  // Remaining bytes are Tail (ignored for forward compatibility)
  return {xftpVersionRange, sessionId, certChainDer, signedKeyDer, webIdentityProof}
}

// -- Certificate utilities

// Certificate chain decomposition matching Haskell chainIdCaCerts (Transport.Shared).
export type ChainCertificates =
  | {type: 'empty'}
  | {type: 'self'; cert: Uint8Array}
  | {type: 'valid'; leafCert: Uint8Array; idCert: Uint8Array; caCert: Uint8Array}
  | {type: 'long'}

export function chainIdCaCerts(certChainDer: Uint8Array[]): ChainCertificates {
  switch (certChainDer.length) {
    case 0: return {type: 'empty'}
    case 1: return {type: 'self', cert: certChainDer[0]}
    case 2: return {type: 'valid', leafCert: certChainDer[0], idCert: certChainDer[1], caCert: certChainDer[1]}
    case 3: return {type: 'valid', leafCert: certChainDer[0], idCert: certChainDer[1], caCert: certChainDer[2]}
    case 4: return {type: 'valid', leafCert: certChainDer[0], idCert: certChainDer[1], caCert: certChainDer[3]}
    default: return {type: 'long'}
  }
}

// SHA-256 fingerprint of the identity certificate.
// For 2-cert chains: idCert = last cert (same as CA).
// For 3+ cert chains: idCert = second cert (distinct from CA).
// Matches Haskell: getFingerprint idCert HashSHA256
export function caFingerprint(certChainDer: Uint8Array[]): Uint8Array {
  const cc = chainIdCaCerts(certChainDer)
  if (cc.type !== 'valid') throw new Error("caFingerprint: need valid chain (2-4 certs)")
  return sha256(cc.idCert)
}

// -- SignedExact DER parsing

// Parsed components of an X.509 SignedExact structure.
export interface SignedKey {
  objectDer: Uint8Array   // raw DER of the signed object (SubjectPublicKeyInfo)
  dhKey: Uint8Array       // extracted 32-byte X25519 public key
  algorithm: Uint8Array   // AlgorithmIdentifier DER bytes
  signature: Uint8Array   // raw signature bytes (Ed25519: 64, Ed448: 114)
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
//     SubjectPublicKeyInfo (SEQUENCE)  -- the signed object
//     AlgorithmIdentifier  (SEQUENCE)  -- signature algorithm
//     BIT STRING                       -- signature
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

  // Extract X25519 key from the signed object.
  // objectDer may be the raw SPKI (44 bytes) or a wrapper SEQUENCE
  // from x509 objectToSignedExact which wraps toASN1 in Start Sequence.
  const dhKey = decodeX25519Key(objectDer)

  return {objectDer, dhKey, algorithm, signature}
}

// Extract X25519 raw public key from either direct SPKI (44 bytes)
// or a wrapper SEQUENCE containing the SPKI.
function decodeX25519Key(der: Uint8Array): Uint8Array {
  if (der.length === 44) return decodePubKeyX25519(der)
  if (der[0] !== 0x30) throw new Error("decodeX25519Key: expected SEQUENCE")
  const d = new Decoder(der)
  d.anyByte()
  derLength(d)
  const inner = derElement(d)
  return decodePubKeyX25519(inner)
}
