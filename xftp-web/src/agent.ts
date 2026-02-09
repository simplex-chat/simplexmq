// XFTP upload/download orchestration + URI encoding -- Simplex.FileTransfer.Client.Main
//
// Combines all building blocks: encryption, chunking, XFTP client commands,
// file descriptions, and DEFLATE-compressed URI encoding.

import pako from "pako"
import {encryptFile, encodeFileHeader} from "./crypto/file.js"
import {generateEd25519KeyPair, encodePubKeyEd25519, encodePrivKeyEd25519, decodePrivKeyEd25519, ed25519KeyPairFromSeed} from "./crypto/keys.js"
import {sha512} from "./crypto/digest.js"
import {prepareChunkSizes, prepareChunkSpecs, getChunkDigest, fileSizeLen, authTagSize} from "./protocol/chunks.js"
import {
  encodeFileDescription, decodeFileDescription, validateFileDescription,
  base64urlEncode, base64urlDecode,
  type FileDescription
} from "./protocol/description.js"
import type {FileInfo} from "./protocol/commands.js"
import {
  getXFTPServerClient, createXFTPChunk, uploadXFTPChunk, downloadXFTPChunk, downloadXFTPChunkRaw,
  ackXFTPChunk, deleteXFTPChunk, type XFTPClientAgent
} from "./client.js"
export {newXFTPAgent, closeXFTPAgent, type XFTPClientAgent} from "./client.js"
import {processDownloadedFile, decryptReceivedChunk} from "./download.js"
import type {XFTPServer} from "./protocol/address.js"
import {formatXFTPServer, parseXFTPServer} from "./protocol/address.js"
import {concatBytes} from "./protocol/encoding.js"
import type {FileHeader} from "./crypto/file.js"

// -- Types

interface SentChunk {
  chunkNo: number
  senderId: Uint8Array
  senderKey: Uint8Array      // 64B libsodium Ed25519 private key
  recipientId: Uint8Array
  recipientKey: Uint8Array   // 64B libsodium Ed25519 private key
  chunkSize: number
  digest: Uint8Array         // SHA-256
  server: XFTPServer
}

export interface EncryptedFileMetadata {
  digest: Uint8Array          // SHA-512 of encData
  key: Uint8Array             // 32B SbKey
  nonce: Uint8Array           // 24B CbNonce
  chunkSizes: number[]
}

export interface EncryptedFileInfo extends EncryptedFileMetadata {
  encData: Uint8Array
}

export interface UploadResult {
  rcvDescription: FileDescription
  sndDescription: FileDescription
  uri: string                 // base64url-encoded compressed YAML (no leading #)
}

export interface DownloadResult {
  header: FileHeader
  content: Uint8Array
}

// -- URI encoding/decoding (RFC section 4.1: DEFLATE + base64url)

export function encodeDescriptionURI(fd: FileDescription): string {
  const yaml = encodeFileDescription(fd)
  const compressed = pako.deflateRaw(new TextEncoder().encode(yaml))
  return base64urlEncode(compressed)
}

export function decodeDescriptionURI(fragment: string): FileDescription {
  const compressed = base64urlDecode(fragment)
  const yaml = new TextDecoder().decode(pako.inflateRaw(compressed))
  const fd = decodeFileDescription(yaml)
  const err = validateFileDescription(fd)
  if (err) throw new Error("decodeDescriptionURI: " + err)
  return fd
}

// -- Upload

export function encryptFileForUpload(source: Uint8Array, fileName: string): EncryptedFileInfo {
  const key = new Uint8Array(32)
  const nonce = new Uint8Array(24)
  crypto.getRandomValues(key)
  crypto.getRandomValues(nonce)
  const fileHdr = encodeFileHeader({fileName, fileExtra: null})
  const fileSize = BigInt(fileHdr.length + source.length)
  const payloadSize = Number(fileSize) + fileSizeLen + authTagSize
  const chunkSizes = prepareChunkSizes(payloadSize)
  const encSize = BigInt(chunkSizes.reduce((a, b) => a + b, 0))
  const encData = encryptFile(source, fileHdr, key, nonce, fileSize, encSize)
  const digest = sha512(encData)
  return {encData, digest, key, nonce, chunkSizes}
}

