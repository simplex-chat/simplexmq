import {secp256k1} from "@noble/curves/secp256k1"
import {keccak_256} from "@noble/hashes/sha3"
import {HDKey} from "@scure/bip32"
import {entropyToMnemonic, mnemonicToSeedSync} from "@scure/bip39"
import {wordlist} from "@scure/bip39/wordlists/english"

export interface Wallet {
  entropy: Uint8Array
  privateKey: Uint8Array
  address: Uint8Array
}

export function walletFromEntropy(entropy: Uint8Array): Wallet {
  const seed = mnemonicToSeedSync(entropyToMnemonic(entropy, wordlist))
  const privateKey = HDKey.fromMasterSeed(seed).derive("m/44'/60'/0'/0/0").privateKey!
  const address = keccak_256(secp256k1.getPublicKey(privateKey, false).slice(1)).slice(12)
  return {entropy, privateKey, address}
}

export function signDigest(privateKey: Uint8Array, digest: Uint8Array): Uint8Array {
  const sig = secp256k1.sign(digest, privateKey)
  return new Uint8Array([...sig.toBytes("compact"), 27 + sig.recovery])
}
