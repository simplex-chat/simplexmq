import sodium from 'libsodium-wrappers-sumo'
import {encryptFile, encodeFileHeader, decryptChunks} from '../src/crypto/file.js'
import {sha512Streaming} from '../src/crypto/digest.js'
import {prepareChunkSizes, fileSizeLen, authTagSize} from '../src/protocol/chunks.js'
import {decryptReceivedChunk} from '../src/download.js'

// ── OPFS session management ─────────────────────────────────────

const SESSION_DIR = `session-${Date.now()}-${crypto.randomUUID()}`
let uploadReadHandle: FileSystemSyncAccessHandle | null = null
let downloadWriteHandle: FileSystemSyncAccessHandle | null = null
const chunkMeta = new Map<number, {offset: number, size: number}>()
let currentDownloadOffset = 0
let sessionDir: FileSystemDirectoryHandle | null = null
let useMemory = false
const memoryChunks = new Map<number, Uint8Array>()

async function getSessionDir(): Promise<FileSystemDirectoryHandle> {
  if (!sessionDir) {
    const root = await navigator.storage.getDirectory()
    sessionDir = await root.getDirectoryHandle(SESSION_DIR, {create: true})
  }
  return sessionDir
}

async function sweepStale() {
  const root = await navigator.storage.getDirectory()
  const oneHourAgo = Date.now() - 3600_000
  for await (const [name] of (root as any).entries()) {
    if (!name.startsWith('session-')) continue
    const parts = name.split('-')
    const ts = parseInt(parts[1], 10)
    if (!isNaN(ts) && ts < oneHourAgo) {
      try { await root.removeEntry(name, {recursive: true}) } catch (_) {}
    }
  }
}

// ── Message handlers ────────────────────────────────────────────

async function handleEncrypt(id: number, data: ArrayBuffer, fileName: string) {
  const source = new Uint8Array(data)
  const key = new Uint8Array(32)
  const nonce = new Uint8Array(24)
  crypto.getRandomValues(key)
  crypto.getRandomValues(nonce)
  const fileHdr = encodeFileHeader({fileName, fileExtra: null})
  const fileSize = BigInt(fileHdr.length + source.length)
  const payloadSize = Number(fileSize) + fileSizeLen + authTagSize
  const chunkSizes = prepareChunkSizes(payloadSize)
  const encSize = BigInt(chunkSizes.reduce((a: number, b: number) => a + b, 0))
  const encDataLen = Number(encSize)
  const total = source.length + encDataLen * 2 // encrypt + hash + write

  const encData = encryptFile(source, fileHdr, key, nonce, fileSize, encSize, (done) => {
    self.postMessage({id, type: 'progress', done, total})
  })

  const digest = sha512Streaming([encData], (done) => {
    self.postMessage({id, type: 'progress', done: source.length + done, total})
  }, encDataLen)
  console.log(`[WORKER-DBG] encrypt: encData.len=${encData.length} digest=${_whex(digest, 64)} chunkSizes=[${chunkSizes.join(',')}]`)

  // Write to OPFS
  const dir = await getSessionDir()
  const fileHandle = await dir.getFileHandle('upload.bin', {create: true})
  const writeHandle = await fileHandle.createSyncAccessHandle()
  const written = writeHandle.write(encData)
  if (written !== encData.length) throw new Error(`OPFS upload write: ${written}/${encData.length}`)
  writeHandle.flush()
  writeHandle.close()

  // Reopen as persistent read handle
  uploadReadHandle = await fileHandle.createSyncAccessHandle()

  self.postMessage({id, type: 'progress', done: total, total})
  self.postMessage({id, type: 'encrypted', digest, key, nonce, chunkSizes})
}

function handleReadChunk(id: number, offset: number, size: number) {
  if (!uploadReadHandle) {
    self.postMessage({id, type: 'error', message: 'No upload file open'})
    return
  }
  const buf = new Uint8Array(size)
  uploadReadHandle.read(buf, {at: offset})
  const ab = buf.buffer as ArrayBuffer
  self.postMessage({id, type: 'chunk', data: ab}, [ab])
}