const DEFAULT_REDIRECT_THRESHOLD = 400

export interface UploadOptions {
  onProgress?: (uploaded: number, total: number) => void
  redirectThreshold?: number
  readChunk?: (offset: number, size: number) => Promise<Uint8Array>
}

export async function uploadFile(
  agent: XFTPClientAgent,
  server: XFTPServer,
  encrypted: EncryptedFileMetadata,
  options?: UploadOptions
): Promise<UploadResult> {
  const {onProgress, redirectThreshold, readChunk: readChunkOpt} = options ?? {}
  const readChunk: (offset: number, size: number) => Promise<Uint8Array> = readChunkOpt
    ? readChunkOpt
    : ('encData' in encrypted
        ? (off, sz) => Promise.resolve((encrypted as EncryptedFileInfo).encData.subarray(off, off + sz))
        : () => { throw new Error("uploadFile: readChunk required when encData is absent") })
  const total = encrypted.chunkSizes.reduce((a, b) => a + b, 0)
  const specs = prepareChunkSpecs(encrypted.chunkSizes)
  const client = await getXFTPServerClient(agent, server)
  const sentChunks: SentChunk[] = []
  let uploaded = 0
  for (let i = 0; i < specs.length; i++) {
    const spec = specs[i]
    const chunkNo = i + 1
    const sndKp = generateEd25519KeyPair()
    const rcvKp = generateEd25519KeyPair()
    const chunkData = await readChunk(spec.chunkOffset, spec.chunkSize)
    const chunkDigest = getChunkDigest(chunkData)
    const fileInfo: FileInfo = {
      sndKey: encodePubKeyEd25519(sndKp.publicKey),
      size: spec.chunkSize,
      digest: chunkDigest
    }
    const rcvKeysForChunk = [encodePubKeyEd25519(rcvKp.publicKey)]
    const {senderId, recipientIds} = await createXFTPChunk(
      client, sndKp.privateKey, fileInfo, rcvKeysForChunk
    )
    await uploadXFTPChunk(client, sndKp.privateKey, senderId, chunkData)
    sentChunks.push({
      chunkNo, senderId, senderKey: sndKp.privateKey,
      recipientId: recipientIds[0], recipientKey: rcvKp.privateKey,
      chunkSize: spec.chunkSize, digest: chunkDigest, server
    })
    uploaded += spec.chunkSize
    onProgress?.(uploaded, total)
  }
  const rcvDescription = buildDescription("recipient", encrypted, sentChunks)
  const sndDescription = buildDescription("sender", encrypted, sentChunks)
  let uri = encodeDescriptionURI(rcvDescription)
  let finalRcvDescription = rcvDescription
  const threshold = redirectThreshold ?? DEFAULT_REDIRECT_THRESHOLD
  if (uri.length > threshold && sentChunks.length > 1) {
    finalRcvDescription = await uploadRedirectDescription(agent, server, rcvDescription)
    uri = encodeDescriptionURI(finalRcvDescription)
  }
  return {rcvDescription: finalRcvDescription, sndDescription, uri}
}

function buildDescription(
  party: "recipient" | "sender",
  enc: EncryptedFileMetadata,
  chunks: SentChunk[]
): FileDescription {
  const defChunkSize = enc.chunkSizes[0]
  return {
    party,
    size: enc.chunkSizes.reduce((a, b) => a + b, 0),
    digest: enc.digest,
    key: enc.key,
    nonce: enc.nonce,
    chunkSize: defChunkSize,
    chunks: chunks.map(c => ({
      chunkNo: c.chunkNo,
      chunkSize: c.chunkSize,
      digest: c.digest,
      replicas: [{
        server: formatXFTPServer(c.server),
        replicaId: party === "recipient" ? c.recipientId : c.senderId,
        replicaKey: encodePrivKeyEd25519(party === "recipient" ? c.recipientKey : c.senderKey)
      }]
    })),
    redirect: null
  }
}

