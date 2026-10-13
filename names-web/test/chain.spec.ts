import {expect, test} from "@playwright/test"
import {readFileSync} from "node:fs"
import {join} from "node:path"
import {
  bytesToHex,
  createPublicClient,
  createWalletClient,
  encodeFunctionData,
  getAddress,
  http,
  labelhash,
  namehash,
  zeroAddress,
  zeroHash,
  type Abi,
  type Address,
} from "viem"
import {hardhat} from "viem/chains"
import {resolver as pageResolver, sponsor as pageSponsor} from "../web/config"

interface Contract {
  address: Address
  abi: Abi
}

const ensContractsDir = process.env.ENS_CONTRACTS_DIR
const transport = http("http://127.0.0.1:8645")
const publicClient = createPublicClient({chain: hardhat, transport})
const walletClient = createWalletClient({chain: hardhat, transport})

test.skip(!ensContractsDir, "set ENS_CONTRACTS_DIR to a compiled checkout of ens-contracts PR #35")

test("registers the page's name through the sponsor on a hardhat node", async ({page}) => {
  const [owner, guardian, registrar] = await walletClient.getAddresses()
  const {baseRegistrar, controller, resolver, sponsor} = await deployNames(owner, guardian)
  expect(sponsor.address).toBe(getAddress(bytesToHex(pageSponsor)))
  expect(resolver.address).toBe(getAddress(bytesToHex(pageResolver)))
  await write(guardian, sponsor, "setRegistrarAllowance", [registrar, 1000n * 10n ** 18n])

  await page.goto("/")
  await page.locator("#label").fill("bakery1")
  await page.locator("#contact").fill("https://smp.simplex.im/a#contact")
  await page.locator("#channel").fill("https://smp1.simplex.im/c#one\nhttps://smp2.simplex.im/c#two")
  await page.locator("#register").click()
  const {commitment} = JSON.parse(await page.locator("#commit-request").innerText())
  const request = JSON.parse(await page.locator("#register-request").innerText())

  await write(registrar, controller, "commit", [commitment])

  const node = namehash(`${request.label}.${request.tld}`)
  const records: [string, string[]][] = [["simplex.contact", request.contactLinks], ["simplex.channel", request.channelLinks]]
  const data = records
    .filter(([, links]) => links.length > 0)
    .map(([key, links]) => encodeFunctionData({abi: resolver.abi, functionName: "setText", args: [node, key, links.join(";")]}))
  const registration = {
    label: request.label,
    owner: request.owner,
    duration: BigInt(request.duration),
    secret: request.secret,
    resolver: request.resolver,
    data,
    reverseRecord: 0,
    referrer: zeroHash,
  }
  await write(registrar, sponsor, "registerWithCredit", [registration, BigInt(request.nonce), BigInt(request.deadline), request.signature])

  expect(await read(baseRegistrar, "ownerOf", [BigInt(labelhash(request.label))])).toBe(getAddress(request.owner))
  expect(await read(resolver, "text", [node, "simplex.contact"])).toBe("https://smp.simplex.im/a#contact")
  expect(await read(resolver, "text", [node, "simplex.channel"])).toBe("https://smp1.simplex.im/c#one;https://smp2.simplex.im/c#two")
})

async function deployNames(owner: Address, guardian: Address) {
  const tldNode = namehash("simplex")
  const ens = await deploy(owner, "registry/ENSRegistry.sol/ENSRegistry.json", [])
  const baseRegistrar = await deploy(owner, "ethregistrar/BaseRegistrarImplementation.sol/BaseRegistrarImplementation.json", [ens.address, tldNode])
  await write(owner, ens, "setSubnodeOwner", [zeroHash, labelhash("simplex"), baseRegistrar.address])
  const dummyOracle = await deploy(owner, "ethregistrar/DummyOracle.sol/DummyOracle.json", [100000000n])
  const priceOracle = await deploy(owner, "simplex/SimplexPriceOracle.sol/SimplexPriceOracle.json", [dummyOracle.address, 8, 1000n, []])
  const implementation = await deploy(owner, "simplex/SimplexController.sol/SimplexController.json", [])
  const initData = encodeFunctionData({
    abi: implementation.abi,
    functionName: "initialize",
    args: [
      baseRegistrar.address,
      priceOracle.address,
      1n,
      86400n,
      ens.address,
      {tldNode, tldSuffix: ".simplex", minCharLength: 6, smpxNft: zeroAddress, nftGateEnabled: false},
      owner,
    ],
  })
  const proxy = await deploy(owner, "simplex/SimplexControllerProxy.sol/SimplexControllerProxy.json", [implementation.address, initData])
  const controller = {address: proxy.address, abi: implementation.abi}
  const subnameRegistrar = await deploy(owner, "simplex/SubnameRegistrar.sol/SubnameRegistrar.json", [ens.address, baseRegistrar.address])
  const resolver = await deploy(owner, "simplex/SimplexResolver.sol/SimplexResolver.json", [
    ens.address,
    subnameRegistrar.address,
    controller.address,
    zeroAddress,
  ])
  await write(owner, subnameRegistrar, "setResolver", [resolver.address])
  await write(owner, baseRegistrar, "addController", [controller.address])
  await write(owner, baseRegistrar, "setSubnameHook", [subnameRegistrar.address])
  await write(owner, controller, "setDefaultResolver", [resolver.address])
  await write(owner, controller, "setBeneficiary", [guardian])
  const sponsor = await deploy(owner, "simplex/SimplexSponsor.sol/SimplexSponsor.json", [controller.address])
  await write(owner, controller, "setSponsor", [sponsor.address])
  return {baseRegistrar, controller, resolver, sponsor}
}

async function deploy(from: Address, artifact: string, args: unknown[]): Promise<Contract> {
  const {abi, bytecode} = JSON.parse(readFileSync(join(ensContractsDir!, "artifacts/contracts", artifact), "utf8"))
  const hash = await walletClient.deployContract({account: from, abi, bytecode, args})
  const {contractAddress} = await publicClient.waitForTransactionReceipt({hash})
  return {address: getAddress(contractAddress!), abi}
}

async function write(from: Address, contract: Contract, functionName: string, args: unknown[]): Promise<void> {
  const hash = await walletClient.writeContract({account: from, ...contract, functionName, args})
  expect((await publicClient.waitForTransactionReceipt({hash})).status).toBe("success")
}

function read(contract: Contract, functionName: string, args: unknown[]): Promise<unknown> {
  return publicClient.readContract({...contract, functionName, args})
}
