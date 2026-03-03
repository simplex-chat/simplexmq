// XFTP file description encoding/decoding -- Simplex.FileTransfer.Description
//
// Handles YAML-encoded file descriptions matching Haskell Data.Yaml output format.
// Base64url encoding matches Haskell Data.ByteString.Base64.URL.encode (with padding).

// -- Base64url (RFC 4648 section 5) with '=' padding

const B64URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
const B64_DECODE = new Uint8Array(128)
B64_DECODE.fill(0xff)
for (let i = 0; i < 64; i++) B64_DECODE[B64URL.charCodeAt(i)] = i

export function base64urlEncode(data: Uint8Array): string {
  let result = ""
  const len = data.length
  let i = 0
  for (; i + 2 < len; i += 3) {
    const b0 = data[i], b1 = data[i + 1], b2 = data[i + 2]
    result += B64URL[b0 >>> 2]
    result += B64URL[((b0 & 3) << 4) | (b1 >>> 4)]
    result += B64URL[((b1 & 15) << 2) | (b2 >>> 6)]
    result += B64URL[b2 & 63]
  }
  if (i < len) {
    const b0 = data[i]
    result += B64URL[b0 >>> 2]
    if (i + 1 < len) {
      const b1 = data[i + 1]
      result += B64URL[((b0 & 3) << 4) | (b1 >>> 4)]
      result += B64URL[(b1 & 15) << 2]
      result += "="
    } else {
      result += B64URL[(b0 & 3) << 4]
      result += "=="
    }
  }
  return result
}

export function base64urlDecode(s: string): Uint8Array {
  let end = s.length
  while (end > 0 && s.charCodeAt(end - 1) === 0x3d) end-- // strip '='
  const n = end
  const out = new Uint8Array((n * 3) >>> 2)
  let j = 0, i = 0
  for (; i + 3 < n; i += 4) {
    const a = B64_DECODE[s.charCodeAt(i)], b = B64_DECODE[s.charCodeAt(i + 1)]
    const c = B64_DECODE[s.charCodeAt(i + 2)], d = B64_DECODE[s.charCodeAt(i + 3)]
    out[j++] = (a << 2) | (b >>> 4)
    out[j++] = ((b & 15) << 4) | (c >>> 2)
    out[j++] = ((c & 3) << 6) | d
  }
  if (n - i >= 2) {
    const a = B64_DECODE[s.charCodeAt(i)], b = B64_DECODE[s.charCodeAt(i + 1)]
    out[j++] = (a << 2) | (b >>> 4)
    if (n - i >= 3) {
      const c = B64_DECODE[s.charCodeAt(i + 2)]
      out[j++] = ((b & 15) << 4) | (c >>> 2)
    }
  }
  return out
}

// -- FileSize encoding/decoding

export const kb = (n: number): number => n * 1024
export const mb = (n: number): number => n * 1048576
export const gb = (n: number): number => n * 1073741824

export function encodeFileSize(bytes: number): string {
  const ks = Math.floor(bytes / 1024)
  if (bytes % 1024 !== 0) return String(bytes)
  const ms = Math.floor(ks / 1024)
  if (ks % 1024 !== 0) return ks + "kb"
  const gs = Math.floor(ms / 1024)
  if (ms % 1024 !== 0) return ms + "mb"
  return gs + "gb"
}

export function decodeFileSize(s: string): number {
  if (s.endsWith("gb")) return parseInt(s) * 1073741824
  if (s.endsWith("mb")) return parseInt(s) * 1048576
  if (s.endsWith("kb")) return parseInt(s) * 1024
  return parseInt(s)
}

// -- Types

export type FileParty = "recipient" | "sender"

export interface FileDescription {
  party: FileParty
  size: number           // total file size in bytes
  digest: Uint8Array     // SHA-512 file digest
  key: Uint8Array        // SbKey (32 bytes)
  nonce: Uint8Array      // CbNonce (24 bytes)
  chunkSize: number      // default chunk size in bytes
  chunks: FileChunk[]
  redirect: RedirectFileInfo | null
}

export interface RedirectFileInfo {
  size: number
  digest: Uint8Array
}

export interface FileChunk {
  chunkNo: number
  chunkSize: number
  digest: Uint8Array
  replicas: FileChunkReplica[]
}

export interface FileChunkReplica {
  server: string         // XFTPServer URI (e.g. "xftp://abc=@example.com")
  replicaId: Uint8Array
  replicaKey: Uint8Array // DER-encoded private key
}

