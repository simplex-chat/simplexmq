// #include <openssl/sha.h>
#include "cryptonite_sha512.h"
#include "sntrup_sha512.h"

void crypto_hash_sha512 (unsigned char *out,
                         const unsigned char *in,
                         unsigned long long inlen)
{
  struct sha512_ctx ctx;
  cryptonite_sha512_init(&ctx);
  cryptonite_sha512_update(&ctx, (const uint8_t *) in, (uint32_t) inlen);
  cryptonite_sha512_finalize(&ctx, (uint8_t *) out);
}
