// XFTP upload/download orchestration + URI encoding -- Simplex.FileTransfer.Client.Main
//
// Combines all building blocks: encryption, chunking, XFTP client commands,
// file descriptions, and DEFLATE-compressed URI encoding.

import pako from "pako"
import {encryptFileAsync, encodeFileHeader} from "./crypto/file.js"
import {generateEd25519KeyPair, encodePubKeyEd25519, encodePrivKeyEd25519, decodePrivKeyEd25519, ed25519KeyPairFromSeed} from "./crypto/keys.js"
import {sha512Streaming} from "./crypto/digest.js"
import {prepareChunkSizes, prepareChunkSpecs, getChunkDigest, fileSizeLen, authTagSize} from "./protocol/chunks.js"
import {
  encodeFileDescription, decodeFileDescription, validateFileDescription,
  base64urlEncode, base64urlDecode,
  type FileDescription
} from "./protocol/description.js"
import type {FileInfo} from "./protocol/commands.js"
import {
  createXFTPChunk, addXFTPRecipients, uploadXFTPChunk, downloadXFTPChunk, downloadXFTPChunkRaw,
  deleteXFTPChunk, ackXFTPChunk, type XFTPClientAgent
} from "./client.js"
export {newXFTPAgent, closeXFTPAgent, type XFTPClientAgent, type TransportConfig,
  XFTPRetriableError, XFTPPermanentError, isRetriable, categorizeError, humanReadableMessage,
  ackXFTPChunk, addXFTPRecipients} from "./client.js"
import {processDownloadedFile, decryptReceivedChunk} from "./download.js"
import type {XFTPServer} from "./protocol/address.js"
import {formatXFTPServer, parseXFTPServer} from "./protocol/address.js"
import type {FileHeader} from "./crypto/file.js"

// -- Types

