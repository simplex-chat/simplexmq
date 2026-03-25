// SMP handshake encoding/decoding and server identity verification.
//
// Adapts patterns from xftp-web/protocol/handshake.ts for SMP protocol.
// Functions that would pull libsodium through xftp-web's import chain
// are inlined here. Crypto uses @noble/hashes and @noble/curves per CLAUDE.md.
//
// SMP handshake flow:
// 1. Server sends ServerHello (16KB block): version range, sessionId, certs, signed DH key
// 2. Client verifies server identity via certificate fingerprint
// 3. Client sends ClientHello (16KB block): negotiated version, key hash
// 4. Session established, transport ready for commands

import {
  Decoder, concatBytes,
  encodeWord16, decodeWord16,
  encodeBytes, decodeBytes,
  decodeLarge, decodeNonEmpty,
  encodeLarge,
} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"
import {sha256} from "@noble/hashes/sha256"
import {ed25519} from "@noble/curves/ed25519.js"
import {ed448} from "@noble/curves/ed448.js"
import {SMPTransportError} from "./types.js"
import {SMP_BLOCK_SIZE} from "./transport.js"

// -- SMP version constants

export const minSMPClientVersion = 6
export const maxSMPClientVersion = 7

export const smpClientVersionRange: VersionRange = {
  minVersion: minSMPClientVersion,
  maxVersion: maxSMPClientVersion,
}

// -- Version range (inlined from xftp-web/handshake.ts to avoid libsodium chain)

export interface VersionRange {
  minVersion: number // Word16
  maxVersion: number // Word16
}

export function encodeVersionRange(vr: VersionRange): Uint8Array {
  return concatBytes(encodeWord16(vr.minVersion), encodeWord16(vr.maxVersion))
}

export function decodeVersionRange(d: Decoder): VersionRange {
  const minVersion = decodeWord16(d)
  const maxVersion = decodeWord16(d)
  if (minVersion > maxVersion) throw new Error("invalid version range: min > max")
  return {minVersion, maxVersion}
}

export function compatibleVRange(a: VersionRange, b: VersionRange): VersionRange | null {
  const min = Math.max(a.minVersion, b.minVersion)
  const max = Math.min(a.maxVersion, b.maxVersion)
  if (min > max) return null
  return {minVersion: min, maxVersion: max}
}

// -- Block padding (inlined from xftp-web/transmission.ts to avoid libsodium chain)
// Same 16KB block format with '#' (0x23) padding used by both SMP and XFTP.

export function blockPad(msg: Uint8Array, blockSize: number = SMP_BLOCK_SIZE): Uint8Array {
  const len = msg.length
  const padLen = blockSize - len - 2
  if (padLen < 0) throw new Error("blockPad: message too large for block")
  const result = new Uint8Array(blockSize)
  result[0] = (len >>> 8) & 0xff
  result[1] = len & 0xff
  result.set(msg, 2)
  result.fill(0x23, 2 + len) // '#' padding
  return result
}

export function blockUnpad(block: Uint8Array): Uint8Array {
  if (block.length < 2) throw new Error("blockUnpad: too short")
  const len = (block[0] << 8) | block[1]
  if (2 + len > block.length) throw new Error("blockUnpad: invalid length")
  return block.subarray(2, 2 + len)
}

// -- SMP ServerHello

export interface SMPServerHandshake {
  smpVersionRange: VersionRange
  sessionId: Uint8Array
  certChainDer: Uint8Array[] // NonEmpty list of DER certificate blobs
  signedKeyDer: Uint8Array   // signed X25519 DH public key (DER)
}

// Decode ServerHello from a 16KB padded block.
// Wire format: unpad(block) -> (versionRange, sessionId, NonEmpty Large certs, Large signedKey)
// Detects server error responses (short blocks with ASCII like "HANDSHAKE" or "SESSION").
export function decodeSMPServerHandshake(block: Uint8Array): SMPServerHandshake {
  const raw = blockUnpad(block)
  // Detect error responses (server sends padded error string)
  if (raw.length < 20) {
    const text = String.fromCharCode(...raw)
    if (/^[A-Z_]+$/.test(text)) {
      throw new SMPTransportError("HANDSHAKE", "Server handshake error: " + text)
    }
  }
  const d = new Decoder(raw)
  const smpVersionRange = decodeVersionRange(d)
  const sessionId = decodeBytes(d)
  // CertChainPubKey: NonEmpty Large (cert chain), Large (signed key)
  const certChainDer = decodeNonEmpty(decodeLarge, d)
  const signedKeyDer = decodeLarge(d)
  // Remaining bytes are ignored for forward compatibility
  return {smpVersionRange, sessionId, certChainDer, signedKeyDer}
}

