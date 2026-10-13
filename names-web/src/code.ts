import {sha256} from "@noble/hashes/sha2"
import {bytesToNumberBE, numberToBytesBE} from "@noble/curves/utils"

const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
const PREFIX = "SN"
const CODE_LENGTH = 30
const CHECKSUM_BITS = 22n

export function formatNameCode(entropy: Uint8Array): string {
  let n = (bytesToNumberBE(entropy) << CHECKSUM_BITS) + checksum(entropy)
  let body = ""
  for (let i = 0; i < CODE_LENGTH; i++) {
    body = ALPHABET[Number(n % 32n)] + body
    n /= 32n
  }
  return [PREFIX, ...body.match(/.{5}/g)!].join("-")
}

export function parseNameCode(code: string): Uint8Array | null {
  const cleaned = code.replace(/[^\p{L}\p{N}]/gu, "").toUpperCase()
  if (!cleaned.startsWith(PREFIX) || cleaned.length !== PREFIX.length + CODE_LENGTH) return null
  let n = 0n
  for (const c of cleaned.slice(PREFIX.length)) {
    const v = charValue(c)
    if (v === undefined) return null
    n = n * 32n + BigInt(v)
  }
  const entropy = numberToBytesBE(n >> CHECKSUM_BITS, 16)
  return n % (1n << CHECKSUM_BITS) === checksum(entropy) ? entropy : null
}

function charValue(c: string): number | undefined {
  if (c === "I" || c === "L") return 1
  if (c === "O") return 0
  const v = ALPHABET.indexOf(c)
  return v < 0 ? undefined : v
}

function checksum(entropy: Uint8Array): bigint {
  return bytesToNumberBE(sha256(entropy)) >> (256n - CHECKSUM_BITS)
}
