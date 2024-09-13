#include <openssl/sha.h>
#include "sha512.h"

#if defined(__ANDROID__)
#include <log.h>
#else
#include <stdio.h>
#endif

void crypto_hash_sha512 (unsigned char *out,
                         const unsigned char *in,
                         unsigned long long inlen)
{
#ifdef __ANDROID__
  __android_log_print(ANDROID_LOG_ERROR, "SimpleX", "LALAL %d", 10);
#else 
  printf("LALAL 10\n");
#endif
  SHA512(in, inlen, out);
#ifdef __ANDROID__
  __android_log_print(ANDROID_LOG_ERROR, "SimpleX", "LALAL %d", 11);
#else 
  printf("LALAL 11\n");
#endif
}
