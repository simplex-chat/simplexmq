// File-level encryption/decryption matching Simplex.FileTransfer.Crypto.
// Operates on in-memory Uint8Array (no file I/O needed for browser).

import {Decoder, concatBytes, encodeInt64, encodeString, decodeString, encodeMaybe, decodeMaybe} from "../protocol/encoding.js"
import {sbInit, sbEncryptChunk, sbDecryptTailTag, sbAuth} from "./secretbox.js"

const AUTH_TAG_SIZE = 16n

// -- FileHeader

export interface FileHeader {
  fileName: string
  fileExtra: string | null
}

// Encoding matches Haskell: smpEncode (fileName, fileExtra)
//   = smpEncode fileName <> smpEncode fileExtra
//   = encodeString(fileName) + encodeMaybe(encodeString, fileExtra)
export function encodeFileHeader(hdr: FileHeader): Uint8Array {
  return concatBytes(
    encodeString(hdr.fileName),
    encodeMaybe(encodeString, hdr.fileExtra)
  )
}

// Parse FileHeader from decrypted content (first 1024 bytes examined).
// Returns the parsed header and remaining bytes (file content).
export function parseFileHeader(data: Uint8Array): {header: FileHeader, rest: Uint8Array} {
  const hdrLen = Math.min(1024, data.length)
  const d = new Decoder(data.subarray(0, hdrLen))
  const fileName = decodeString(d)
  const fileExtra = decodeMaybe(decodeString, d)
  const consumed = d.offset()
  return {
    header: {fileName, fileExtra},
    rest: data.subarray(consumed)
  }
}

// -- Encryption (FileTransfer.Crypto:encryptFile)

// Encrypt file content with streaming XSalsa20-Poly1305.
// Output format: encrypted(Int64 fileSize | fileHdr | source | '#' padding) | 16-byte auth tag
//
//   source   -- raw file content
//   fileHdr  -- pre-encoded FileHeader bytes (from encodeFileHeader)
//   key      -- 32-byte symmetric key
//   nonce    -- 24-byte nonce
//   fileSize -- BigInt(fileHdr.length + source.length)
//   encSize  -- total output size (including 16-byte auth tag)
export function encryptFile(
  source: Uint8Array,
  fileHdr: Uint8Array,
  key: Uint8Array,
  nonce: Uint8Array,
  fileSize: bigint,
  encSize: bigint
): Uint8Array {
  const state = sbInit(key, nonce)
  const lenStr = encodeInt64(fileSize)
  const padLen = Number(encSize - AUTH_TAG_SIZE - fileSize - 8n)
  if (padLen < 0) throw new Error("encryptFile: encSize too small")
  const hdr = sbEncryptChunk(state, concatBytes(lenStr, fileHdr))
  const encSource = sbEncryptChunk(state, source)
  const padding = new Uint8Array(padLen)
  padding.fill(0x23) // '#'
  const encPad = sbEncryptChunk(state, padding)
  const tag = sbAuth(state)
  return concatBytes(hdr, encSource, encPad, tag)
}

// Async variant: encrypts source in 64KB slices, yielding between each to avoid blocking the main thread.
// Produces identical output to encryptFile.
const ENCRYPT_SLICE = 65536

export async function encryptFileAsync(
  source: Uint8Array,
  fileHdr: Uint8Array,
  key: Uint8Array,
  nonce: Uint8Array,
  fileSize: bigint,
  encSize: bigint,
  onProgress?: (done: number, total: number) => void
): Promise<Uint8Array> {
  const state = sbInit(key, nonce)
  const lenStr = encodeInt64(fileSize)
  const padLen = Number(encSize - AUTH_TAG_SIZE - fileSize - 8n)
  if (padLen < 0) throw new Error("encryptFile: encSize too small")
  const totalOut = Number(encSize)
  const out = new Uint8Array(totalOut)
  let outOff = 0
  // Header (small, no yield needed)
  const hdr = sbEncryptChunk(state, concatBytes(lenStr, fileHdr))
  out.set(hdr, outOff); outOff += hdr.length
  // Source in 64KB slices, yielding between each
  for (let off = 0; off < source.length; off += ENCRYPT_SLICE) {
    const end = Math.min(off + ENCRYPT_SLICE, source.length)
    const enc = sbEncryptChunk(state, source.subarray(off, end))
    out.set(enc, outOff); outOff += enc.length
    onProgress?.(end, source.length)
    await new Promise<void>(r => setTimeout(r, 0))
  }
  // Padding (small, no yield needed)
  const padding = new Uint8Array(padLen)
  padding.fill(0x23)
  const encPad = sbEncryptChunk(state, padding)
  out.set(encPad, outOff); outOff += encPad.length
  // Auth tag
  const tag = sbAuth(state)
  out.set(tag, outOff)
  return out
}

// -- Decryption (FileTransfer.Crypto:decryptChunks)

// Decrypt one or more XFTP chunks into a FileHeader and file content.
// Chunks are concatenated, then decrypted as a single stream.
//
//   encSize -- total encrypted size (including 16-byte auth tag)
//   chunks  -- downloaded XFTP chunk data (concatenated = full encrypted file)
//   key     -- 32-byte symmetric key
//   nonce   -- 24-byte nonce
export function decryptChunks(
  encSize: bigint,
  chunks: Uint8Array[],
  key: Uint8Array,
  nonce: Uint8Array
): {header: FileHeader, content: Uint8Array} {
  if (chunks.length === 0) throw new Error("decryptChunks: empty chunks")
  const paddedLen = encSize - AUTH_TAG_SIZE
  const data = chunks.length === 1 ? chunks[0] : concatBytes(...chunks)
  const {valid, content} = sbDecryptTailTag(key, nonce, paddedLen, data)
  if (!valid) throw new Error("decryptChunks: invalid auth tag")
  const {header, rest} = parseFileHeader(content)
  return {header, content: rest}
}
