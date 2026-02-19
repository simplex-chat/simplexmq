import {test, expect} from 'vitest'
import sodium from 'libsodium-wrappers-sumo'
import {encryptFile, encryptFileAsync, encodeFileHeader} from '../src/crypto/file.js'
import {prepareChunkSizes, fileSizeLen, authTagSize} from '../src/protocol/chunks.js'
import {sha512Streaming} from '../src/crypto/digest.js'
import {encryptFileForUpload} from '../src/agent.js'

await sodium.ready

function fillRandom(buf: Uint8Array) {
  for (let off = 0; off < buf.length; off += 65536) {
    crypto.getRandomValues(buf.subarray(off, Math.min(off + 65536, buf.length)))
  }
}

function makeTestParams(sourceSize: number) {
  const source = new Uint8Array(sourceSize)
  fillRandom(source)
  const fileHdr = encodeFileHeader({fileName: 'test.bin', fileExtra: null})
  const key = new Uint8Array(32)
  const nonce = new Uint8Array(24)
  crypto.getRandomValues(key)
  crypto.getRandomValues(nonce)
  const fileSize = BigInt(fileHdr.length + source.length)
  const payloadSize = Number(fileSize) + fileSizeLen + authTagSize
  const chunkSizes = prepareChunkSizes(payloadSize)
  const encSize = BigInt(chunkSizes.reduce((a, b) => a + b, 0))
  return {source, fileHdr, key, nonce, fileSize, encSize}
}

test('encryptFileAsync produces identical output to encryptFile', async () => {
  const {source, fileHdr, key, nonce, fileSize, encSize} = makeTestParams(256 * 1024) // 256KB
  const syncResult = encryptFile(source, fileHdr, key, nonce, fileSize, encSize)
  const asyncResult = await encryptFileAsync(source, fileHdr, key, nonce, fileSize, encSize)
  expect(asyncResult.length).toBe(syncResult.length)
  expect(Buffer.from(asyncResult)).toEqual(Buffer.from(syncResult))
})

test('encryptFileAsync matches sync for small files', async () => {
  const {source, fileHdr, key, nonce, fileSize, encSize} = makeTestParams(100) // 100 bytes
  const syncResult = encryptFile(source, fileHdr, key, nonce, fileSize, encSize)
  const asyncResult = await encryptFileAsync(source, fileHdr, key, nonce, fileSize, encSize)
  expect(Buffer.from(asyncResult)).toEqual(Buffer.from(syncResult))
})

test('encryptFileAsync matches sync for exact slice boundary', async () => {
  const {source, fileHdr, key, nonce, fileSize, encSize} = makeTestParams(65536) // exactly 1 slice
  const syncResult = encryptFile(source, fileHdr, key, nonce, fileSize, encSize)
  const asyncResult = await encryptFileAsync(source, fileHdr, key, nonce, fileSize, encSize)
  expect(Buffer.from(asyncResult)).toEqual(Buffer.from(syncResult))
})

test('encryptFileAsync matches sync for multi-slice boundary', async () => {
  const {source, fileHdr, key, nonce, fileSize, encSize} = makeTestParams(65536 * 3) // exactly 3 slices
  const syncResult = encryptFile(source, fileHdr, key, nonce, fileSize, encSize)
  const asyncResult = await encryptFileAsync(source, fileHdr, key, nonce, fileSize, encSize)
  expect(Buffer.from(asyncResult)).toEqual(Buffer.from(syncResult))
})

test('encryptFileAsync calls onProgress', async () => {
  const {source, fileHdr, key, nonce, fileSize, encSize} = makeTestParams(65536 * 2 + 100) // 2 full slices + partial
  const calls: [number, number][] = []
  await encryptFileAsync(source, fileHdr, key, nonce, fileSize, encSize, (done, total) => {
    calls.push([done, total])
  })
  expect(calls.length).toBe(3) // 2 full slices + 1 partial
  expect(calls[calls.length - 1][0]).toBe(calls[calls.length - 1][1]) // last call: done === total
})

test('encryptFileAsync matches sync for empty source', async () => {
  const {source, fileHdr, key, nonce, fileSize, encSize} = makeTestParams(0)
  const syncResult = encryptFile(source, fileHdr, key, nonce, fileSize, encSize)
  const asyncResult = await encryptFileAsync(source, fileHdr, key, nonce, fileSize, encSize)
  expect(Buffer.from(asyncResult)).toEqual(Buffer.from(syncResult))
})

test('encryptFileAsync streaming produces identical output to buffered', async () => {
  const {source, fileHdr, key, nonce, fileSize, encSize} = makeTestParams(256 * 1024)
  const slices: Uint8Array[] = []
  await encryptFileAsync(source, fileHdr, key, nonce, fileSize, encSize, undefined, (data) => {
    slices.push(data)
  })
  const streamed = Buffer.concat(slices)
  const buffered = await encryptFileAsync(source, fileHdr, key, nonce, fileSize, encSize)
  expect(streamed).toEqual(Buffer.from(buffered))
})

test('encryptFileForUpload streaming digest matches slice data', async () => {
  const source = new Uint8Array(256 * 1024)
  fillRandom(source)
  const slices: Uint8Array[] = []
  const result = await encryptFileForUpload(source, 'test.bin', {
    onSlice: (data) => { slices.push(data) }
  })
  const combined = Buffer.concat(slices)
  const actualDigest = sha512Streaming([combined])
  expect(Buffer.from(result.digest)).toEqual(Buffer.from(actualDigest))
  expect(result.key.length).toBe(32)
  expect(result.nonce.length).toBe(24)
  expect(result.chunkSizes.length).toBeGreaterThan(0)
  expect('encData' in result).toBe(false)
})