// -- Internal: flat server replica

interface FileServerReplica {
  chunkNo: number
  server: string
  replicaId: Uint8Array
  replicaKey: Uint8Array
  digest: Uint8Array | null
  chunkSize: number | null
}

// -- Server replica colon-separated format

function encodeServerReplica(r: FileServerReplica): string {
  let s = r.chunkNo + ":" + base64urlEncode(r.replicaId) + ":" + base64urlEncode(r.replicaKey)
  if (r.digest !== null) s += ":" + base64urlEncode(r.digest)
  if (r.chunkSize !== null) s += ":" + encodeFileSize(r.chunkSize)
  return s
}

function decodeServerReplica(server: string, s: string): FileServerReplica {
  const parts = s.split(":")
  if (parts.length < 3) throw new Error("invalid server replica: " + s)
  return {
    chunkNo: parseInt(parts[0]),
    server,
    replicaId: base64urlDecode(parts[1]),
    replicaKey: base64urlDecode(parts[2]),
    digest: parts.length >= 4 ? base64urlDecode(parts[3]) : null,
    chunkSize: parts.length >= 5 ? decodeFileSize(parts[4]) : null
  }
}

// -- Unfold chunks to flat replicas

function unfoldChunksToReplicas(defChunkSize: number, chunks: FileChunk[]): FileServerReplica[] {
  const result: FileServerReplica[] = []
  for (const c of chunks) {
    c.replicas.forEach((r, idx) => {
      result.push({
        chunkNo: c.chunkNo,
        server: r.server,
        replicaId: r.replicaId,
        replicaKey: r.replicaKey,
        digest: idx === 0 ? c.digest : null,
        chunkSize: c.chunkSize !== defChunkSize && idx === 0 ? c.chunkSize : null
      })
    })
  }
  return result
}

// -- Group replicas by server (for YAML encoding)

function encodeFileReplicas(
  defChunkSize: number, chunks: FileChunk[]
): {server: string, chunks: string[]}[] {
  const flat = unfoldChunksToReplicas(defChunkSize, chunks)
  // Sort by server URI string (matches Haskell Ord for ProtocolServer when
  // all servers share the same scheme and keyHash -- true for typical use).
  flat.sort((a, b) => a.server < b.server ? -1 : a.server > b.server ? 1 : 0)
  const groups: {server: string, chunks: string[]}[] = []
  for (const r of flat) {
    if (groups.length === 0 || groups[groups.length - 1].server !== r.server) {
      groups.push({server: r.server, chunks: [encodeServerReplica(r)]})
    } else {
      groups[groups.length - 1].chunks.push(encodeServerReplica(r))
    }
  }
  return groups
}

// -- Fold flat replicas back into FileChunks

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}

function foldReplicasToChunks(defChunkSize: number, replicas: FileServerReplica[]): FileChunk[] {
  const sizes = new Map<number, number>()
  const digests = new Map<number, Uint8Array>()
  for (const r of replicas) {
    if (r.chunkSize !== null) {
      const existing = sizes.get(r.chunkNo)
      if (existing !== undefined && existing !== r.chunkSize)
        throw new Error("different size in chunk replicas")
      sizes.set(r.chunkNo, r.chunkSize)
    }
    if (r.digest !== null) {
      const existing = digests.get(r.chunkNo)
      if (existing !== undefined && !bytesEqual(existing, r.digest))
        throw new Error("different digest in chunk replicas")
      digests.set(r.chunkNo, r.digest)
    }
  }
  const chunkMap = new Map<number, FileChunk>()
  for (const r of replicas) {
    const existing = chunkMap.get(r.chunkNo)
    if (existing) {
      existing.replicas.push({server: r.server, replicaId: r.replicaId, replicaKey: r.replicaKey})
    } else {
      const digest = digests.get(r.chunkNo)
      if (!digest) throw new Error("no digest for chunk")
      chunkMap.set(r.chunkNo, {
        chunkNo: r.chunkNo,
        chunkSize: sizes.get(r.chunkNo) ?? defChunkSize,
        digest,
        replicas: [{server: r.server, replicaId: r.replicaId, replicaKey: r.replicaKey}]
      })
    }
  }
  return Array.from(chunkMap.values()).sort((a, b) => a.chunkNo - b.chunkNo)
}

// -- YAML encoding (matching Data.Yaml key ordering)