async function handleDecryptAndStore(
  id: number, dhSecret: Uint8Array, nonce: Uint8Array,
  body: ArrayBuffer, chunkDigest: Uint8Array, chunkNo: number
) {
  const bodyArr = new Uint8Array(body)
  console.log(`[WORKER-DBG] store chunk=${chunkNo} body.len=${bodyArr.length} nonce=${_whex(nonce, 24)} dhSecret=${_whex(dhSecret)} digest=${_whex(chunkDigest, 32)} body[0..8]=${_whex(bodyArr)} body[-8..]=${_whex(bodyArr.slice(-8))}`)
  const decrypted = decryptReceivedChunk(dhSecret, nonce, bodyArr, chunkDigest)
  console.log(`[WORKER-DBG] decrypted chunk=${chunkNo} len=${decrypted.length} [0..8]=${_whex(decrypted)} [-8..]=${_whex(decrypted.slice(-8))}`)

  if (useMemory) {
    memoryChunks.set(chunkNo, decrypted)
    self.postMessage({id, type: 'stored'})
    return
  }

  if (!downloadWriteHandle) {
    const dir = await getSessionDir()
    const fileHandle = await dir.getFileHandle('download.bin', {create: true})
    downloadWriteHandle = await fileHandle.createSyncAccessHandle()
  }

  const offset = currentDownloadOffset
  currentDownloadOffset += decrypted.length
  chunkMeta.set(chunkNo, {offset, size: decrypted.length})
  const written = downloadWriteHandle.write(decrypted, {at: offset})
  console.log(`[WORKER-DBG] OPFS write chunk=${chunkNo} offset=${offset} size=${decrypted.length} written=${written}`)

  if (written !== decrypted.length) {
    console.warn(`[WORKER] OPFS write failed chunk=${chunkNo}: ${written}/${decrypted.length}, falling back to in-memory storage`)
    // Migrate previously written chunks from OPFS to memory
    for (const [cn, meta] of chunkMeta.entries()) {
      if (cn === chunkNo) continue
      const buf = new Uint8Array(meta.size)
      downloadWriteHandle.read(buf, {at: meta.offset})
      memoryChunks.set(cn, buf)
    }
    downloadWriteHandle.close()
    downloadWriteHandle = null
    try {
      const dir = await getSessionDir()
      await dir.removeEntry('download.bin')
    } catch (_) {}
    chunkMeta.clear()
    currentDownloadOffset = 0
    memoryChunks.set(chunkNo, decrypted)
    useMemory = true
    self.postMessage({id, type: 'stored'})
    return
  }

  downloadWriteHandle.flush()

  // Verify: read back and compare first/last 8 bytes
  const verifyBuf = new Uint8Array(Math.min(8, decrypted.length))
  downloadWriteHandle.read(verifyBuf, {at: offset})
  const verifyEnd = new Uint8Array(Math.min(8, decrypted.length))
  downloadWriteHandle.read(verifyEnd, {at: offset + decrypted.length - verifyEnd.length})
  console.log(`[WORKER-DBG] OPFS verify chunk=${chunkNo} readBack[0..8]=${_whex(verifyBuf)} readBack[-8..]=${_whex(verifyEnd)} expected[0..8]=${_whex(decrypted)} expected[-8..]=${_whex(decrypted.slice(-8))}`)

  self.postMessage({id, type: 'stored'})
}

