// XFTP upload/download orchestration + URI encoding — Simplex.FileTransfer.Client.Main
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
  connectXFTP, createXFTPChunk, uploadXFTPChunk, downloadXFTPChunk,
  ackXFTPChunk, deleteXFTPChunk, closeXFTP, type XFTPClient
} from "./client.js"
import {processDownloadedFile} from "./download.js"
import type {XFTPServer} from "./protocol/address.js"
import {formatXFTPServer} from "./protocol/address.js"
import {concatBytes} from "./protocol/encoding.js"
import type {FileHeader} from "./crypto/file.js"

// ── Types ───────────────────────────────────────────────────────

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

export interface EncryptedFileInfo {
  encData: Uint8Array
  digest: Uint8Array          // SHA-512 of encData
  key: Uint8Array             // 32B SbKey
  nonce: Uint8Array           // 24B CbNonce
  chunkSizes: number[]
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

// ── URI encoding/decoding (RFC §4.1: DEFLATE + base64url) ───────

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

// ── Upload ──────────────────────────────────────────────────────

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

export async function uploadFile(
  server: XFTPServer,
  encrypted: EncryptedFileInfo,
  onProgress?: (uploaded: number, total: number) => void,
  redirectThreshold?: number
): Promise<UploadResult> {
  const specs = prepareChunkSpecs(encrypted.chunkSizes)
  const client = await connectXFTP(server)
  const sentChunks: SentChunk[] = []
  let uploaded = 0
  try {
    for (let i = 0; i < specs.length; i++) {
      const spec = specs[i]
      const chunkNo = i + 1
      const sndKp = generateEd25519KeyPair()
      const rcvKp = generateEd25519KeyPair()
      const chunkData = encrypted.encData.subarray(spec.chunkOffset, spec.chunkOffset + spec.chunkSize)
      const chunkDigest = getChunkDigest(chunkData)
      const fileInfo: FileInfo = {
        sndKey: encodePubKeyEd25519(sndKp.publicKey),
        size: spec.chunkSize,
        digest: chunkDigest
      }
      const {senderId, recipientIds} = await createXFTPChunk(
        client, sndKp.privateKey, fileInfo, [encodePubKeyEd25519(rcvKp.publicKey)]
      )
      await uploadXFTPChunk(client, sndKp.privateKey, senderId, chunkData)
      sentChunks.push({
        chunkNo, senderId, senderKey: sndKp.privateKey,
        recipientId: recipientIds[0], recipientKey: rcvKp.privateKey,
        chunkSize: spec.chunkSize, digest: chunkDigest, server
      })
      uploaded += spec.chunkSize
      onProgress?.(uploaded, encrypted.encData.length)
    }
    const rcvDescription = buildDescription("recipient", encrypted, sentChunks)
    const sndDescription = buildDescription("sender", encrypted, sentChunks)
    let uri = encodeDescriptionURI(rcvDescription)
    let finalRcvDescription = rcvDescription
    const threshold = redirectThreshold ?? DEFAULT_REDIRECT_THRESHOLD
    if (uri.length > threshold && sentChunks.length > 1) {
      finalRcvDescription = await uploadRedirectDescription(client, server, rcvDescription)
      uri = encodeDescriptionURI(finalRcvDescription)
    }
    return {rcvDescription: finalRcvDescription, sndDescription, uri}
  } finally {
    closeXFTP(client)
  }
}

function buildDescription(
  party: "recipient" | "sender",
  enc: EncryptedFileInfo,
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
  client: XFTPClient,
  server: XFTPServer,
  innerFd: FileDescription
): Promise<FileDescription> {
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
    const {senderId, recipientIds} = await createXFTPChunk(
      client, sndKp.privateKey, fileInfo, [encodePubKeyEd25519(rcvKp.publicKey)]
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

// ── Download ────────────────────────────────────────────────────

export async function downloadFile(
  fd: FileDescription,
  onProgress?: (downloaded: number, total: number) => void
): Promise<DownloadResult> {
  const err = validateFileDescription(fd)
  if (err) throw new Error("downloadFile: " + err)
  if (fd.redirect !== null) {
    return downloadWithRedirect(fd, onProgress)
  }
  const connections = new Map<string, XFTPClient>()
  try {
    const plaintextChunks: Uint8Array[] = new Array(fd.chunks.length)
    let downloaded = 0
    for (const chunk of fd.chunks) {
      const replica = chunk.replicas[0]
      if (!replica) throw new Error("downloadFile: chunk has no replicas")
      const client = await getOrConnect(connections, replica.server)
      const seed = decodePrivKeyEd25519(replica.replicaKey)
      const kp = ed25519KeyPairFromSeed(seed)
      const data = await downloadXFTPChunk(client, kp.privateKey, replica.replicaId, chunk.digest)
      plaintextChunks[chunk.chunkNo - 1] = data
      downloaded += chunk.chunkSize
      onProgress?.(downloaded, fd.size)
    }
    // Verify file size
    const totalSize = plaintextChunks.reduce((s, c) => s + c.length, 0)
    if (totalSize !== fd.size) throw new Error("downloadFile: file size mismatch")
    // Verify file digest (SHA-512 of encrypted file data)
    const combined = plaintextChunks.length === 1 ? plaintextChunks[0] : concatBytes(...plaintextChunks)
    const digest = sha512(combined)
    if (!digestEqual(digest, fd.digest)) throw new Error("downloadFile: file digest mismatch")
    // Decrypt
    const result = processDownloadedFile(fd, plaintextChunks)
    // ACK all chunks (best-effort)
    for (const chunk of fd.chunks) {
      const replica = chunk.replicas[0]
      if (!replica) continue
      try {
        const client = connections.get(replica.server)
        if (!client) continue
        const seed = decodePrivKeyEd25519(replica.replicaKey)
        const kp = ed25519KeyPairFromSeed(seed)
        await ackXFTPChunk(client, kp.privateKey, replica.replicaId)
      } catch (_) {}
    }
    return result
  } finally {
    for (const c of connections.values()) closeXFTP(c)
  }
}

async function downloadWithRedirect(
  fd: FileDescription,
  onProgress?: (downloaded: number, total: number) => void
): Promise<DownloadResult> {
  const connections = new Map<string, XFTPClient>()
  try {
    const plaintextChunks: Uint8Array[] = new Array(fd.chunks.length)
    for (const chunk of fd.chunks) {
      const replica = chunk.replicas[0]
      if (!replica) throw new Error("downloadWithRedirect: chunk has no replicas")
      const client = await getOrConnect(connections, replica.server)
      const seed = decodePrivKeyEd25519(replica.replicaKey)
      const kp = ed25519KeyPairFromSeed(seed)
      const data = await downloadXFTPChunk(client, kp.privateKey, replica.replicaId, chunk.digest)
      plaintextChunks[chunk.chunkNo - 1] = data
    }
    const totalSize = plaintextChunks.reduce((s, c) => s + c.length, 0)
    if (totalSize !== fd.size) throw new Error("downloadWithRedirect: redirect file size mismatch")
    const combined = plaintextChunks.length === 1 ? plaintextChunks[0] : concatBytes(...plaintextChunks)
    const digest = sha512(combined)
    if (!digestEqual(digest, fd.digest)) throw new Error("downloadWithRedirect: redirect file digest mismatch")
    const {content: yamlBytes} = processDownloadedFile(fd, plaintextChunks)
    const innerFd = decodeFileDescription(new TextDecoder().decode(yamlBytes))
    const innerErr = validateFileDescription(innerFd)
    if (innerErr) throw new Error("downloadWithRedirect: inner description invalid: " + innerErr)
    if (innerFd.size !== fd.redirect!.size) throw new Error("downloadWithRedirect: redirect size mismatch")
    if (!digestEqual(innerFd.digest, fd.redirect!.digest)) throw new Error("downloadWithRedirect: redirect digest mismatch")
    for (const chunk of fd.chunks) {
      const replica = chunk.replicas[0]
      if (!replica) continue
      try {
        const client = connections.get(replica.server)
        if (!client) continue
        const seed = decodePrivKeyEd25519(replica.replicaKey)
        const kp = ed25519KeyPairFromSeed(seed)
        await ackXFTPChunk(client, kp.privateKey, replica.replicaId)
      } catch (_) {}
    }
    for (const c of connections.values()) closeXFTP(c)
    return downloadFile(innerFd, onProgress)
  } catch (e) {
    for (const c of connections.values()) closeXFTP(c)
    throw e
  }
}

// ── Delete ──────────────────────────────────────────────────────

export async function deleteFile(sndDescription: FileDescription): Promise<void> {
  const connections = new Map<string, XFTPClient>()
  try {
    for (const chunk of sndDescription.chunks) {
      const replica = chunk.replicas[0]
      if (!replica) throw new Error("deleteFile: chunk has no replicas")
      const client = await getOrConnect(connections, replica.server)
      const seed = decodePrivKeyEd25519(replica.replicaKey)
      const kp = ed25519KeyPairFromSeed(seed)
      await deleteXFTPChunk(client, kp.privateKey, replica.replicaId)
    }
  } finally {
    for (const c of connections.values()) closeXFTP(c)
  }
}

// ── Internal ────────────────────────────────────────────────────

import {parseXFTPServer} from "./protocol/address.js"

async function getOrConnect(
  connections: Map<string, XFTPClient>,
  serverStr: string
): Promise<XFTPClient> {
  let c = connections.get(serverStr)
  if (!c) {
    c = await connectXFTP(parseXFTPServer(serverStr))
    connections.set(serverStr, c)
  }
  return c
}

function digestEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i]
  return diff === 0
}