interface SentChunk {
  chunkNo: number
  senderId: Uint8Array
  senderKey: Uint8Array      // 64B libsodium Ed25519 private key
  recipients: {recipientId: Uint8Array, recipientKey: Uint8Array}[]
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
  rcvDescriptions: FileDescription[]
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

export async function encryptFileForUpload(
  source: Uint8Array,
  fileName: string,
  onProgress?: (done: number, total: number) => void
): Promise<EncryptedFileInfo> {
  const key = new Uint8Array(32)
  const nonce = new Uint8Array(24)
  crypto.getRandomValues(key)
  crypto.getRandomValues(nonce)
  const fileHdr = encodeFileHeader({fileName, fileExtra: null})
  const fileSize = BigInt(fileHdr.length + source.length)
  const payloadSize = Number(fileSize) + fileSizeLen + authTagSize
  const chunkSizes = prepareChunkSizes(payloadSize)
  const encSize = BigInt(chunkSizes.reduce((a, b) => a + b, 0))
  const encData = await encryptFileAsync(source, fileHdr, key, nonce, fileSize, encSize, onProgress)
  const digest = sha512Streaming([encData])
  console.log(`[AGENT-DBG] encrypt: encData.len=${encData.length} digest=${_dbgHex(digest, 64)} chunkSizes=[${chunkSizes.join(',')}]`)
  return {encData, digest, key, nonce, chunkSizes}
}

const DEFAULT_REDIRECT_THRESHOLD = 400
const MAX_RECIPIENTS_PER_REQUEST = 200 // each key is ~46 bytes; 200 keys fit within 16KB XFTP block

export interface UploadOptions {
  onProgress?: (uploaded: number, total: number) => void
  redirectThreshold?: number
  readChunk?: (offset: number, size: number) => Promise<Uint8Array>
  auth?: Uint8Array
  numRecipients?: number
}

export async function uploadFile(
  agent: XFTPClientAgent,
  servers: XFTPServer[],
  encrypted: EncryptedFileMetadata,
  options?: UploadOptions
): Promise<UploadResult> {
  if (servers.length === 0) throw new Error("uploadFile: servers list is empty")
  const {onProgress, redirectThreshold, readChunk: readChunkOpt, auth, numRecipients = 1} = options ?? {}
  const readChunk: (offset: number, size: number) => Promise<Uint8Array> = readChunkOpt
    ? readChunkOpt
    : ('encData' in encrypted
        ? (off, sz) => Promise.resolve((encrypted as EncryptedFileInfo).encData.subarray(off, off + sz))
        : () => { throw new Error("uploadFile: readChunk required when encData is absent") })
  const total = encrypted.chunkSizes.reduce((a, b) => a + b, 0)
  const specs = prepareChunkSpecs(encrypted.chunkSizes)

  // Pre-assign servers and group by server (matching Haskell groupAllOn)
  const chunkJobs = specs.map((spec, i) => ({
    index: i,
    spec,
    server: servers[Math.floor(Math.random() * servers.length)]
  }))
  const byServer = new Map<string, typeof chunkJobs>()
  for (const job of chunkJobs) {
    const key = formatXFTPServer(job.server)
    if (!byServer.has(key)) byServer.set(key, [])
    byServer.get(key)!.push(job)
  }

  // Upload groups in parallel, sequential within each group
  const sentChunks: SentChunk[] = new Array(specs.length)
  let uploaded = 0
  await Promise.all([...byServer.values()].map(async (jobs) => {
    for (const {index, spec, server} of jobs) {
      const chunkNo = index + 1
      const sndKp = generateEd25519KeyPair()
      const rcvKps = Array.from({length: numRecipients}, () => generateEd25519KeyPair())
      const chunkData = await readChunk(spec.chunkOffset, spec.chunkSize)
      const chunkDigest = getChunkDigest(chunkData)
      console.log(`[AGENT-DBG] upload chunk=${chunkNo} offset=${spec.chunkOffset} size=${spec.chunkSize} digest=${_dbgHex(chunkDigest, 32)} data[0..8]=${_dbgHex(chunkData)} data[-8..]=${_dbgHex(chunkData.slice(-8))}`)
      const fileInfo: FileInfo = {
        sndKey: encodePubKeyEd25519(sndKp.publicKey),
        size: spec.chunkSize,
        digest: chunkDigest
      }
      const firstBatch = Math.min(numRecipients, MAX_RECIPIENTS_PER_REQUEST)
      const firstBatchKeys = rcvKps.slice(0, firstBatch).map(kp => encodePubKeyEd25519(kp.publicKey))
      const {senderId, recipientIds: firstIds} = await createXFTPChunk(
        agent, server, sndKp.privateKey, fileInfo, firstBatchKeys, auth ?? null
      )
      const allRecipientIds = [...firstIds]
      let added = firstBatch
      while (added < numRecipients) {
        const batchSize = Math.min(numRecipients - added, MAX_RECIPIENTS_PER_REQUEST)
        const batchKeys = rcvKps.slice(added, added + batchSize).map(kp => encodePubKeyEd25519(kp.publicKey))
        const moreIds = await addXFTPRecipients(agent, server, sndKp.privateKey, senderId, batchKeys)
        allRecipientIds.push(...moreIds)
        added += batchSize
      }
      await uploadXFTPChunk(agent, server, sndKp.privateKey, senderId, chunkData)
      sentChunks[index] = {
        chunkNo, senderId, senderKey: sndKp.privateKey,
        recipients: allRecipientIds.map((rid, ri) => ({
          recipientId: rid, recipientKey: rcvKps[ri].privateKey
        })),
        chunkSize: spec.chunkSize, digest: chunkDigest, server
      }
      uploaded += spec.chunkSize
      onProgress?.(uploaded, total)
    }
  }))

  const rcvDescriptions = Array.from({length: numRecipients}, (_, ri) =>
    buildDescription("recipient", ri, encrypted, sentChunks)
  )
  const sndDescription = buildDescription("sender", 0, encrypted, sentChunks)
  let uri = encodeDescriptionURI(rcvDescriptions[0])
  let finalRcvDescriptions = rcvDescriptions
  const threshold = redirectThreshold ?? DEFAULT_REDIRECT_THRESHOLD
  if (uri.length > threshold && sentChunks.length > 1) {
    const redirected = await uploadRedirectDescription(agent, servers, rcvDescriptions[0], auth)
    finalRcvDescriptions = [redirected, ...rcvDescriptions.slice(1)]
    uri = encodeDescriptionURI(redirected)
  }
  return {rcvDescriptions: finalRcvDescriptions, sndDescription, uri}
}

function buildDescription(
  party: "recipient" | "sender",
  recipientIndex: number,
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
        replicaId: party === "recipient" ? c.recipients[recipientIndex].recipientId : c.senderId,
        replicaKey: encodePrivKeyEd25519(party === "recipient" ? c.recipients[recipientIndex].recipientKey : c.senderKey)
      }]
    })),
    redirect: null
  }
}

