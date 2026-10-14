import {bytesToHex} from "@noble/curves/utils"
import {formatNameCode} from "../src/code"
import {makeCommitment, registerIntentDigest, type Registration} from "../src/registration"
import {checksumAddress, signDigest, walletFromEntropy} from "../src/wallet"
import {chainId, duration, minLabelLength, resolver, sponsor, tld} from "./config"

const wallet = walletFromEntropy(crypto.getRandomValues(new Uint8Array(16)))
element("code").textContent = formatNameCode(wallet.entropy)
element("address").textContent = checksumAddress(wallet.address)
element("mnemonic").textContent = wallet.mnemonic

element("register").addEventListener("click", () => {
  element("commit-request").textContent = ""
  element("register-request").textContent = ""
  const input = element("label") as HTMLInputElement
  const label = input.value.trim().toLowerCase()
  const valid = label.length >= minLabelLength && label.length <= 63 && /^[a-z0-9]+(-[a-z0-9]+)*$/.test(label)
  input.setCustomValidity(valid ? "" : `${minLabelLength} to 63 letters a-z, digits 0-9 and single hyphens between them`)
  const fields = [input, element("contact"), element("channel")] as HTMLInputElement[]
  if (!fields.every(field => field.reportValidity())) return
  const registration: Registration = {
    label,
    tld,
    owner: wallet.address,
    duration,
    secret: crypto.getRandomValues(new Uint8Array(32)),
    resolver,
    contactLinks: links("contact"),
    channelLinks: links("channel"),
  }
  element("commit-request").textContent = json({commitment: makeCommitment(registration)})
  const nonce = 0n
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600)
  const signature = signDigest(wallet.privateKey, registerIntentDigest(chainId, sponsor, registration, nonce, deadline))
  element("register-request").textContent = json({...registration, nonce, deadline, signature})
})

function element(id: string): HTMLElement {
  return document.getElementById(id)!
}

function links(id: string): string[] {
  const link = (element(id) as HTMLInputElement).value.trim()
  return link === "" ? [] : [link]
}

function json(request: object): string {
  return JSON.stringify(request, (_, v) => (v instanceof Uint8Array ? "0x" + bytesToHex(v) : typeof v === "bigint" ? v.toString() : v), 2)
}
