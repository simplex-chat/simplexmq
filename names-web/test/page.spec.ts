import {expect, test} from "@playwright/test"
import {bytesToHex, hexToBytes} from "viem"
import {parseNameCode} from "../src/code"
import {makeCommitment, registerIntentDigest, type Registration} from "../src/registration"
import {signDigest, walletFromEntropy} from "../src/wallet"
import {chainId, sponsor} from "../web/config"

test("prepares a commitment and a registration signed by the code's wallet", async ({page}) => {
  await page.goto("/")
  const code = await page.locator("#code").innerText()
  await page.locator("#label").fill("bakery1")
  await page.locator("#contact").fill("https://smp.simplex.im/a#contact")
  await page.locator("#channel").fill("https://smp1.simplex.im/c#one\nhttps://smp2.simplex.im/c#two")
  await page.locator("#register").click()
  const {commitment} = JSON.parse(await page.locator("#commit-request").innerText())
  const request = JSON.parse(await page.locator("#register-request").innerText())

  const wallet = walletFromEntropy(parseNameCode(code)!)
  expect(request).toMatchObject({label: "bakery1", owner: bytesToHex(wallet.address), contactLinks: ["https://smp.simplex.im/a#contact"], channelLinks: ["https://smp1.simplex.im/c#one", "https://smp2.simplex.im/c#two"]})

  const registration: Registration = {
    ...request,
    owner: hexToBytes(request.owner),
    duration: BigInt(request.duration),
    secret: hexToBytes(request.secret),
    resolver: hexToBytes(request.resolver),
  }
  expect(commitment).toBe(bytesToHex(makeCommitment(registration)))

  const digest = registerIntentDigest(chainId, sponsor, registration, BigInt(request.nonce), BigInt(request.deadline))
  expect(request.signature).toBe(bytesToHex(signDigest(wallet.privateKey, digest)))
})
