// XFTP server address parsing/formatting -- Simplex.Messaging.Protocol (ProtocolServer)
//
// Parses/formats server address strings of the form:
//   xftp://<keyhash>@<host>[,<host2>,...][:<port>]
//
// KeyHash is base64url-encoded SHA-256 fingerprint of the identity certificate.

import {base64urlEncode} from "./description.js"

export interface XFTPServer {
  keyHash: Uint8Array  // 32-byte SHA-256 fingerprint (decoded from base64url)
  host: string         // primary hostname
  port: string         // port number (default "443")
}

// Decode base64url (RFC 4648 section 5) to Uint8Array.
function base64urlDecode(s: string): Uint8Array {
  // Convert base64url to standard base64
  let b64 = s.replace(/-/g, '+').replace(/_/g, '/')
  // Add padding if needed
  while (b64.length % 4 !== 0) b64 += '='
  const bin = atob(b64)
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
  return bytes
}

// Parse an XFTP server address string.
// Format: xftp://<base64url-keyhash>@<host>[,<host2>,...][:<port>]
export function parseXFTPServer(address: string): XFTPServer {
  const m = address.match(/^xftp:\/\/([A-Za-z0-9_-]+={0,2})@(.+)$/)
  if (!m) throw new Error("parseXFTPServer: invalid address format")
  const keyHash = base64urlDecode(m[1])
  if (keyHash.length !== 32) throw new Error("parseXFTPServer: keyHash must be 32 bytes")
  const hostPart = m[2]
  // Take the first host (before any comma), then split port from that
  const firstHost = hostPart.split(',')[0]
  const colonIdx = firstHost.lastIndexOf(':')
  let host: string
  let port: string
  if (colonIdx > 0) {
    host = firstHost.substring(0, colonIdx)
    port = firstHost.substring(colonIdx + 1)
  } else {
    host = firstHost
    port = "443"
  }
  return {keyHash, host, port}
}

// Format an XFTPServer back to its URI string representation.
export function formatXFTPServer(srv: XFTPServer): string {
  return "xftp://" + base64urlEncode(srv.keyHash) + "@" + srv.host + ":" + srv.port
}