async function uploadRedirectDescription(
  agent: XFTPClientAgent,
  servers: XFTPServer[],
  innerFd: FileDescription,
  auth?: Uint8Array
): Promise<FileDescription> {
  const yaml = encodeFileDescription(innerFd)
  const yamlBytes = new TextEncoder().encode(yaml)
  const enc = await encryptFileForUpload(yamlBytes, "")
  const specs = prepareChunkSpecs(enc.chunkSizes)

  const chunkJobs = specs.map((spec, i) => ({
    index: i,
    spec,
    server: servers[Math.floor(Math.random() * servers.length)]
  }))
  const byServer = new Map<string, typeof chunkJobs>()
  for (const job of chunkJobs) {
    const key = formatXFTPServer(job.server)
    if (!byServer.has(key)) byServer.set(key, [])
    byServer.get(key)!.push(job)
  }

  const sentChunks: SentChunk[] = new Array(specs.length)
  await Promise.all([...byServer.values()].map(async (jobs) => {
    for (const {index, spec, server} of jobs) {
      const chunkNo = index + 1
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
        agent, server, sndKp.privateKey, fileInfo, rcvKeysForChunk, auth ?? null
      )
      await uploadXFTPChunk(agent, server, sndKp.privateKey, senderId, chunkData)
      sentChunks[index] = {
        chunkNo, senderId, senderKey: sndKp.privateKey,
        recipients: [{recipientId: recipientIds[0], recipientKey: rcvKp.privateKey}],
        chunkSize: spec.chunkSize, digest: chunkDigest, server
      }
    }
  }))

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
        replicaId: c.recipients[0].recipientId,
        replicaKey: encodePrivKeyEd25519(c.recipients[0].recipientKey)
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
}

export async function downloadFileRaw(
  agent: XFTPClientAgent,
  fd: FileDescription,
  onRawChunk: (chunk: RawDownloadedChunk) => Promise<void>,
  options?: DownloadRawOptions
): Promise<FileDescription> {
  const err = validateFileDescription(fd)
  if (err) throw new Error("downloadFileRaw: " + err)
  const {onProgress} = options ?? {}
  // Resolve redirect on main thread (redirect data is small)
  if (fd.redirect !== null) {
    console.log(`[AGENT-DBG] resolving redirect: outer size=${fd.size} chunks=${fd.chunks.length}`)
    fd = await resolveRedirect(agent, fd)
    console.log(`[AGENT-DBG] resolved: size=${fd.size} chunks=${fd.chunks.length} digest=${Array.from(fd.digest.slice(0, 16)).map(x => x.toString(16).padStart(2, '0')).join('')}…`)
  }
  const resolvedFd = fd
  // Group chunks by server, sequential within each server, parallel across servers
  let downloaded = 0
  const byServer = new Map<string, typeof resolvedFd.chunks>()
  for (const chunk of resolvedFd.chunks) {
    const srv = chunk.replicas[0]?.server ?? ""
    if (!byServer.has(srv)) byServer.set(srv, [])
    byServer.get(srv)!.push(chunk)
  }
  await Promise.all([...byServer.entries()].map(async ([srv, chunks]) => {
    const server = parseXFTPServer(srv)
    for (const chunk of chunks) {
      const replica = chunk.replicas[0]
      if (!replica) throw new Error("downloadFileRaw: chunk has no replicas")
      const seed = decodePrivKeyEd25519(replica.replicaKey)
      const kp = ed25519KeyPairFromSeed(seed)
      const raw = await downloadXFTPChunkRaw(agent, server, kp.privateKey, replica.replicaId)
      console.log(`[AGENT-DBG] chunk=${chunk.chunkNo} body.len=${raw.body.length} expectedChunkSize=${chunk.chunkSize} digest=${_dbgHex(chunk.digest, 32)} body.byteOffset=${raw.body.byteOffset} body.buffer.byteLength=${raw.body.buffer.byteLength}`)
      await onRawChunk({
        chunkNo: chunk.chunkNo,
        dhSecret: raw.dhSecret,
        nonce: raw.nonce,
        body: raw.body,
        digest: chunk.digest
      })
      await ackXFTPChunk(agent, server, kp.privateKey, replica.replicaId)
      downloaded += chunk.chunkSize
      onProgress?.(downloaded, resolvedFd.size)
    }
  }))
  return resolvedFd
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
  const totalSize = chunks.reduce((s, c) => s + c.length, 0)
  if (totalSize !== resolvedFd.size) throw new Error("downloadFile: file size mismatch")
  const digest = sha512Streaming(chunks)
  if (!digestEqual(digest, resolvedFd.digest)) throw new Error("downloadFile: file digest mismatch")
  return processDownloadedFile(resolvedFd, chunks)
}