// -- SMP ClientHello

export interface SMPClientHandshake {
  smpVersion: number    // negotiated version (6 or 7)
  keyHash: Uint8Array   // SHA-256 fingerprint of server CA cert (32 bytes)
}

// Encode ClientHello as a 16KB padded block.
// Wire format: pad(Word16(version) + shortString(keyHash), 16384)
export function encodeSMPClientHandshake(ch: SMPClientHandshake): Uint8Array {
  const body = concatBytes(encodeWord16(ch.smpVersion), encodeBytes(ch.keyHash))
  return blockPad(body)
}

// -- Certificate chain utilities (inlined from xftp-web/handshake.ts)

// Certificate chain decomposition matching Haskell chainIdCaCerts.
// Returns leaf cert (for signature verification) and identity cert (for fingerprinting).
// Valid chains have 2-4 certificates.
export function chainIdCaCerts(
  certChainDer: Uint8Array[]
): {leafCert: Uint8Array; idCert: Uint8Array} | null {
  switch (certChainDer.length) {
    case 2:
      return {leafCert: certChainDer[0], idCert: certChainDer[1]}
    case 3:
      return {leafCert: certChainDer[0], idCert: certChainDer[1]}
    case 4:
      return {leafCert: certChainDer[0], idCert: certChainDer[1]}
    default:
      return null
  }
}

// SHA-256 fingerprint of the identity certificate.
// Uses @noble/hashes (per CLAUDE.md: never libsodium, never Web Crypto API).
export function caFingerprint(certChainDer: Uint8Array[]): Uint8Array {
  const cc = chainIdCaCerts(certChainDer)
  if (cc === null) {
    throw new SMPTransportError("IDENTITY", "Invalid certificate chain (need 2-4 certs)")
  }
  return sha256(cc.idCert)
}

// -- ASN.1 DER parsing helpers

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

function derElement(d: Decoder): Uint8Array {
  const start = d.offset()
  d.anyByte() // tag
  const len = derLength(d)
  d.take(len) // value
  return d.buf.subarray(start, d.offset())
}

function derSkip(d: Decoder): void {
  d.anyByte()
  d.take(derLength(d))
}

// -- SignedExact DER parsing (inlined from xftp-web/handshake.ts)
// Extracts the signed object, algorithm, and signature from a SignedExact structure.
// Does NOT extract the raw X25519 key (avoids libsodium dependency).

export interface SignedKey {
  objectDer: Uint8Array  // raw DER of the signed object (SubjectPublicKeyInfo)
  algorithm: Uint8Array  // AlgorithmIdentifier DER bytes
  signature: Uint8Array  // raw signature bytes (Ed25519: 64, Ed448: 114)
}

export function extractSignedKey(signedDer: Uint8Array): SignedKey {
  const outer = new Decoder(signedDer)
  const outerTag = outer.anyByte()
  if (outerTag !== 0x30) {
    throw new Error("SignedExact: expected SEQUENCE tag 0x30, got 0x" + outerTag.toString(16))
  }
  derLength(outer) // consume total content length

  // First element: SubjectPublicKeyInfo (the signed object)
  const objectDer = derElement(outer)

  // Second element: AlgorithmIdentifier
  const algorithm = derElement(outer)

  // Third element: BIT STRING (signature)
  const sigTag = outer.anyByte()
  if (sigTag !== 0x03) {
    throw new Error("SignedExact: expected BIT STRING tag 0x03, got 0x" + sigTag.toString(16))
  }
  const sigLen = derLength(outer)
  const unusedBits = outer.anyByte()
  if (unusedBits !== 0) throw new Error("SignedExact: expected 0 unused bits in signature")
  const signature = outer.take(sigLen - 1)

  return {objectDer, algorithm, signature}
}

// -- X.509 certificate public key extraction (inlined from xftp-web/identity.ts)

