#ifndef SXCRANDOM_H
#define SXCRANDOM_H

#include <stdint.h>

typedef void random_func (void *ctx, size_t length, uint8_t *dst);

void sxcrandom_dummy (void *ctx, size_t length, uint8_t *dst);

#endif