async function handleVerifyAndDecrypt(
  id: number, size: number, digest: Uint8Array, key: Uint8Array, nonce: Uint8Array
) {
  console.log(`[WORKER-DBG] verify: expectedSize=${size} expectedDigest=${_whex(digest, 64)} useMemory=${useMemory} chunkMeta.size=${chunkMeta.size} memoryChunks.size=${memoryChunks.size}`)

  // Read chunks — from memory (fallback) or OPFS
  const chunks: Uint8Array[] = []
  let totalSize = 0
  const total = size * 3 // read + hash + decrypt (byte-based progress)
  let done = 0
  if (useMemory) {
    const sorted = [...memoryChunks.entries()].sort((a, b) => a[0] - b[0])
    for (const [chunkNo, data] of sorted) {
      console.log(`[WORKER-DBG] verify memory chunk=${chunkNo} size=${data.length}`)
      chunks.push(data)
      totalSize += data.length
      done += data.length
      self.postMessage({id, type: 'progress', done, total})
    }
  } else {
    // Close write handle, reopen as read
    if (downloadWriteHandle) {
      downloadWriteHandle.flush()
      downloadWriteHandle.close()
      downloadWriteHandle = null
    }
    const dir = await getSessionDir()
    const fileHandle = await dir.getFileHandle('download.bin')
    const readHandle = await fileHandle.createSyncAccessHandle()
    console.log(`[WORKER-DBG] verify: OPFS file size=${readHandle.getSize()}`)
    const sortedEntries = [...chunkMeta.entries()].sort((a, b) => a[0] - b[0])
    for (const [chunkNo, meta] of sortedEntries) {
      const buf = new Uint8Array(meta.size)
      const bytesRead = readHandle.read(buf, {at: meta.offset})
      console.log(`[WORKER-DBG] verify read chunk=${chunkNo} offset=${meta.offset} size=${meta.size} bytesRead=${bytesRead} [0..8]=${_whex(buf)} [-8..]=${_whex(buf.slice(-8))}`)
      chunks.push(buf)
      totalSize += meta.size
      done += meta.size
      self.postMessage({id, type: 'progress', done, total})
    }
    readHandle.close()
  }

  if (totalSize !== size) {
    self.postMessage({id, type: 'error', message: `File size mismatch: ${totalSize} !== ${size}`})
    return
  }

  // Compute SHA-512 with byte-level progress
  const hashSEG = 4 * 1024 * 1024
  const state = sodium.crypto_hash_sha512_init() as unknown as import('libsodium-wrappers').StateAddress
  for (let i = 0; i < chunks.length; i++) {
    const chunk = chunks[i]
    for (let off = 0; off < chunk.length; off += hashSEG) {
      const end = Math.min(off + hashSEG, chunk.length)
      sodium.crypto_hash_sha512_update(state, chunk.subarray(off, end))
      done += end - off
      self.postMessage({id, type: 'progress', done, total})
    }
  }
  const actualDigest = sodium.crypto_hash_sha512_final(state)
  if (!digestEqual(actualDigest, digest)) {
    console.error(`[WORKER-DBG] DIGEST MISMATCH: expected=${_whex(digest, 64)} actual=${_whex(actualDigest, 64)} chunks=${chunks.length} totalSize=${totalSize}`)
    const state2 = sodium.crypto_hash_sha512_init() as unknown as import('libsodium-wrappers').StateAddress
    for (let i = 0; i < chunks.length; i++) {
      const chunk = chunks[i]
      for (let off = 0; off < chunk.length; off += hashSEG) {
        sodium.crypto_hash_sha512_update(state2, chunk.subarray(off, Math.min(off + hashSEG, chunk.length)))
      }
      const chunkDigest = sha512Streaming([chunk])
      console.error(`[WORKER-DBG] chunk[${i}] size=${chunk.length} sha512=${_whex(chunkDigest, 32)}… [0..8]=${_whex(chunk)} [-8..]=${_whex(chunk.slice(-8))}`)
    }
    self.postMessage({id, type: 'error', message: 'File digest mismatch'})
    return
  }
  console.log(`[WORKER-DBG] verify: digest OK`)

  // File-level decrypt with byte-level progress
  const result = decryptChunks(BigInt(size), chunks, key, nonce, (d) => {
    self.postMessage({id, type: 'progress', done: size * 2 + d, total})
  })
  self.postMessage({id, type: 'progress', done: total, total})

  // Clean up download state
  if (!useMemory) {
    const dir = await getSessionDir()
    try { await dir.removeEntry('download.bin') } catch (_) {}
  }
  chunkMeta.clear()
  memoryChunks.clear()
  currentDownloadOffset = 0
  useMemory = false

  const contentBuf = result.content.buffer.slice(
    result.content.byteOffset,
    result.content.byteOffset + result.content.byteLength
  )
  self.postMessage(
    {id, type: 'decrypted', header: result.header, content: contentBuf},
    [contentBuf]
  )
}

async function handleCleanup(id: number) {
  if (uploadReadHandle) {
    uploadReadHandle.close()
    uploadReadHandle = null
  }
  if (downloadWriteHandle) {
    downloadWriteHandle.close()
    downloadWriteHandle = null
  }
  chunkMeta.clear()
  memoryChunks.clear()
  currentDownloadOffset = 0
  useMemory = false
  try {
    const root = await navigator.storage.getDirectory()
    await root.removeEntry(SESSION_DIR, {recursive: true})
  } catch (_) {}
  sessionDir = null
  self.postMessage({id, type: 'cleaned'})
}

// ── Message dispatch ────────────────────────────────────────────

// Serialize all message processing — async onmessage would allow
// interleaved execution at await points, racing on shared OPFS handles
// when downloadFileRaw fetches chunks from multiple servers in parallel.
let queue: Promise<void> = Promise.resolve()
self.onmessage = (e: MessageEvent) => {
  const msg = e.data
  queue = queue.then(async () => {
    try {
      await initPromise
      switch (msg.type) {
        case 'encrypt':
          await handleEncrypt(msg.id, msg.data, msg.fileName)
          break
        case 'readChunk':
          handleReadChunk(msg.id, msg.offset, msg.size)
          break
        case 'decryptAndStoreChunk':
          await handleDecryptAndStore(msg.id, msg.dhSecret, msg.nonce, msg.body, msg.chunkDigest, msg.chunkNo)
          break
        case 'verifyAndDecrypt':
          await handleVerifyAndDecrypt(msg.id, msg.size, msg.digest, msg.key, msg.nonce)
          break
        case 'cleanup':
          await handleCleanup(msg.id)
          break
        default:
          self.postMessage({id: msg.id, type: 'error', message: `Unknown message type: ${msg.type}`})
      }
    } catch (err: any) {
      self.postMessage({id: msg.id, type: 'error', message: err?.message ?? String(err)})
    }
  })
}

// ── Helpers ─────────────────────────────────────────────────────

function _whex(b: Uint8Array, n = 8): string {
  return Array.from(b.slice(0, n)).map(x => x.toString(16).padStart(2, '0')).join('')
}

function digestEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i]
  return diff === 0
}

// ── Init ────────────────────────────────────────────────────────

const initPromise = (async () => {
  await sodium.ready
  await sweepStale()
})()

// Signal main thread that the worker is ready to receive messages
initPromise.then(() => self.postMessage({type: 'ready'}), () => {})
