// Double ratchet REPL for cross-language testing.
// Holds one ratchet state, reads commands from stdin, writes results to stdout.
//
// Init protocol:
//   INIT_RCV <version> <pqSupport 0|1>
//     → ok: <hex E2E params>
//   COMPLETE <hex peer E2E params>
//     → ok
//   INIT_SND <version> <kemMode> <hex peer E2E params>
//     → ok: <hex E2E params>
//     kemMode: none | propose | accept
//
// Encrypt/decrypt operators (same syntax as Haskell DoubleRatchetTests):
//   \#> <plaintext>       encrypt, assert noSndKEM
//   !#> <plaintext>       encrypt, assert hasSndKEM
//   \#>! <plaintext>      encrypt PQEncOn, assert noSndKEM
//   !#>! <plaintext>      encrypt PQEncOn, assert hasSndKEM
//   !#>\ <plaintext>      encrypt PQEncOff, assert hasSndKEM
//   \#>\ <plaintext>      encrypt PQEncOff, assert noSndKEM
//   <#\ <hex ct> <expected>   decrypt, assert noRcvKEM
//   <#! <hex ct> <expected>   decrypt, assert hasRcvKEM
//
// Plain encrypt/decrypt (no assertions):
//   E <plaintext>         → ok: <hex ciphertext>
//   D <hex ciphertext>    → ok: <plaintext>
//
// Response format: ok: <data> or error: <message>

import {createInterface} from "readline"
import {
  generateX448KeyPair, pqX3dhSnd, pqX3dhRcv,
  encodePubKeyX448, decodePubKeyX448,
  initSndRatchet, initRcvRatchet,
  rcEncrypt, rcDecrypt,
  rootKdf,
  type Ratchet, type SkippedMsgKeys, type RatchetVersions,
  type RatchetInitParams, type RatchetKEMAccepted,
} from "../dist/crypto/ratchet.js"
import {initSntrup761, sntrup761Keypair, sntrup761Enc, sntrup761Dec} from "../dist/crypto/sntrup761.js"
import type {KEMKeyPair} from "../dist/crypto/sntrup761.js"
import {
  Decoder, decodeBytes, decodeLarge, encodeBytes, encodeWord16, concatBytes,
} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"

// -- State

let ratchet: Ratchet | null = null
let skippedKeys: SkippedMsgKeys = new Map()
const PADDED_MSG_LEN = 16000

// Intermediate state for RCV init (between INIT_RCV and COMPLETE)
let rcvInitState: {
  privKey1: Uint8Array
  privKey2: Uint8Array
  kemKeyPair: KEMKeyPair | null
  pqSupport: boolean
} | null = null

// -- Hex helpers

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("")
}

function fromHex(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2)
  for (let i = 0; i < hex.length; i += 2)
    bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16)
  return bytes
}

// -- E2E params helpers

// Parse E2ERatchetParams: version(Word16) + pk1(ByteString) + pk2(ByteString) + Maybe KEMParams
interface ParsedE2EParams {
  version: number
  pk1Raw: Uint8Array  // raw X448 public key
  pk2Raw: Uint8Array  // raw X448 public key
  kemPk: Uint8Array | null  // KEM public key if proposed
  kemCt: Uint8Array | null  // KEM ciphertext if accepted
  kemAcceptPk: Uint8Array | null  // KEM public key in accepted
}

function parseE2EParams(data: Uint8Array): ParsedE2EParams {
  const d = new Decoder(data)
  const version = d.anyByte() * 256 + d.anyByte()
  const pk1Raw = decodePubKeyX448(decodeBytes(d))
  const pk2Raw = decodePubKeyX448(decodeBytes(d))
  let kemPk: Uint8Array | null = null
  let kemCt: Uint8Array | null = null
  let kemAcceptPk: Uint8Array | null = null
  if (version >= 3 && d.remaining() > 0) {
    const maybeByte = d.anyByte()
    if (maybeByte === 0x31) { // Just
      const tag = d.anyByte()
      if (tag === 0x50) { // 'P' Proposed
        kemPk = decodeLarge(d)
      } else if (tag === 0x41) { // 'A' Accepted
        kemCt = decodeLarge(d)
        kemAcceptPk = decodeLarge(d)
      }
    }
  }
  return {version, pk1Raw, pk2Raw, kemPk, kemCt, kemAcceptPk}
}

