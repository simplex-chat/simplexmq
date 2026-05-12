/*
 * WASM wrapper for sntrup761.
 * Provides JS-callable functions with RNG from JS imports.
 *
 * Build: emcc sntrup761_wasm.c sntrup761.c sha512.c -O2 -o sntrup761.js \
 *        -s EXPORTED_FUNCTIONS='["_sntrup761_wasm_keypair","_sntrup761_wasm_enc","_sntrup761_wasm_dec","_malloc","_free"]' \
 *        -s EXPORTED_RUNTIME_METHODS='["ccall","cwrap"]'
 */

#include "sntrup761.h"
#include <stdlib.h>

/* Import RNG from JS environment */
extern void js_random_bytes(unsigned char *buf, int len);

/* RNG callback adapter for sntrup761 */
static void wasm_random(void *ctx, size_t length, uint8_t *dst) {
  (void)ctx;
  js_random_bytes(dst, (int)length);
}

/* JS-callable wrappers */

void sntrup761_wasm_keypair(unsigned char *pk, unsigned char *sk) {
  sntrup761_keypair(pk, sk, NULL, wasm_random);
}

void sntrup761_wasm_enc(unsigned char *c, unsigned char *k, const unsigned char *pk) {
  sntrup761_enc(c, k, pk, NULL, wasm_random);
}

void sntrup761_wasm_dec(unsigned char *k, const unsigned char *c, const unsigned char *sk) {
  sntrup761_dec(k, c, sk);
}
