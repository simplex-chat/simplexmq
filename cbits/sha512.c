#include "openssl_sha.h"
#include "sha512.h"

void crypto_hash_sha512 (unsigned char *out,
                         const unsigned char *in,
                         unsigned long long inlen)
{
  SHA512_CTX ctx;
  SHA512_Init(&ctx);
  SHA512_Update(&ctx, in, inlen);
  SHA512_Final(out, &ctx);
}
