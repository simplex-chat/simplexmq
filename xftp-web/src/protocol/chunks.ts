// XFTP chunk sizing — Simplex.FileTransfer.Chunks + Client
//
// Computes chunk sizes for file uploads, chunk specifications with offsets,
// and per-chunk SHA-256 digests.

import {kb, mb} from "./description.js"
import {sha256} from "../crypto/digest.js"

// ── Chunk size constants (Simplex.FileTransfer.Chunks) ──────────

export const chunkSize0 = kb(64)   // 65536
export const chunkSize1 = kb(256)  // 262144
export const chunkSize2 = mb(1)    // 1048576
export const chunkSize3 = mb(4)    // 4194304

export const serverChunkSizes = [chunkSize0, chunkSize1, chunkSize2, chunkSize3]

// ── Size constants ──────────────────────────────────────────────

export const fileSizeLen = 8     // 64-bit file size prefix (padLazy)
export const authTagSize = 16   // Poly1305 authentication tag

// ── Chunk sizing (Simplex.FileTransfer.Client.prepareChunkSizes) ─

function size34(sz: number): number {
  return Math.floor((sz * 3) / 4)
}

export function prepareChunkSizes(payloadSize: number): number[] {
  let smallSize: number, bigSize: number
  if (payloadSize > size34(chunkSize3)) {
    smallSize = chunkSize2; bigSize = chunkSize3
  } else if (payloadSize > size34(chunkSize2)) {
    smallSize = chunkSize1; bigSize = chunkSize2
  } else {
    smallSize = chunkSize0; bigSize = chunkSize1
  }
  function prepareSizes(size: number): number[] {
    if (size === 0) return []
    if (size >= bigSize) {
      const n1 = Math.floor(size / bigSize)
      const remSz = size % bigSize
      return new Array<number>(n1).fill(bigSize).concat(prepareSizes(remSz))
    }
    if (size > size34(bigSize)) return [bigSize]
    const n2 = Math.floor(size / smallSize)
    const remSz2 = size % smallSize
    return new Array<number>(remSz2 === 0 ? n2 : n2 + 1).fill(smallSize)
  }
  return prepareSizes(payloadSize)
}

// Find the smallest server chunk size that fits the payload.
// Returns null if payload exceeds the largest chunk size.
// Matches Haskell singleChunkSize.
export function singleChunkSize(payloadSize: number): number | null {
  for (const sz of serverChunkSizes) {
    if (payloadSize <= sz) return sz
  }
  return null
}

// ── Chunk specs ─────────────────────────────────────────────────

export interface ChunkSpec {
  chunkOffset: number
  chunkSize: number
}

// Generate chunk specifications with byte offsets.
// Matches Haskell prepareChunkSpecs (without filePath).
export function prepareChunkSpecs(chunkSizes: number[]): ChunkSpec[] {
  const specs: ChunkSpec[] = []
  let offset = 0
  for (const size of chunkSizes) {
    specs.push({chunkOffset: offset, chunkSize: size})
    offset += size
  }
  return specs
}

// ── Chunk digest ────────────────────────────────────────────────

export function getChunkDigest(chunk: Uint8Array): Uint8Array {
  return sha256(chunk)
}
