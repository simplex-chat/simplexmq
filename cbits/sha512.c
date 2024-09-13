#include <openssl/sha.h>
#include "sha512.h"

#include <stdio.h>

void crypto_hash_sha512 (unsigned char *out,
                         const unsigned char *in,
                         unsigned long long inlen)
{
  printf("LALAL 10\n");
  SHA512(in, inlen, out);
  printf("LALAL 11\n");
}
