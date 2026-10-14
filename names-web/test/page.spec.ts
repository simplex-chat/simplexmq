import {expect, test} from "@playwright/test"
import {bytesToHex, getAddress, hexToBytes} from "viem"
import {parseNameCode} from "../src/code"
import {makeCommitment, registerIntentDigest, type Registration} from "../src/registration"
import {signDigest, walletFromEntropy} from "../src/wallet"
import {chainId, duration, resolver, sponsor, tld} from "../web/config"

test("prepares a commitment and a registration signed by the code's wallet", async ({page}) => {
  await page.goto("/")
  const code = await page.locator("#code").innerText()
  await page.locator("#label").fill(" Bakery1 ")
  await page.locator("#contact").fill("https://smp.simplex.im/a#contact")
  await page.locator("#channel").fill("https://smp1.simplex.im/c#one")
  const now = Math.floor(Date.now() / 1000)
  await page.locator("#register").click()
  const request = JSON.parse(await page.locator("#register-request").innerText())

  const wallet = walletFromEntropy(parseNameCode(code)!)
  expect(await page.locator("#address").innerText()).toBe(getAddress(bytesToHex(wallet.address)))
  expect(await page.locator("#mnemonic").innerText()).toBe(wallet.mnemonic)
  expect(request).toEqual({
    label: "bakery1",
    tld,
    owner: bytesToHex(wallet.address),
    duration: duration.toString(),
    secret: expect.stringMatching(/^0x[0-9a-f]{64}$/),
    resolver: bytesToHex(resolver),
    contactLinks: ["https://smp.simplex.im/a#contact"],
    channelLinks: ["https://smp1.simplex.im/c#one"],
    nonce: "0",
    deadline: expect.any(String),
    signature: expect.any(String),
  })
  expect(Number(request.deadline)).toBeGreaterThanOrEqual(now + 3600)
  expect(Number(request.deadline)).toBeLessThanOrEqual(now + 3660)

  const registration: Registration = {
    ...request,
    owner: hexToBytes(request.owner),
    duration: BigInt(request.duration),
    secret: hexToBytes(request.secret),
    resolver: hexToBytes(request.resolver),
  }
  expect(JSON.parse(await page.locator("#commit-request").innerText())).toEqual({commitment: bytesToHex(makeCommitment(registration))})

  const digest = registerIntentDigest(chainId, sponsor, registration, BigInt(request.nonce), BigInt(request.deadline))
  expect(request.signature).toBe(bytesToHex(signDigest(wallet.privateKey, digest)))
})

test("refuses labels the contract cannot register or clients cannot resolve", async ({page}) => {
  await page.goto("/")
  await page.locator("#label").fill("bakery1")
  await page.locator("#register").click()
  await expect(page.locator("#commit-request")).not.toBeEmpty()
  for (const label of ["bake1", "b".repeat(64), "bakery_1", "bäkery1", "-bakery1", "bakery1-", "bake--ry1"]) {
    await page.locator("#label").fill(label)
    await page.locator("#register").click()
    await expect(page.locator("#commit-request")).toBeEmpty()
    await expect(page.locator("#register-request")).toBeEmpty()
  }
})

test("refuses two links in one field", async ({page}) => {
  await page.goto("/")
  await page.locator("#label").fill("bakery1")
  for (const field of ["#contact", "#channel"]) {
    await page.locator("#register").click()
    await expect(page.locator("#commit-request")).not.toBeEmpty()
    await page.locator(field).fill("https://smp1.simplex.im/c#one;https://smp2.simplex.im/c#two")
    await page.locator("#register").click()
    await expect(page.locator("#commit-request")).toBeEmpty()
    await expect(page.locator("#register-request")).toBeEmpty()
    await page.locator(field).fill("")
  }
})

test("draws a new code on each load and a new secret on each request", async ({page}) => {
  await page.goto("/")
  const code = await page.locator("#code").innerText()
  await page.locator("#label").fill("bakery1")
  await page.locator("#register").click()
  const {secret} = JSON.parse(await page.locator("#register-request").innerText())
  await page.locator("#register").click()
  expect(JSON.parse(await page.locator("#register-request").innerText()).secret).not.toBe(secret)
  await page.reload()
  expect(await page.locator("#code").innerText()).not.toBe(code)
})
