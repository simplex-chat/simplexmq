#include <openssl/sha.h>
#include "sha512.h"

void crypto_hash_sha512 (unsigned char *out,
                         const unsigned char *in,
                         unsigned long long inlen)
{
  SHA512(in, inlen, out);
}
