// File-level encryption/decryption matching Simplex.FileTransfer.Crypto.
// Operates on in-memory Uint8Array (no file I/O needed for browser).

import {Decoder, concatBytes, encodeInt64, encodeString, decodeString, encodeMaybe, decodeMaybe} from "../protocol/encoding.js"
import {sbInit, sbEncryptChunk, sbDecryptChunk, sbDecryptTailTag, sbAuth} from "./secretbox.js"
import {unPadLazy} from "./padding.js"

const AUTH_TAG_SIZE = 16n
const PROGRESS_SEG = 256 * 1024

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
  encSize: bigint,
  onProgress?: (done: number, total: number) => void
): Uint8Array {
  const state = sbInit(key, nonce)
  const lenStr = encodeInt64(fileSize)
  const padLen = Number(encSize - AUTH_TAG_SIZE - fileSize - 8n)
  if (padLen < 0) throw new Error("encryptFile: encSize too small")
  const hdr = sbEncryptChunk(state, concatBytes(lenStr, fileHdr))
  // Process source in segments for progress reporting.
  // sbEncryptChunk is streaming — segments produce identical output to a single call.
  const encSource = new Uint8Array(source.length)
  for (let off = 0; off < source.length; off += PROGRESS_SEG) {
    const end = Math.min(off + PROGRESS_SEG, source.length)
    const seg = sbEncryptChunk(state, source.subarray(off, end))
    encSource.set(seg, off)
    onProgress?.(end, source.length)
  }
  if (source.length === 0) onProgress?.(0, 0)
  const padding = new Uint8Array(padLen)
  padding.fill(0x23) // '#'
  const encPad = sbEncryptChunk(state, padding)
  const tag = sbAuth(state)
  return concatBytes(hdr, encSource, encPad, tag)
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
  nonce: Uint8Array,
  onProgress?: (done: number, total: number) => void
): {header: FileHeader, content: Uint8Array} {
  if (chunks.length === 0) throw new Error("decryptChunks: empty chunks")
  const paddedLen = encSize - AUTH_TAG_SIZE
  const data = chunks.length === 1 ? chunks[0] : concatBytes(...chunks)
  if (!onProgress) {
    const {valid, content} = sbDecryptTailTag(key, nonce, paddedLen, data)
    if (!valid) throw new Error("decryptChunks: invalid auth tag")
    const {header, rest} = parseFileHeader(content)
    return {header, content: rest}
  }
  // Segmented decrypt for progress reporting.
  // sbDecryptChunk is streaming — segments produce identical output to a single call.
  const pLen = Number(paddedLen)
  const cipher = data.subarray(0, pLen)
  const providedTag = data.subarray(pLen)
  const state = sbInit(key, nonce)
  const plaintext = new Uint8Array(pLen)
  for (let off = 0; off < pLen; off += PROGRESS_SEG) {
    const end = Math.min(off + PROGRESS_SEG, pLen)
    const seg = sbDecryptChunk(state, cipher.subarray(off, end))
    plaintext.set(seg, off)
    onProgress(end, pLen)
  }
  if (pLen === 0) onProgress(0, 0)
  const computedTag = sbAuth(state)
  let diff = providedTag.length === 16 ? 0 : 1
  for (let i = 0; i < computedTag.length; i++) diff |= providedTag[i] ^ computedTag[i]
  if (diff !== 0) throw new Error("decryptChunks: invalid auth tag")
  const content = unPadLazy(plaintext)
  const {header, rest} = parseFileHeader(content)
  return {header, content: rest}
}
