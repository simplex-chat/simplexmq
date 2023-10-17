#include "drbg-ctr.h"

#include <string.h>

static void memxor(uint8_t *dst, const uint8_t *src, size_t n)
{
  size_t i;
  for (i = 0; i < n; i++)
    dst[i] ^= src[i];
}

static void increment (uint8_t *V)
{
  size_t i;

  for (i = AES_BLOCK_SIZE - 1; i > 0; i--)
    {
      if (V[i] == 0xFF)
        V[i] = 0;
      else
        {
          V[i]++;
          break;
        }
    }
}

static void
drbg_ctr_aes256_update (uint8_t *Key, uint8_t *V, uint8_t *provided_data)
{
  uint8_t tmp[DRBG_CTR_AES256_SEED_SIZE];

  increment (V);
  aes256_encrypt (Key, tmp, V);

  increment (V);
  aes256_encrypt (Key, tmp + AES_BLOCK_SIZE, V);

  increment (V);
  aes256_encrypt (Key, tmp + 2 * AES_BLOCK_SIZE, V);

  if (provided_data)
    memxor (tmp, provided_data, 48);

  memcpy (Key, tmp, AES256_KEY_SIZE);
  memcpy (V, tmp + AES256_KEY_SIZE, AES_BLOCK_SIZE);
}

void
drbg_ctr_aes256_init (struct drbg_ctr_aes256_ctx *ctx, uint8_t *seed_material)
{
  memset (ctx->K, 0, AES256_KEY_SIZE);
  memset (ctx->V, 0, AES_BLOCK_SIZE);

  drbg_ctr_aes256_update (ctx->K, ctx->V, seed_material);
}

void
drbg_ctr_aes256_random (struct drbg_ctr_aes256_ctx *ctx,
                        size_t n, uint8_t *dst)
{
  while (n >= AES_BLOCK_SIZE)
    {
      increment (ctx->V);
      aes256_encrypt (ctx->K, dst, ctx->V);
      dst += AES_BLOCK_SIZE;
      n -= AES_BLOCK_SIZE;
    }

  if (n > 0)
    {
      uint8_t block[AES_BLOCK_SIZE];

      increment (ctx->V);
      aes256_encrypt (ctx->K, block, ctx->V);
      memcpy (dst, block, n);
    }

  drbg_ctr_aes256_update (ctx->K, ctx->V, NULL);
}
