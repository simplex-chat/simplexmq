// XFTP upload/download orchestration + URI encoding -- Simplex.FileTransfer.Client.Main
//
// Combines all building blocks: encryption, chunking, XFTP client commands,
// file descriptions, and DEFLATE-compressed URI encoding.

import pako from "pako"
import {encryptFileAsync, prepareEncryption} from "./crypto/file.js"
import {sbInit, sbEncryptChunk, sbAuth} from "./crypto/secretbox.js"
import {concatBytes, encodeInt64} from "./protocol/encoding.js"
export {prepareEncryption, type EncryptionParams} from "./crypto/file.js"
import {generateEd25519KeyPair, encodePubKeyEd25519, encodePrivKeyEd25519, decodePrivKeyEd25519, ed25519KeyPairFromSeed} from "./crypto/keys.js"
import {sha512Streaming, sha512Init, sha512Update, sha512Final} from "./crypto/digest.js"
import {prepareChunkSpecs, getChunkDigest} from "./protocol/chunks.js"
import {
  encodeFileDescription, decodeFileDescription, validateFileDescription,
  base64urlEncode, base64urlDecode,
  type FileDescription
} from "./protocol/description.js"
import type {FileInfo} from "./protocol/commands.js"
import {
  createXFTPChunk, addXFTPRecipients, uploadXFTPChunk, downloadXFTPChunk, downloadXFTPChunkRaw,
  deleteXFTPChunk, ackXFTPChunk, XFTPAgent
} from "./client.js"
export {XFTPAgent, type TransportConfig,
  XFTPRetriableError, XFTPPermanentError, isRetriable, categorizeError, humanReadableMessage} from "./client.js"
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

export interface EncryptForUploadOptions {
  onProgress?: (done: number, total: number) => void
  onSlice?: (data: Uint8Array) => void | Promise<void>
}