async function resolveRedirect(
  agent: XFTPClientAgent,
  fd: FileDescription
): Promise<FileDescription> {
  const plaintextChunks: Uint8Array[] = new Array(fd.chunks.length)
  const byServer = new Map<string, typeof fd.chunks>()
  for (const chunk of fd.chunks) {
    const srv = chunk.replicas[0]?.server ?? ""
    if (!byServer.has(srv)) byServer.set(srv, [])
    byServer.get(srv)!.push(chunk)
  }
  await Promise.all([...byServer.entries()].map(async ([srv, chunks]) => {
    const server = parseXFTPServer(srv)
    for (const chunk of chunks) {
      const replica = chunk.replicas[0]
      if (!replica) throw new Error("resolveRedirect: chunk has no replicas")
      const seed = decodePrivKeyEd25519(replica.replicaKey)
      const kp = ed25519KeyPairFromSeed(seed)
      const data = await downloadXFTPChunk(agent, server, kp.privateKey, replica.replicaId, chunk.digest)
      plaintextChunks[chunk.chunkNo - 1] = data
      await ackXFTPChunk(agent, server, kp.privateKey, replica.replicaId)
    }
  }))
  const totalSize = plaintextChunks.reduce((s, c) => s + c.length, 0)
  if (totalSize !== fd.size) throw new Error("resolveRedirect: redirect file size mismatch")
  const digest = sha512Streaming(plaintextChunks)
  if (!digestEqual(digest, fd.digest)) throw new Error("resolveRedirect: redirect file digest mismatch")
  const {content: yamlBytes} = processDownloadedFile(fd, plaintextChunks)
  const yamlStr = new TextDecoder().decode(yamlBytes)
  const innerFd = decodeFileDescription(yamlStr)
  const innerErr = validateFileDescription(innerFd)
  if (innerErr) throw new Error("resolveRedirect: inner description invalid: " + innerErr)
  if (innerFd.size !== fd.redirect!.size) throw new Error("resolveRedirect: redirect size mismatch")
  if (!digestEqual(innerFd.digest, fd.redirect!.digest)) throw new Error("resolveRedirect: redirect digest mismatch")
  return innerFd
}

// -- Delete

export async function deleteFile(agent: XFTPClientAgent, sndDescription: FileDescription): Promise<void> {
  const byServer = new Map<string, typeof sndDescription.chunks>()
  for (const chunk of sndDescription.chunks) {
    const srv = chunk.replicas[0]?.server ?? ""
    if (!byServer.has(srv)) byServer.set(srv, [])
    byServer.get(srv)!.push(chunk)
  }
  await Promise.all([...byServer.entries()].map(async ([srv, chunks]) => {
    const server = parseXFTPServer(srv)
    for (const chunk of chunks) {
      const replica = chunk.replicas[0]
      if (!replica) throw new Error("deleteFile: chunk has no replicas")
      const seed = decodePrivKeyEd25519(replica.replicaKey)
      const kp = ed25519KeyPairFromSeed(seed)
      await deleteXFTPChunk(agent, server, kp.privateKey, replica.replicaId)
    }
  }))
}

// -- Internal

function _dbgHex(b: Uint8Array, n = 8): string {
  return Array.from(b.slice(0, n)).map(x => x.toString(16).padStart(2, '0')).join('')
}

function digestEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i]
  return diff === 0
}
