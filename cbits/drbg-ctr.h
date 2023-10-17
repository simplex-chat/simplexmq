#ifndef DRBG_CTR_H
#define DRBG_CTR_H

#include <string.h>
#include <stdint.h>

#include "aes256_ecb.h"

#define DRBG_CTR_AES256_SEED_SIZE (AES_BLOCK_SIZE + AES256_KEY_SIZE)

struct drbg_ctr_aes256_ctx
{
  uint8_t K[AES256_KEY_SIZE];
  uint8_t V[AES_BLOCK_SIZE];
};

/* Initialize using DRBG_CTR_AES256_SEED_SIZE bytes of
   SEED_MATERIAL.  */
void
drbg_ctr_aes256_init (struct drbg_ctr_aes256_ctx *ctx,
                      uint8_t *seed_material);

/* Output N bytes of random data into DST.  */
void
drbg_ctr_aes256_random (struct drbg_ctr_aes256_ctx *ctx,
                        size_t n, uint8_t *dst);

#endif /* DRBG_CTR_H */
