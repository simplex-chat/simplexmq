import type {FileHeader} from '../src/crypto/file.js'
import {t} from './i18n.js'

export interface CryptoBackend {
  encrypt(data: Uint8Array, fileName: string,
          onProgress?: (done: number, total: number) => void
  ): Promise<EncryptResult>
  readChunk(offset: number, size: number): Promise<Uint8Array>
  decryptAndStoreChunk(
    dhSecret: Uint8Array, nonce: Uint8Array,
    body: Uint8Array, digest: Uint8Array, chunkNo: number
  ): Promise<void>
  verifyAndDecrypt(params: {size: number, digest: Uint8Array, key: Uint8Array, nonce: Uint8Array},
                   onProgress?: (done: number, total: number) => void
  ): Promise<{header: FileHeader, content: Uint8Array}>
  cleanup(): Promise<void>
}

export interface EncryptResult {
  digest: Uint8Array
  key: Uint8Array
  nonce: Uint8Array
  chunkSizes: number[]
}

type PendingRequest = {resolve: (value: any) => void, reject: (reason: any) => void}

class WorkerBackend implements CryptoBackend {
  private worker: Worker
  private pending = new Map<number, PendingRequest>()
  private nextId = 1
  private progressCb: ((done: number, total: number) => void) | null = null
  private ready: Promise<void>

  constructor() {
    this.worker = new Worker(new URL('./crypto.worker.ts', import.meta.url), {type: 'module'})
    let rejectReady: (e: Error) => void
    this.ready = new Promise((resolve, reject) => {
      rejectReady = reject
      this.worker.onmessage = (e) => {
        if (e.data?.type === 'ready') {
          this.worker.onmessage = (e) => this.handleMessage(e.data)
          resolve()
        } else {
          reject(new Error('Worker: unexpected first message'))
        }
      }
    })
    this.worker.onerror = (e) => {
      rejectReady(new Error('Worker failed to load: ' + e.message))
      for (const p of this.pending.values()) p.reject(new Error('Worker error: ' + e.message))
      this.pending.clear()
    }
  }

  private handleMessage(msg: {id: number, type: string, [k: string]: any}) {
    if (msg.type === 'progress') {
      this.progressCb?.(msg.done, msg.total)
      return
    }
    const p = this.pending.get(msg.id)
    if (!p) return
    this.pending.delete(msg.id)
    if (msg.type === 'error') {
      p.reject(new Error(msg.message))
    } else {
      p.resolve(msg)
    }
  }

  private async send(msg: Record<string, any>, transfer?: Transferable[]): Promise<any> {
    await this.ready
    const id = this.nextId++
    return new Promise((resolve, reject) => {
      this.pending.set(id, {resolve, reject})
      this.worker.postMessage({...msg, id}, transfer ?? [])
    })
  }

  private toTransferable(data: Uint8Array): ArrayBuffer {
    if (data.byteOffset !== 0 || data.byteLength !== data.buffer.byteLength) {
      return data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer
    }
    return data.buffer as ArrayBuffer
  }

  async encrypt(data: Uint8Array, fileName: string,
                onProgress?: (done: number, total: number) => void): Promise<EncryptResult> {
    this.progressCb = onProgress ?? null
    const buf = this.toTransferable(data)
    const resp = await this.send({type: 'encrypt', data: buf, fileName}, [buf])
    this.progressCb = null
    return {digest: resp.digest, key: resp.key, nonce: resp.nonce, chunkSizes: resp.chunkSizes}
  }

  async readChunk(offset: number, size: number): Promise<Uint8Array> {
    const resp = await this.send({type: 'readChunk', offset, size})
    return new Uint8Array(resp.data)
  }

  async decryptAndStoreChunk(
    dhSecret: Uint8Array, nonce: Uint8Array,
    body: Uint8Array, digest: Uint8Array, chunkNo: number
  ): Promise<void> {
    // Copy arrays to ensure clean ArrayBuffer separation before worker transfer
    // nonce/dhSecret may be subarrays sharing buffer with body
    const dhSecretCopy = new Uint8Array(dhSecret)
    const nonceCopy = new Uint8Array(nonce)
    const digestCopy = new Uint8Array(digest)
    const buf = this.toTransferable(body)
    const hex = (b: Uint8Array | ArrayBuffer, n = 8) => {
      const u = b instanceof ArrayBuffer ? new Uint8Array(b) : b
      return Array.from(u.slice(0, n)).map(x => x.toString(16).padStart(2, '0')).join('')
    }
    console.log(`[BACKEND-DBG] chunk=${chunkNo} body.len=${body.length} body.byteOff=${body.byteOffset} buf.byteLen=${buf.byteLength} nonce=${hex(nonceCopy, 24)} dhSecret=${hex(dhSecretCopy)} digest=${hex(digestCopy, 32)} buf[0..8]=${hex(buf)} body[-8..]=${hex(body.slice(-8))}`)
    await this.send(
      {type: 'decryptAndStoreChunk', dhSecret: dhSecretCopy, nonce: nonceCopy, body: buf, chunkDigest: digestCopy, chunkNo},
      [buf]
    )
  }

  async verifyAndDecrypt(params: {size: number, digest: Uint8Array, key: Uint8Array, nonce: Uint8Array},
                         onProgress?: (done: number, total: number) => void
  ): Promise<{header: FileHeader, content: Uint8Array}> {
    this.progressCb = onProgress ?? null
    const resp = await this.send({
      type: 'verifyAndDecrypt',
      size: params.size, digest: params.digest, key: params.key, nonce: params.nonce
    })
    this.progressCb = null
    return {header: resp.header, content: new Uint8Array(resp.content)}
  }

  async cleanup(): Promise<void> {
    await this.send({type: 'cleanup'})
    this.worker.terminate()
  }
}

export function createCryptoBackend(): CryptoBackend {
  if (typeof Worker === 'undefined') {
    throw new Error(t('workersRequired', 'Web Workers required \u2014 update your browser'))
  }
  return new WorkerBackend()
}
