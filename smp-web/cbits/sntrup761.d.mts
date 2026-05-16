interface Sntrup761Module {
  _sntrup761_wasm_keypair(pk: number, sk: number): void
  _sntrup761_wasm_enc(c: number, k: number, pk: number): void
  _sntrup761_wasm_dec(k: number, c: number, sk: number): void
  _malloc(size: number): number
  _free(ptr: number): void
  HEAPU8: Uint8Array
}

declare function createSntrup761(): Promise<Sntrup761Module>
export default createSntrup761