// Encode E2ERatchetParams for sending to peer
function encodeE2EParams(
  version: number,
  pk1Raw: Uint8Array, pk2Raw: Uint8Array,
  kemPk: Uint8Array | null,  // for proposed
  kemCt: Uint8Array | null,  // for accepted
  kemAcceptPk: Uint8Array | null,  // public key in accepted
): Uint8Array {
  const vBytes = new Uint8Array(2)
  vBytes[0] = (version >> 8) & 0xff
  vBytes[1] = version & 0xff
  const parts = [vBytes, encodeBytes(encodePubKeyX448(pk1Raw)), encodeBytes(encodePubKeyX448(pk2Raw))]
  if (version >= 3) {
    if (kemCt && kemAcceptPk) {
      // Just Accepted
      parts.push(new Uint8Array([0x31, 0x41])) // Just + 'A'
      parts.push(new Uint8Array([(kemCt.length >> 8) & 0xff, kemCt.length & 0xff]))
      parts.push(kemCt)
      parts.push(new Uint8Array([(kemAcceptPk.length >> 8) & 0xff, kemAcceptPk.length & 0xff]))
      parts.push(kemAcceptPk)
    } else if (kemPk) {
      // Just Proposed
      parts.push(new Uint8Array([0x31, 0x50])) // Just + 'P'
      parts.push(new Uint8Array([(kemPk.length >> 8) & 0xff, kemPk.length & 0xff]))
      parts.push(kemPk)
    } else {
      // Nothing
      parts.push(new Uint8Array([0x30]))
    }
  }
  return concatBytes(...parts)
}

// -- Init handlers

function handleInitRcv(version: number, pqSupport: boolean): string {
  const kp1 = generateX448KeyPair()
  const kp2 = generateX448KeyPair()
  let kemKeyPair: KEMKeyPair | null = null
  let kemPk: Uint8Array | null = null
  if (pqSupport) {
    kemKeyPair = sntrup761Keypair()
    kemPk = kemKeyPair.publicKey
  }
  rcvInitState = {privKey1: kp1.privateKey, privKey2: kp2.privateKey, kemKeyPair, pqSupport}
  const params = encodeE2EParams(version, kp1.publicKey, kp2.publicKey, kemPk, null, null)
  return "ok: " + toHex(params)
}

function handleComplete(peerParamsHex: string): string {
  if (!rcvInitState) return "error: not in RCV init state"
  const {privKey1, privKey2, kemKeyPair, pqSupport} = rcvInitState
  const peerParams = parseE2EParams(fromHex(peerParamsHex))

  // Build kemAccepted for X3DH if peer accepted our KEM proposal
  let kemAccepted: RatchetKEMAccepted | null = null
  if (peerParams.kemCt && peerParams.kemAcceptPk && kemKeyPair) {
    const ss = sntrup761Dec(peerParams.kemCt, kemKeyPair.secretKey)
    kemAccepted = {rcPQRr: peerParams.kemAcceptPk, rcPQRss: ss, rcPQRct: peerParams.kemCt}
  }

  // X3DH (receiver side)
  const initParams = pqX3dhRcv(privKey1, privKey2, peerParams.pk1Raw, peerParams.pk2Raw, kemAccepted)

  // Init receiving ratchet
  const vs: RatchetVersions = {current: peerParams.version, maxSupported: peerParams.version}
  ratchet = initRcvRatchet(vs, privKey2, initParams, kemKeyPair, pqSupport)
  skippedKeys = new Map()
  rcvInitState = null
  return "ok"
}

function handleInitSnd(version: number, kemMode: string, peerParamsHex: string): string {
  const peerParams = parseE2EParams(fromHex(peerParamsHex))

  const kp1 = generateX448KeyPair()
  const kp2 = generateX448KeyPair()
  const kp3 = generateX448KeyPair() // fresh DH key for ratchet

  // KEM handling
  let kemAccepted: RatchetKEMAccepted | null = null
  let ownKemKp: KEMKeyPair | null = null
  let outKemPk: Uint8Array | null = null
  let outKemCt: Uint8Array | null = null
  let outKemAcceptPk: Uint8Array | null = null

  if (kemMode === "accept" && peerParams.kemPk) {
    // Accept peer's KEM proposal
    const encResult = sntrup761Enc(peerParams.kemPk)
    ownKemKp = sntrup761Keypair()
    kemAccepted = {rcPQRr: peerParams.kemPk, rcPQRss: encResult.sharedSecret, rcPQRct: encResult.ciphertext}
    outKemCt = encResult.ciphertext
    outKemAcceptPk = ownKemKp.publicKey
  } else if (kemMode === "propose") {
    ownKemKp = sntrup761Keypair()
    outKemPk = ownKemKp.publicKey
  }

  // X3DH (sender side)
  const initParams = pqX3dhSnd(kp1.privateKey, kp2.privateKey, peerParams.pk1Raw, peerParams.pk2Raw, kemAccepted)

  // Init sending ratchet
  const vs: RatchetVersions = {current: version, maxSupported: version}
  ratchet = initSndRatchet(vs, peerParams.pk2Raw, kp3.privateKey, initParams, ownKemKp)
  skippedKeys = new Map()

  const params = encodeE2EParams(version, kp1.publicKey, kp2.publicKey, outKemPk, outKemCt, outKemAcceptPk)
  return "ok: " + toHex(params)
}

