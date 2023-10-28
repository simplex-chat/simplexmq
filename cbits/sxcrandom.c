#include <string.h>
#include "sxcrandom.h"

void sxcrandom_dummy (void *ctx, size_t length, uint8_t *dst) {
  memset(dst, 0x00, length);
}