export async function encryptFileForUpload(
  source: Uint8Array, fileName: string,
  options: EncryptForUploadOptions & {onSlice: NonNullable<EncryptForUploadOptions['onSlice']>}
): Promise<EncryptedFileMetadata>
export async function encryptFileForUpload(
  source: Uint8Array, fileName: string,
  options?: EncryptForUploadOptions
): Promise<EncryptedFileInfo>
export async function encryptFileForUpload(
  source: Uint8Array,
  fileName: string,
  options?: EncryptForUploadOptions
): Promise<EncryptedFileInfo | EncryptedFileMetadata> {
  const {onProgress, onSlice} = options ?? {}
  const {fileHdr, key, nonce, fileSize, encSize, chunkSizes} = prepareEncryption(source.length, fileName)
  if (onSlice) {
    const hashState = sha512Init()
    await encryptFileAsync(source, fileHdr, key, nonce, fileSize, encSize, onProgress, (data) => {
      sha512Update(hashState, data)
      return onSlice(data)
    })
    const digest = sha512Final(hashState)
    return {digest, key, nonce, chunkSizes}
  } else {
    const encData = await encryptFileAsync(source, fileHdr, key, nonce, fileSize, encSize, onProgress)
    const digest = sha512Streaming([encData])
    console.log(`[AGENT-DBG] encrypt: encData.len=${encData.length} digest=${_dbgHex(digest, 64)} chunkSizes=[${chunkSizes.join(',')}]`)
    return {encData, digest, key, nonce, chunkSizes}
  }
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

async function uploadSingleChunk(
  agent: XFTPAgent, server: XFTPServer,
  chunkNo: number, chunkData: Uint8Array, chunkSize: number,
  numRecipients: number, auth: Uint8Array | null
): Promise<SentChunk> {
  const sndKp = generateEd25519KeyPair()
  const rcvKps = Array.from({length: numRecipients}, () => generateEd25519KeyPair())
  const chunkDigest = getChunkDigest(chunkData)
  const fileInfo: FileInfo = {
    sndKey: encodePubKeyEd25519(sndKp.publicKey),
    size: chunkSize,
    digest: chunkDigest
  }
  const firstBatch = Math.min(numRecipients, MAX_RECIPIENTS_PER_REQUEST)
  const firstBatchKeys = rcvKps.slice(0, firstBatch).map(kp => encodePubKeyEd25519(kp.publicKey))
  const {senderId, recipientIds: firstIds} = await createXFTPChunk(
    agent, server, sndKp.privateKey, fileInfo, firstBatchKeys, auth
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
  return {
    chunkNo, senderId, senderKey: sndKp.privateKey,
    recipients: allRecipientIds.map((rid, ri) => ({
      recipientId: rid, recipientKey: rcvKps[ri].privateKey
    })),
    chunkSize, digest: chunkDigest, server
  }
}

export async function uploadFile(
  agent: XFTPAgent,
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
      const chunkData = await readChunk(spec.chunkOffset, spec.chunkSize)
      sentChunks[index] = await uploadSingleChunk(agent, server, chunkNo, chunkData, spec.chunkSize, numRecipients, auth ?? null)
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

export interface SendFileOptions {
  onProgress?: (uploaded: number, total: number) => void
  auth?: Uint8Array
  numRecipients?: number
}

export async function sendFile(
  agent: XFTPAgent, servers: XFTPServer[],
  source: Uint8Array, fileName: string,
  options?: SendFileOptions
): Promise<UploadResult>
export async function sendFile(
  agent: XFTPAgent, servers: XFTPServer[],
  source: AsyncIterable<Uint8Array>, sourceSize: number,
  fileName: string, options?: SendFileOptions
): Promise<UploadResult>
export async function sendFile(
  agent: XFTPAgent, servers: XFTPServer[],
  source: Uint8Array | AsyncIterable<Uint8Array>,
  fileNameOrSize: string | number,
  fileNameOrOptions?: string | SendFileOptions,
  maybeOptions?: SendFileOptions
): Promise<UploadResult> {
  let sourceSize: number, fileName: string, options: SendFileOptions | undefined
  if (source instanceof Uint8Array) {
    sourceSize = source.length
    fileName = fileNameOrSize as string
    options = fileNameOrOptions as SendFileOptions | undefined
  } else {
    sourceSize = fileNameOrSize as number
    fileName = fileNameOrOptions as string
    options = maybeOptions
  }
  if (servers.length === 0) throw new Error("sendFile: servers list is empty")
  const {onProgress, auth, numRecipients = 1} = options ?? {}
  const params = prepareEncryption(sourceSize, fileName)
  const specs = prepareChunkSpecs(params.chunkSizes)
  const total = params.chunkSizes.reduce((a, b) => a + b, 0)

  const encState = sbInit(params.key, params.nonce)
  const hashState = sha512Init()

  const sentChunks: SentChunk[] = new Array(specs.length)
  let specIdx = 0, chunkOff = 0, uploaded = 0
  let chunkBuf = new Uint8Array(specs[0].chunkSize)

  async function flushChunk() {
    const server = servers[Math.floor(Math.random() * servers.length)]
    sentChunks[specIdx] = await uploadSingleChunk(
      agent, server, specIdx + 1, chunkBuf, specs[specIdx].chunkSize, numRecipients, auth ?? null
    )
    uploaded += specs[specIdx].chunkSize
    onProgress?.(uploaded, total)
    specIdx++
    if (specIdx < specs.length) {
      chunkBuf = new Uint8Array(specs[specIdx].chunkSize)
      chunkOff = 0
    }
  }

  async function feedEncrypted(data: Uint8Array) {
    sha512Update(hashState, data)
    let off = 0
    while (off < data.length) {
      const space = specs[specIdx].chunkSize - chunkOff
      const n = Math.min(space, data.length - off)
      chunkBuf.set(data.subarray(off, off + n), chunkOff)
      chunkOff += n
      off += n
      if (chunkOff === specs[specIdx].chunkSize) await flushChunk()
    }
  }

  await feedEncrypted(sbEncryptChunk(encState, concatBytes(encodeInt64(params.fileSize), params.fileHdr)))

  const SLICE = 65536
  if (source instanceof Uint8Array) {
    for (let off = 0; off < source.length; off += SLICE) {
      await feedEncrypted(sbEncryptChunk(encState, source.subarray(off, Math.min(off + SLICE, source.length))))
    }
  } else {
    for await (const chunk of source) {
      for (let off = 0; off < chunk.length; off += SLICE) {
        await feedEncrypted(sbEncryptChunk(encState, chunk.subarray(off, Math.min(off + SLICE, chunk.length))))
      }
    }
  }

  const padLen = Number(params.encSize - 16n - params.fileSize - 8n)
  const padding = new Uint8Array(padLen)
  padding.fill(0x23)
  await feedEncrypted(sbEncryptChunk(encState, padding))
  await feedEncrypted(sbAuth(encState))

  const digest = sha512Final(hashState)
  const encrypted: EncryptedFileMetadata = {digest, key: params.key, nonce: params.nonce, chunkSizes: params.chunkSizes}
  const rcvDescriptions = Array.from({length: numRecipients}, (_, ri) =>
    buildDescription("recipient", ri, encrypted, sentChunks)
  )
  const sndDescription = buildDescription("sender", 0, encrypted, sentChunks)
  let uri = encodeDescriptionURI(rcvDescriptions[0])
  let finalRcvDescriptions = rcvDescriptions
  if (uri.length > DEFAULT_REDIRECT_THRESHOLD && sentChunks.length > 1) {
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
  agent: XFTPAgent,
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
      const chunkData = enc.encData.subarray(spec.chunkOffset, spec.chunkOffset + spec.chunkSize)
      sentChunks[index] = await uploadSingleChunk(agent, server, chunkNo, chunkData, spec.chunkSize, 1, auth ?? null)
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
  agent: XFTPAgent,
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
  agent: XFTPAgent,
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

export async function receiveFile(
  agent: XFTPAgent,
  uri: string,
  options?: {onProgress?: (downloaded: number, total: number) => void}
): Promise<DownloadResult> {
  const fd = decodeDescriptionURI(uri)
  return downloadFile(agent, fd, options?.onProgress)
}

async function resolveRedirect(
  agent: XFTPAgent,
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

export async function deleteFile(agent: XFTPAgent, sndDescription: FileDescription): Promise<void> {
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
