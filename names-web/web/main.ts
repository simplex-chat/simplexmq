import {bytesToHex} from "@noble/curves/utils"
import {formatNameCode} from "../src/code"
import {makeCommitment, registerIntentDigest, type Registration} from "../src/registration"
import {signDigest, walletFromEntropy} from "../src/wallet"
import {chainId, duration, resolver, sponsor, tld} from "./config"

const wallet = walletFromEntropy(crypto.getRandomValues(new Uint8Array(16)))
element("code").textContent = formatNameCode(wallet.entropy)

element("register").addEventListener("click", () => {
  const registration: Registration = {
    label: (element("label") as HTMLInputElement).value,
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
