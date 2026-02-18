import {test, expect} from 'vitest'
import sodium from 'libsodium-wrappers-sumo'
import {encryptFile, encryptFileAsync, encodeFileHeader} from '../src/crypto/file.js'
import {prepareChunkSizes, fileSizeLen, authTagSize} from '../src/protocol/chunks.js'

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
