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
  const encData = encryptFile(source, fileHdr, key, nonce, fileSize, encSize)

  self.postMessage({id, type: 'progress', done: 50, total: 100})

  const digest = sha512Streaming([encData])

  self.postMessage({id, type: 'progress', done: 80, total: 100})

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

  self.postMessage({id, type: 'progress', done: 100, total: 100})
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
  const decrypted = decryptReceivedChunk(dhSecret, nonce, bodyArr, chunkDigest)

  if (!downloadWriteHandle) {
    const dir = await getSessionDir()
    const fileHandle = await dir.getFileHandle('download.bin', {create: true})
    downloadWriteHandle = await fileHandle.createSyncAccessHandle()
  }

  const offset = currentDownloadOffset
  currentDownloadOffset += decrypted.length
  chunkMeta.set(chunkNo, {offset, size: decrypted.length})
  const written = downloadWriteHandle.write(decrypted, {at: offset})
  if (written !== decrypted.length) throw new Error(`OPFS download write chunk ${chunkNo}: ${written}/${decrypted.length}`)
  downloadWriteHandle.flush()

  self.postMessage({id, type: 'stored'})
}

async function handleVerifyAndDecrypt(
  id: number, size: number, digest: Uint8Array, key: Uint8Array, nonce: Uint8Array
) {
  // Close write handle, reopen as read
  if (downloadWriteHandle) {
    downloadWriteHandle.flush()
    downloadWriteHandle.close()
    downloadWriteHandle = null
  }

  const dir = await getSessionDir()
  const fileHandle = await dir.getFileHandle('download.bin')
  const readHandle = await fileHandle.createSyncAccessHandle()

  // Read chunks ordered by chunkNo, verify size and SHA-512 digest (streaming)
  const sortedEntries = [...chunkMeta.entries()].sort((a, b) => a[0] - b[0])
  const chunks: Uint8Array[] = []
  let totalSize = 0
  for (const [, meta] of sortedEntries) {
    const buf = new Uint8Array(meta.size)
    readHandle.read(buf, {at: meta.offset})
    chunks.push(buf)
    totalSize += meta.size
  }
  readHandle.close()

  if (totalSize !== size) {
    self.postMessage({id, type: 'error', message: `File size mismatch: ${totalSize} !== ${size}`})
    return
  }

  const actualDigest = sha512Streaming(chunks)
  if (!digestEqual(actualDigest, digest)) {
    const hex = (b: Uint8Array) => Array.from(b.slice(0, 16)).map(x => x.toString(16).padStart(2, '0')).join('')
    console.error(`[WORKER] digest mismatch: expected=${hex(digest)}… actual=${hex(actualDigest)}… chunks=${chunks.length} totalSize=${totalSize}`)
    self.postMessage({id, type: 'error', message: 'File digest mismatch'})
    return
  }

  // File-level decrypt
  const result = decryptChunks(BigInt(size), chunks, key, nonce)

  // Clean up download file
  try { await dir.removeEntry('download.bin') } catch (_) {}
  chunkMeta.clear()
  currentDownloadOffset = 0

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
  currentDownloadOffset = 0
  try {
    const root = await navigator.storage.getDirectory()
    await root.removeEntry(SESSION_DIR, {recursive: true})
  } catch (_) {}
  sessionDir = null
  self.postMessage({id, type: 'cleaned'})
}

// ── Message dispatch ────────────────────────────────────────────

self.onmessage = async (e: MessageEvent) => {
  await initPromise
  const msg = e.data
  try {
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
}

// ── Helpers ─────────────────────────────────────────────────────

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
