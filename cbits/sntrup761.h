/*
 * Derived from public domain source, written by (in alphabetical order):
 * - Daniel J. Bernstein
 * - Chitchanok Chuengsatiansup
 * - Tanja Lange
 * - Christine van Vredendaal
 */

#ifndef SNTRUP761_H
#define SNTRUP761_H

#include <string.h>
#include <stdint.h>
#include "sxcrandom.h"

#define SNTRUP761_SECRETKEY_SIZE 1763
#define SNTRUP761_PUBLICKEY_SIZE 1158
#define SNTRUP761_CIPHERTEXT_SIZE 1039
#define SNTRUP761_SIZE 32

void
sntrup761_keypair (uint8_t *pk, uint8_t *sk,
                   void *random_ctx, random_func *random);

void
sntrup761_enc (uint8_t *c, uint8_t *k, const uint8_t *pk,
               void *random_ctx, random_func *random);

void
sntrup761_dec (uint8_t *k, const uint8_t *c, const uint8_t *sk);

#endif
