import {concatBytes, numberToBytesBE, utf8ToBytes} from "@noble/curves/utils"
import {keccak_256} from "@noble/hashes/sha3"

export interface Registration {
  label: string
  tld: string
  owner: Uint8Array
  duration: bigint
  secret: Uint8Array
  resolver: Uint8Array
  contactLinks: string[]
  channelLinks: string[]
}

export function makeCommitment(r: Registration): Uint8Array {
  return keccak_256(abiTuple([dynamic(registrationTuple(r))]))
}

export function registerIntentDigest(chainId: bigint, sponsor: Uint8Array, r: Registration, nonce: bigint, deadline: bigint): Uint8Array {
  const domain = hashStruct("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)", [
    keccak_256(utf8ToBytes("SimplexSponsor")),
    keccak_256(utf8ToBytes("1")),
    uint256(chainId),
    addressWord(sponsor),
  ])
  const intent = hashStruct("RegisterName(string label,address owner,address resolver,bytes[] data,uint256 nonce,uint256 deadline)", [
    keccak_256(utf8ToBytes(r.label)),
    addressWord(r.owner),
    addressWord(r.resolver),
    keccak_256(concatBytes(...recordCalls(r).map(keccak_256))),
    uint256(nonce),
    uint256(deadline),
  ])
  return keccak_256(concatBytes(new Uint8Array([0x19, 0x01]), domain, intent))
}

function hashStruct(typeString: string, words: Uint8Array[]): Uint8Array {
  return keccak_256(concatBytes(keccak_256(utf8ToBytes(typeString)), ...words))
}

function registrationTuple(r: Registration): Uint8Array {
  const reverseRecord = uint256(0n)
  const referrer = new Uint8Array(32)
  return abiTuple([
    dynamic(abiBytes(utf8ToBytes(r.label))),
    fixed(addressWord(r.owner)),
    fixed(uint256(r.duration)),
    fixed(r.secret),
    fixed(addressWord(r.resolver)),
    dynamic(abiArray(recordCalls(r).map(abiBytes))),
    fixed(reverseRecord),
    fixed(referrer),
  ])
}

function recordCalls(r: Registration): Uint8Array[] {
  const node = namehash(r.tld, r.label)
  const records: [string, string[]][] = [["simplex.contact", r.contactLinks], ["simplex.channel", r.channelLinks]]
  return records
    .filter(([, links]) => links.length > 0)
    .map(([key, links]) =>
      concatBytes(
        selector("setText(bytes32,string,string)"),
        abiTuple([fixed(node), dynamic(abiBytes(utf8ToBytes(key))), dynamic(abiBytes(utf8ToBytes(links.join(";"))))]),
      ),
    )
}

function namehash(tld: string, label: string): Uint8Array {
  const tldNode = keccak_256(concatBytes(new Uint8Array(32), keccak_256(utf8ToBytes(tld))))
  return keccak_256(concatBytes(tldNode, keccak_256(utf8ToBytes(label))))
}

interface AbiValue {
  dynamic: boolean
  bytes: Uint8Array
}

const fixed = (bytes: Uint8Array): AbiValue => ({dynamic: false, bytes})
const dynamic = (bytes: Uint8Array): AbiValue => ({dynamic: true, bytes})

function abiTuple(values: AbiValue[]): Uint8Array {
  let offset = 32 * values.length
  const heads = values.map(v => {
    if (!v.dynamic) return v.bytes
    const head = uint256(BigInt(offset))
    offset += v.bytes.length
    return head
  })
  return concatBytes(...heads, ...values.filter(v => v.dynamic).map(v => v.bytes))
}

function abiBytes(bytes: Uint8Array): Uint8Array {
  return concatBytes(uint256(BigInt(bytes.length)), bytes, new Uint8Array((32 - (bytes.length % 32)) % 32))
}

function abiArray(items: Uint8Array[]): Uint8Array {
  return concatBytes(uint256(BigInt(items.length)), abiTuple(items.map(dynamic)))
}

function uint256(n: bigint): Uint8Array {
  return numberToBytesBE(n, 32)
}

function addressWord(address: Uint8Array): Uint8Array {
  return concatBytes(new Uint8Array(12), address)
}

function selector(signature: string): Uint8Array {
  return keccak_256(utf8ToBytes(signature)).slice(0, 4)
}