// Extract SubjectPublicKeyInfo DER from a full X.509 certificate DER.
// Navigates: Certificate -> TBSCertificate -> skip fields -> SubjectPublicKeyInfo
export function extractCertPublicKeyInfo(certDer: Uint8Array): Uint8Array {
  const d = new Decoder(certDer)
  if (d.anyByte() !== 0x30) throw new Error("X.509: expected Certificate SEQUENCE")
  derLength(d)
  if (d.anyByte() !== 0x30) throw new Error("X.509: expected TBSCertificate SEQUENCE")
  derLength(d)
  if (d.buf[d.offset()] === 0xa0) derSkip(d) // version [0] EXPLICIT (optional)
  derSkip(d) // serialNumber
  derSkip(d) // signature AlgorithmIdentifier
  derSkip(d) // issuer
  derSkip(d) // validity
  derSkip(d) // subject
  return derElement(d) // SubjectPublicKeyInfo
}

// Detect key algorithm from SPKI DER prefix.
// Ed25519 OID 1.3.101.112: byte 8 = 0x70, SPKI = 44 bytes
// Ed448 OID 1.3.101.113: byte 8 = 0x71, SPKI = 69 bytes
type CertKeyAlgorithm = "ed25519" | "ed448"

function detectKeyAlgorithm(spki: Uint8Array): CertKeyAlgorithm {
  if (spki.length === 44 && spki[8] === 0x70) return "ed25519"
  if (spki.length === 69 && spki[8] === 0x71) return "ed448"
  throw new Error("Unsupported certificate key algorithm (SPKI length=" + spki.length + ")")
}

// Extract raw public key bytes from SPKI DER.
// Ed25519: 32 bytes at offset 12 (after fixed SPKI prefix)
// Ed448: 57 bytes at offset 12
function extractRawPubKey(spki: Uint8Array): Uint8Array {
  const alg = detectKeyAlgorithm(spki)
  if (alg === "ed25519") return spki.subarray(12, 44)
  // Ed448: SPKI = 30 43 30 05 06 03 2b 65 71 03 3a 00 [57 bytes]
  return spki.subarray(12, 69)
}

// Verify signature using the correct curve based on SPKI key algorithm.
function verifySignature(spki: Uint8Array, signature: Uint8Array, message: Uint8Array): boolean {
  const alg = detectKeyAlgorithm(spki)
  const key = extractRawPubKey(spki)
  if (alg === "ed25519") {
    return ed25519.verify(signature, message, key)
  }
  return ed448.verify(signature, message, key)
}

// -- Constant-time comparison

export function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i]
  return diff === 0
}

// -- Server identity verification (combines fingerprint check + DH key signature)

// Verify SMP server identity from the ServerHello handshake.
// 1. Certificate chain has valid structure (2-4 certs)
// 2. SHA-256(idCert) matches expected keyHash (constant-time comparison)
// 3. Signed DH key signature is valid against the leaf certificate
//
// Unlike XFTP, SMP does not have a web identity proof (challenge/response).
// Server identity is verified through the certificate fingerprint and DH key signature.
export function verifyServerIdentity(
  serverHello: SMPServerHandshake,
  expectedKeyHash: Uint8Array
): void {
  // a. Compute certificate fingerprint
  const fingerprint = caFingerprint(serverHello.certChainDer)

  // b. Compare with expected key hash (constant-time)
  if (!constantTimeEqual(fingerprint, expectedKeyHash)) {
    throw new SMPTransportError("IDENTITY", "Server certificate fingerprint mismatch")
  }

  // c. Extract signed DH key components
  const signedKey = extractSignedKey(serverHello.signedKeyDer)

  // d. Verify DH key signature against leaf certificate
  const certs = chainIdCaCerts(serverHello.certChainDer)
  if (certs === null) {
    throw new SMPTransportError("IDENTITY", "Invalid certificate chain")
  }
  const leafSpki = extractCertPublicKeyInfo(certs.leafCert)
  const valid = verifySignature(leafSpki, signedKey.signature, signedKey.objectDer)
  if (!valid) {
    throw new SMPTransportError("IDENTITY", "Server DH key signature verification failed")
  }
}

// -- Command block building utilities (used by client.ts)

// Build a 16KB padded command block from transmission components.
// Format: blockPad([count=1] + encodeLarge(transmission))
export function buildCommandBlock(transmission: Uint8Array): Uint8Array {
  const batch = concatBytes(new Uint8Array([1]), encodeLarge(transmission))
  return blockPad(batch)
}

// Parse a 16KB response block into raw transmission bytes.
// Format: blockUnpad -> [count] + decodeLarge(transmission)
export function parseResponseBlock(block: Uint8Array): Uint8Array {
  const raw = blockUnpad(block)
  const d = new Decoder(raw)
  const count = d.anyByte()
  if (count < 1) throw new Error("Empty batch (count=0)")
  // Read first transmission (we only process one per block)
  return decodeLarge(d)
}
