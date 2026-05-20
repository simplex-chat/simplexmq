// SNTRUP761 post-quantum KEM.
// Mirrors: Simplex.Messaging.Crypto.SNTRUP761
//
// Uses WASM compiled from the same C source as the Haskell build
// (cbits/sntrup761.c by djb et al., public domain).
// SHA-512 from SUPERCOP/NaCl (djb, public domain).

// Key sizes (from sntrup761.h)
export const SNTRUP761_PUBLICKEY_SIZE = 1158
export const SNTRUP761_SECRETKEY_SIZE = 1763
export const SNTRUP761_CIPHERTEXT_SIZE = 1039
export const SNTRUP761_SIZE = 32 // shared secret

export interface KEMKeyPair {
  publicKey: Uint8Array  // 1158 bytes
  secretKey: Uint8Array  // 1763 bytes
}

export interface KEMEncResult {
  ciphertext: Uint8Array  // 1039 bytes
  sharedSecret: Uint8Array // 32 bytes
}

// WASM module instance
let wasmModule: any = null

export async function initSntrup761(): Promise<void> {
  if (wasmModule) return
  const createSntrup761 = (await import("../../dist/wasm/sntrup761.mjs")).default
  wasmModule = await createSntrup761()
}

function getModule(): any {
  if (!wasmModule) throw new Error("sntrup761 WASM not initialized - call initSntrup761() first")
  return wasmModule
}

export function sntrup761Keypair(): KEMKeyPair {
  const m = getModule()
  const pkPtr = m._malloc(SNTRUP761_PUBLICKEY_SIZE)
  const skPtr = m._malloc(SNTRUP761_SECRETKEY_SIZE)
  try {
    m._sntrup761_wasm_keypair(pkPtr, skPtr)
    const publicKey = new Uint8Array(m.HEAPU8.buffer, pkPtr, SNTRUP761_PUBLICKEY_SIZE).slice()
    const secretKey = new Uint8Array(m.HEAPU8.buffer, skPtr, SNTRUP761_SECRETKEY_SIZE).slice()
    return {publicKey, secretKey}
  } finally {
    m._free(pkPtr)
    m._free(skPtr)
  }
}

export function sntrup761Enc(publicKey: Uint8Array): KEMEncResult {
  if (publicKey.length !== SNTRUP761_PUBLICKEY_SIZE) throw new Error("bad public key length")
  const m = getModule()
  const pkPtr = m._malloc(SNTRUP761_PUBLICKEY_SIZE)
  const ctPtr = m._malloc(SNTRUP761_CIPHERTEXT_SIZE)
  const ssPtr = m._malloc(SNTRUP761_SIZE)
  try {
    m.HEAPU8.set(publicKey, pkPtr)
    m._sntrup761_wasm_enc(ctPtr, ssPtr, pkPtr)
    const ciphertext = new Uint8Array(m.HEAPU8.buffer, ctPtr, SNTRUP761_CIPHERTEXT_SIZE).slice()
    const sharedSecret = new Uint8Array(m.HEAPU8.buffer, ssPtr, SNTRUP761_SIZE).slice()
    return {ciphertext, sharedSecret}
  } finally {
    m._free(pkPtr)
    m._free(ctPtr)
    m._free(ssPtr)
  }
}

export function sntrup761Dec(ciphertext: Uint8Array, secretKey: Uint8Array): Uint8Array {
  if (ciphertext.length !== SNTRUP761_CIPHERTEXT_SIZE) throw new Error("bad ciphertext length")
  if (secretKey.length !== SNTRUP761_SECRETKEY_SIZE) throw new Error("bad secret key length")
  const m = getModule()
  const ctPtr = m._malloc(SNTRUP761_CIPHERTEXT_SIZE)
  const skPtr = m._malloc(SNTRUP761_SECRETKEY_SIZE)
  const ssPtr = m._malloc(SNTRUP761_SIZE)
  try {
    m.HEAPU8.set(ciphertext, ctPtr)
    m.HEAPU8.set(secretKey, skPtr)
    m._sntrup761_wasm_dec(ssPtr, ctPtr, skPtr)
    return new Uint8Array(m.HEAPU8.buffer, ssPtr, SNTRUP761_SIZE).slice()
  } finally {
    m._free(ctPtr)
    m._free(skPtr)
    m._free(ssPtr)
  }
}