async function uploadRedirectDescription(
  agent: XFTPClientAgent,
  server: XFTPServer,
  innerFd: FileDescription
): Promise<FileDescription> {
  const client = await getXFTPServerClient(agent, server)
  const yaml = encodeFileDescription(innerFd)
  const yamlBytes = new TextEncoder().encode(yaml)
  const enc = encryptFileForUpload(yamlBytes, "")
  const specs = prepareChunkSpecs(enc.chunkSizes)
  const sentChunks: SentChunk[] = []
  for (let i = 0; i < specs.length; i++) {
    const spec = specs[i]
    const chunkNo = i + 1
    const sndKp = generateEd25519KeyPair()
    const rcvKp = generateEd25519KeyPair()
    const chunkData = enc.encData.subarray(spec.chunkOffset, spec.chunkOffset + spec.chunkSize)
    const chunkDigest = getChunkDigest(chunkData)
    const fileInfo: FileInfo = {
      sndKey: encodePubKeyEd25519(sndKp.publicKey),
      size: spec.chunkSize,
      digest: chunkDigest
    }
    const rcvKeysForChunk = [encodePubKeyEd25519(rcvKp.publicKey)]
    const {senderId, recipientIds} = await createXFTPChunk(
      client, sndKp.privateKey, fileInfo, rcvKeysForChunk
    )
    await uploadXFTPChunk(client, sndKp.privateKey, senderId, chunkData)
    sentChunks.push({
      chunkNo, senderId, senderKey: sndKp.privateKey,
      recipientId: recipientIds[0], recipientKey: rcvKp.privateKey,
      chunkSize: spec.chunkSize, digest: chunkDigest, server
    })
  }
  return {
    party: "recipient",
    size: enc.chunkSizes.reduce((a, b) => a + b, 0),
    digest: enc.digest,
    key: enc.key,
    nonce: enc.nonce,
    chunkSize: enc.chunkSizes[0],
    chunks: sentChunks.map(c => ({
      chunkNo: c.chunkNo,
      chunkSize: c.chunkSize,
      digest: c.digest,
      replicas: [{
        server: formatXFTPServer(c.server),
        replicaId: c.recipientId,
        replicaKey: encodePrivKeyEd25519(c.recipientKey)
      }]
    })),
    redirect: {size: innerFd.size, digest: innerFd.digest}
  }
}

// -- Download

export interface RawDownloadedChunk {
  chunkNo: number
  dhSecret: Uint8Array
  nonce: Uint8Array
  body: Uint8Array
  digest: Uint8Array
}

export interface DownloadRawOptions {
  onProgress?: (downloaded: number, total: number) => void
  concurrency?: number
}

export async function downloadFileRaw(
  agent: XFTPClientAgent,
  fd: FileDescription,
  onRawChunk: (chunk: RawDownloadedChunk) => Promise<void>,
  options?: DownloadRawOptions
): Promise<FileDescription> {
  const err = validateFileDescription(fd)
  if (err) throw new Error("downloadFileRaw: " + err)
  const {onProgress, concurrency = 1} = options ?? {}
  // Resolve redirect on main thread (redirect data is small)
  if (fd.redirect !== null) {
    fd = await resolveRedirect(agent, fd)
  }
  const resolvedFd = fd
  // Pre-connect to avoid race condition under concurrency
  const servers = new Set(resolvedFd.chunks.map(c => c.replicas[0]?.server).filter(Boolean) as string[])
  for (const s of servers) {
    await getXFTPServerClient(agent, parseXFTPServer(s))
  }
  // Sliding-window parallel download
  let downloaded = 0
  const queue = resolvedFd.chunks.slice()
  let idx = 0
  async function worker() {
    while (idx < queue.length) {
      const i = idx++
      const chunk = queue[i]
      const replica = chunk.replicas[0]
      if (!replica) throw new Error("downloadFileRaw: chunk has no replicas")
      const client = await getXFTPServerClient(agent, parseXFTPServer(replica.server))
      const seed = decodePrivKeyEd25519(replica.replicaKey)
      const kp = ed25519KeyPairFromSeed(seed)
      const raw = await downloadXFTPChunkRaw(client, kp.privateKey, replica.replicaId)
      await onRawChunk({
        chunkNo: chunk.chunkNo,
        dhSecret: raw.dhSecret,
        nonce: raw.nonce,
        body: raw.body,
        digest: chunk.digest
      })
      downloaded += chunk.chunkSize
      onProgress?.(downloaded, resolvedFd.size)
    }
  }
  const workers = Array.from({length: Math.min(concurrency, queue.length)}, () => worker())
  await Promise.all(workers)
  return resolvedFd
}