// -- Encrypt/decrypt handlers

function handleEncrypt(kemAssert: boolean | null, _pqPref: boolean | null, plaintext: string): string {
  if (!ratchet) return "error: not initialized"
  try {
    const result = rcEncrypt(ratchet, new TextEncoder().encode(plaintext), PADDED_MSG_LEN)
    ratchet = result.state
    if (kemAssert === true && !ratchet.rcSndKEM) return "error: expected hasSndKEM"
    if (kemAssert === false && ratchet.rcSndKEM) return "error: expected noSndKEM"
    return "ok: " + toHex(result.ciphertext)
  } catch (e: any) {
    return "error: " + e.message
  }
}

function handleDecrypt(kemAssert: boolean | null, hexCt: string, expectedPlaintext: string | null): string {
  if (!ratchet) return "error: not initialized"
  try {
    const ct = fromHex(hexCt)
    const result = rcDecrypt(ratchet, skippedKeys, ct)
    ratchet = result.state
    skippedKeys = result.skippedKeys
    const plaintext = new TextDecoder().decode(result.plaintext)
    if (kemAssert === true && !ratchet.rcRcvKEM) return "error: expected hasRcvKEM"
    if (kemAssert === false && ratchet.rcRcvKEM) return "error: expected noRcvKEM"
    if (expectedPlaintext !== null && plaintext !== expectedPlaintext)
      return "error: expected '" + expectedPlaintext + "', got '" + plaintext + "'"
    return "ok: " + plaintext
  } catch (e: any) {
    return "error: " + e.message
  }
}

// -- Command parser

function parseLine(line: string): string {
  // Init commands
  if (line.startsWith("INIT_RCV ")) {
    const parts = line.split(" ")
    return handleInitRcv(parseInt(parts[1]), parts[2] === "1")
  }
  if (line.startsWith("COMPLETE ")) {
    return handleComplete(line.substring(9).trim())
  }
  if (line.startsWith("INIT_SND ")) {
    const parts = line.split(" ")
    return handleInitSnd(parseInt(parts[1]), parts[2], parts[3])
  }

  // Query commands
  if (line === "SNDKEM") {
    if (!ratchet) return "error: not initialized"
    return "ok: " + (ratchet.rcSndKEM ? "1" : "0")
  }
  if (line === "RCVKEM") {
    if (!ratchet) return "error: not initialized"
    return "ok: " + (ratchet.rcRcvKEM ? "1" : "0")
  }

  // Encrypt operators: \#> !#> \#>! !#>! !#>\ \#>\
  const encMatch = line.match(/^([!\\])#(>[!\\]?)\s+(.+)$/)
  if (encMatch) {
    const [, kemChar, arrow, msg] = encMatch
    const kemAssert = kemChar === "!" ? true : false
    let pqPref: boolean | null = null
    if (arrow === ">!") pqPref = true
    else if (arrow === ">\\") pqPref = false
    return handleEncrypt(kemAssert, pqPref, msg)
  }

  // Decrypt operators: <#\ <#!
  const decMatch = line.match(/^<#([!\\])\s+(\S+)\s+(.+)$/)
  if (decMatch) {
    const [, kemChar, hexCt, expected] = decMatch
    const kemAssert = kemChar === "!" ? true : false
    return handleDecrypt(kemAssert, hexCt, expected)
  }

  // Plain encrypt (no assertion)
  if (line.startsWith("E ")) {
    return handleEncrypt(null, null, line.substring(2))
  }

  // Plain decrypt (no assertion, no expected)
  if (line.startsWith("D ")) {
    return handleDecrypt(null, line.substring(2), null)
  }

  return "error: unknown command: " + line
}

// -- Main

async function main() {
  await initSntrup761()

  const rl = createInterface({input: process.stdin, terminal: false})

  for await (const line of rl) {
    const trimmed = line.trim()
    if (!trimmed) continue
    const response = parseLine(trimmed)
    process.stdout.write(response + "\n")
  }
}

main().catch(e => {
  process.stderr.write("FATAL: " + e.message + "\n")
  process.exit(1)
})
