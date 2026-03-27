// Agent protocol types and short link parsing.
// Mirrors: Simplex.Messaging.Agent.Protocol

import {base64urlDecode} from "@simplex-chat/xftp-web/dist/protocol/description.js"

// -- Short link types (Agent/Protocol.hs:1462-1470)

export type ShortLinkScheme = "simplex" | "https"

export type ContactConnType = "contact" | "channel" | "group" | "relay"

export interface ShortLinkServer {
  hosts: string[]
  port: string
  keyHash: Uint8Array
}

export type ConnShortLink =
  | {mode: "invitation", scheme: ShortLinkScheme, server: ShortLinkServer, linkId: Uint8Array, linkKey: Uint8Array}
  | {mode: "contact", scheme: ShortLinkScheme, connType: ContactConnType, server: ShortLinkServer, linkKey: Uint8Array}

// -- Contact type char mapping (Agent/Protocol.hs:1651-1666)

const ctTypeFromChar: Record<string, ContactConnType> = {
  a: "contact",
  c: "channel",
  g: "group",
  r: "relay",
}

// -- Short link parser (Agent/Protocol.hs:1596-1629)
// Mirrors strP for AConnShortLink

export function connShortLinkStrP(uri: string): ConnShortLink {
  let scheme: ShortLinkScheme
  let firstHost: string | null = null
  let rest: string

  if (uri.startsWith("simplex:")) {
    scheme = "simplex"
    rest = uri.slice("simplex:".length)
  } else if (uri.startsWith("https://")) {
    scheme = "https"
    const afterScheme = uri.slice("https://".length)
    const slashIdx = afterScheme.indexOf("/")
    if (slashIdx < 0) throw new Error("bad short link: no path")
    firstHost = afterScheme.slice(0, slashIdx)
    rest = afterScheme.slice(slashIdx)
  } else {
    throw new Error("bad short link scheme")
  }

  // rest: /typeChar#fragment?query
  if (rest[0] !== "/") throw new Error("bad short link: expected /")
  const typeChar = rest[1]
  const hashIdx = rest.indexOf("#")
  if (hashIdx < 0) throw new Error("bad short link: no #")
  const afterHash = rest.slice(hashIdx + 1)

  const qIdx = afterHash.indexOf("?")
  const fragment = qIdx >= 0 ? afterHash.slice(0, qIdx) : afterHash
  const queryStr = qIdx >= 0 ? afterHash.slice(qIdx + 1) : ""
  const params = new URLSearchParams(queryStr)

  // Build server
  const hParam = params.get("h")
  const additionalHosts = hParam ? hParam.split(",") : []
  const allHosts = firstHost ? [firstHost, ...additionalHosts] : additionalHosts
  if (allHosts.length === 0) throw new Error("short link without server")

  const port = params.get("p") ?? ""
  const keyHash = params.has("c") ? base64urlDecode(params.get("c")!) : new Uint8Array(0)
  const server: ShortLinkServer = {hosts: allHosts, port, keyHash}

  if (typeChar === "i") {
    const slashIdx = fragment.indexOf("/")
    if (slashIdx < 0) throw new Error("invitation link must have linkId/linkKey")
    const linkId = base64urlDecode(fragment.slice(0, slashIdx))
    const linkKey = base64urlDecode(fragment.slice(slashIdx + 1))
    return {mode: "invitation", scheme, server, linkId, linkKey}
  } else {
    const connType = ctTypeFromChar[typeChar]
    if (!connType) throw new Error("unknown contact type: " + typeChar)
    const linkKey = base64urlDecode(fragment)
    return {mode: "contact", scheme, connType, server, linkKey}
  }
}