export async function ackFileChunks(
  agent: XFTPClientAgent, fd: FileDescription
): Promise<void> {
  for (const chunk of fd.chunks) {
    const replica = chunk.replicas[0]
    if (!replica) continue
    try {
      const client = await getXFTPServerClient(agent, parseXFTPServer(replica.server))
      const seed = decodePrivKeyEd25519(replica.replicaKey)
      const kp = ed25519KeyPairFromSeed(seed)
      await ackXFTPChunk(client, kp.privateKey, replica.replicaId)
    } catch (_) {}
  }
}

export async function downloadFile(
  agent: XFTPClientAgent,
  fd: FileDescription,
  onProgress?: (downloaded: number, total: number) => void
): Promise<DownloadResult> {
  const chunks: Uint8Array[] = []
  const resolvedFd = await downloadFileRaw(agent, fd, async (raw) => {
    chunks[raw.chunkNo - 1] = decryptReceivedChunk(
      raw.dhSecret, raw.nonce, raw.body, raw.digest
    )
  }, {onProgress})
  const combined = chunks.length === 1 ? chunks[0] : concatBytes(...chunks)
  if (combined.length !== resolvedFd.size) throw new Error("downloadFile: file size mismatch")
  const digest = sha512(combined)
  if (!digestEqual(digest, resolvedFd.digest)) throw new Error("downloadFile: file digest mismatch")
  const result = processDownloadedFile(resolvedFd, chunks)
  await ackFileChunks(agent, resolvedFd)
  return result
}

async function resolveRedirect(
  agent: XFTPClientAgent,
  fd: FileDescription
): Promise<FileDescription> {
  const plaintextChunks: Uint8Array[] = new Array(fd.chunks.length)
  for (const chunk of fd.chunks) {
    const replica = chunk.replicas[0]
    if (!replica) throw new Error("resolveRedirect: chunk has no replicas")
    const client = await getXFTPServerClient(agent, parseXFTPServer(replica.server))
    const seed = decodePrivKeyEd25519(replica.replicaKey)
    const kp = ed25519KeyPairFromSeed(seed)
    const data = await downloadXFTPChunk(client, kp.privateKey, replica.replicaId, chunk.digest)
    plaintextChunks[chunk.chunkNo - 1] = data
  }
  const totalSize = plaintextChunks.reduce((s, c) => s + c.length, 0)
  if (totalSize !== fd.size) throw new Error("resolveRedirect: redirect file size mismatch")
  const combined = plaintextChunks.length === 1 ? plaintextChunks[0] : concatBytes(...plaintextChunks)
  const digest = sha512(combined)
  if (!digestEqual(digest, fd.digest)) throw new Error("resolveRedirect: redirect file digest mismatch")
  const {content: yamlBytes} = processDownloadedFile(fd, plaintextChunks)
  const yamlStr = new TextDecoder().decode(yamlBytes)
  const innerFd = decodeFileDescription(yamlStr)
  const innerErr = validateFileDescription(innerFd)
  if (innerErr) throw new Error("resolveRedirect: inner description invalid: " + innerErr)
  if (innerFd.size !== fd.redirect!.size) throw new Error("resolveRedirect: redirect size mismatch")
  if (!digestEqual(innerFd.digest, fd.redirect!.digest)) throw new Error("resolveRedirect: redirect digest mismatch")
  // ACK redirect chunks (best-effort)
  await ackFileChunks(agent, fd)
  return innerFd
}

// -- Delete

export async function deleteFile(agent: XFTPClientAgent, sndDescription: FileDescription): Promise<void> {
  for (const chunk of sndDescription.chunks) {
    const replica = chunk.replicas[0]
    if (!replica) throw new Error("deleteFile: chunk has no replicas")
    const client = await getXFTPServerClient(agent, parseXFTPServer(replica.server))
    const seed = decodePrivKeyEd25519(replica.replicaKey)
    const kp = ed25519KeyPairFromSeed(seed)
    await deleteXFTPChunk(client, kp.privateKey, replica.replicaId)
  }
}

// -- Internal

function digestEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i]
  return diff === 0
}