export function encodeFileDescription(fd: FileDescription): string {
  const lines: string[] = []
  // Top-level keys in alphabetical order (matching Data.Yaml / libyaml)
  lines.push("chunkSize: " + encodeFileSize(fd.chunkSize))
  lines.push("digest: " + base64urlEncode(fd.digest))
  lines.push("key: " + base64urlEncode(fd.key))
  lines.push("nonce: " + base64urlEncode(fd.nonce))
  lines.push("party: " + fd.party)
  if (fd.redirect !== null) {
    lines.push("redirect:")
    lines.push("  digest: " + base64urlEncode(fd.redirect.digest))
    lines.push("  size: " + fd.redirect.size)
  }
  const groups = encodeFileReplicas(fd.chunkSize, fd.chunks)
  lines.push("replicas:")
  for (const g of groups) {
    lines.push("- chunks:")
    for (const c of g.chunks) {
      lines.push("  - " + c)
    }
    lines.push("  server: " + g.server)
  }
  lines.push("size: " + encodeFileSize(fd.size))
  return lines.join("\n") + "\n"
}

// -- YAML decoding

export function decodeFileDescription(yaml: string): FileDescription {
  const lines = yaml.split("\n")
  const topLevel: Record<string, string> = {}
  const replicaGroups: {server: string, chunks: string[]}[] = []
  let redirect: RedirectFileInfo | null = null
  let i = 0
  while (i < lines.length) {
    const line = lines[i]
    if (line.length === 0) { i++; continue }
    if (line === "replicas:") {
      i++
      while (i < lines.length && lines[i].startsWith("- ")) {
        const group = {server: "", chunks: [] as string[]}
        i = parseReplicaItem(lines, i, group)
        replicaGroups.push(group)
      }
    } else if (line === "redirect:") {
      i++
      let digestStr = "", sizeStr = ""
      while (i < lines.length && lines[i].startsWith("  ")) {
        const kv = lines[i].substring(2)
        const ci = kv.indexOf(": ")
        if (ci >= 0) {
          const k = kv.substring(0, ci), v = kv.substring(ci + 2)
          if (k === "digest") digestStr = v
          if (k === "size") sizeStr = v
        }
        i++
      }
      redirect = {size: parseInt(sizeStr), digest: base64urlDecode(digestStr)}
    } else {
      const ci = line.indexOf(": ")
      if (ci >= 0) topLevel[line.substring(0, ci)] = line.substring(ci + 2)
      i++
    }
  }
  const chunkSize = decodeFileSize(topLevel["chunkSize"])
  const serverReplicas: FileServerReplica[] = []
  for (const g of replicaGroups) {
    for (const c of g.chunks) serverReplicas.push(decodeServerReplica(g.server, c))
  }
  return {
    party: topLevel["party"] as FileParty,
    size: decodeFileSize(topLevel["size"]),
    digest: base64urlDecode(topLevel["digest"]),
    key: base64urlDecode(topLevel["key"]),
    nonce: base64urlDecode(topLevel["nonce"]),
    chunkSize,
    chunks: foldReplicasToChunks(chunkSize, serverReplicas),
    redirect
  }
}

function parseReplicaItem(
  lines: string[], startIdx: number, group: {server: string, chunks: string[]}
): number {
  let i = startIdx
  const first = lines[i].substring(2) // strip "- " prefix
  i = parseReplicaField(first, lines, i + 1, group)
  while (i < lines.length && lines[i].startsWith("  ") && !lines[i].startsWith("- ")) {
    i = parseReplicaField(lines[i].substring(2), lines, i + 1, group)
  }
  return i
}

function parseReplicaField(
  entry: string, lines: string[], nextIdx: number,
  group: {server: string, chunks: string[]}
): number {
  if (entry === "chunks:" || entry.startsWith("chunks:")) {
    let i = nextIdx
    while (i < lines.length && lines[i].startsWith("  - ")) {
      group.chunks.push(lines[i].substring(4))
      i++
    }
    return i
  }
  const ci = entry.indexOf(": ")
  if (ci >= 0) {
    const k = entry.substring(0, ci), v = entry.substring(ci + 2)
    if (k === "server") group.server = v
  }
  return nextIdx
}

// -- Validation

export function validateFileDescription(fd: FileDescription): string | null {
  for (let i = 0; i < fd.chunks.length; i++) {
    if (fd.chunks[i].chunkNo !== i + 1) return "chunk numbers are not sequential"
  }
  let total = 0
  for (const c of fd.chunks) total += c.chunkSize
  if (total !== fd.size) return "chunks total size is different than file size"
  return null
}

export const fdSeparator = "################################\n"
