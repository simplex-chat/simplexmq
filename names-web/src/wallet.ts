import {secp256k1} from "@noble/curves/secp256k1"
import {bytesToHex, utf8ToBytes} from "@noble/curves/utils"
import {keccak_256} from "@noble/hashes/sha3"
import {HDKey} from "@scure/bip32"
import {entropyToMnemonic, mnemonicToSeedSync} from "@scure/bip39"
import {wordlist} from "@scure/bip39/wordlists/english"

export interface Wallet {
  entropy: Uint8Array
  mnemonic: string
  privateKey: Uint8Array
  address: Uint8Array
}

export function walletFromEntropy(entropy: Uint8Array): Wallet {
  const mnemonic = entropyToMnemonic(entropy, wordlist)
  const seed = mnemonicToSeedSync(mnemonic)
  const privateKey = HDKey.fromMasterSeed(seed).derive("m/44'/60'/0'/0/0").privateKey!
  const address = keccak_256(secp256k1.getPublicKey(privateKey, false).slice(1)).slice(12)
  return {entropy, mnemonic, privateKey, address}
}

export function checksumAddress(address: Uint8Array): string {
  const hex = bytesToHex(address)
  const hash = bytesToHex(keccak_256(utf8ToBytes(hex)))
  return "0x" + [...hex].map((c, i) => (parseInt(hash[i], 16) >= 8 ? c.toUpperCase() : c)).join("")
}

export function signDigest(privateKey: Uint8Array, digest: Uint8Array): Uint8Array {
  const sig = secp256k1.sign(digest, privateKey)
  return new Uint8Array([...sig.toBytes("compact"), 27 + sig.recovery])
}
