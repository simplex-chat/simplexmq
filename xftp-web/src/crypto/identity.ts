// Web handshake identity proof verification.
//
// Verifies server identity in the XFTP web handshake using the certificate
// chain from the protocol handshake (independent of TLS certificates).
// Ed25519 via libsodium, Ed448 via @noble/curves.

import {Decoder, concatBytes} from "../protocol/encoding.js"
import {sha256} from "./digest.js"
import {verify, decodePubKeyEd25519, verifyEd448, decodePubKeyEd448} from "./keys.js"
import {chainIdCaCerts, extractSignedKey} from "../protocol/handshake.js"

// ── ASN.1 DER helpers (minimal, for X.509 parsing) ─────────────────

function derLen(d: Decoder): number {
  const first = d.anyByte()
  if (first < 0x80) return first
  const n = first & 0x7f
  if (n === 0 || n > 4) throw new Error("DER: unsupported length encoding")
  let len = 0
  for (let i = 0; i < n; i++) len = (len << 8) | d.anyByte()
  return len
}

function derSkip(d: Decoder): void {
  d.anyByte()
  d.take(derLen(d))
}

function derReadElement(d: Decoder): Uint8Array {
  const start = d.offset()
  d.anyByte()
  d.take(derLen(d))
  return d.buf.subarray(start, d.offset())
}

// ── X.509 certificate public key extraction ─────────────────────────

// Extract SubjectPublicKeyInfo DER from a full X.509 certificate DER.
// Navigates: Certificate → TBSCertificate → skip version, serialNumber,
//   signatureAlg, issuer, validity, subject → SubjectPublicKeyInfo.
export function extractCertPublicKeyInfo(certDer: Uint8Array): Uint8Array {
  const d = new Decoder(certDer)
  if (d.anyByte() !== 0x30) throw new Error("X.509: expected Certificate SEQUENCE")
  derLen(d)
  if (d.anyByte() !== 0x30) throw new Error("X.509: expected TBSCertificate SEQUENCE")
  derLen(d)
  if (d.buf[d.offset()] === 0xa0) derSkip(d) // version [0] EXPLICIT (optional)
  derSkip(d) // serialNumber
  derSkip(d) // signature AlgorithmIdentifier
  derSkip(d) // issuer
  derSkip(d) // validity
  derSkip(d) // subject
  return derReadElement(d) // SubjectPublicKeyInfo
}

// Detect certificate key algorithm from SPKI DER prefix.
// Ed25519 OID 1.3.101.112: byte 8 = 0x70, SPKI = 44 bytes
// Ed448   OID 1.3.101.113: byte 8 = 0x71, SPKI = 69 bytes
type CertKeyAlgorithm = 'ed25519' | 'ed448'

function detectKeyAlgorithm(spki: Uint8Array): CertKeyAlgorithm {
  if (spki.length === 44 && spki[8] === 0x70) return 'ed25519'
  if (spki.length === 69 && spki[8] === 0x71) return 'ed448'
  throw new Error("unsupported certificate key algorithm")
}

// Extract raw public key from SPKI DER, auto-detecting Ed25519 or Ed448.
function extractCertRawKey(spki: Uint8Array): {key: Uint8Array, alg: CertKeyAlgorithm} {
  const alg = detectKeyAlgorithm(spki)
  const key = alg === 'ed25519' ? decodePubKeyEd25519(spki) : decodePubKeyEd448(spki)
  return {key, alg}
}

// Verify signature using the appropriate algorithm.
function verifySig(alg: CertKeyAlgorithm, key: Uint8Array, sig: Uint8Array, msg: Uint8Array): boolean {
  return alg === 'ed25519' ? verify(key, sig, msg) : verifyEd448(key, sig, msg)
}

// ── Identity proof verification ─────────────────────────────────────

export interface IdentityVerification {
  certChainDer: Uint8Array[]
  signedKeyDer: Uint8Array
  sigBytes: Uint8Array
  challenge: Uint8Array
  sessionId: Uint8Array
  keyHash: Uint8Array
}

// Verify server identity proof from XFTP web handshake.
//   1. Certificate chain has valid structure (2-4 certs)
//   2. SHA-256(idCert) matches expected keyHash
//   3. Challenge signature valid: verify(leafKey, sigBytes, challenge || sessionId)
//   4. DH key signature valid: verify(leafKey, signedKey.signature, signedKey.objectDer)
export function verifyIdentityProof(v: IdentityVerification): boolean {
  const cc = chainIdCaCerts(v.certChainDer)
  if (cc.type !== 'valid') return false
  const fp = sha256(cc.idCert)
  if (!constantTimeEqual(fp, v.keyHash)) return false
  const spki = extractCertPublicKeyInfo(cc.leafCert)
  const {key, alg} = extractCertRawKey(spki)
  if (!verifySig(alg, key, v.sigBytes, concatBytes(v.challenge, v.sessionId))) return false
  const sk = extractSignedKey(v.signedKeyDer)
  return verifySig(alg, key, sk.signature, sk.objectDer)
}

function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i]
  return diff === 0
}
