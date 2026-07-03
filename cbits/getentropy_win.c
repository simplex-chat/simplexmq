// SPDX-License-Identifier: Apache-2.0
// getentropy() shim for Windows, where it is absent from the CRT.
// Follows the POSIX contract: fills `buffer` with `length` random bytes
// (length must not exceed 256), returns 0 on success or -1 with errno set.
#ifdef _WIN32
#include <errno.h>
#include <stddef.h>
#include <windows.h>
#include <bcrypt.h>

int getentropy(void *buffer, size_t length) {
    if (length > 256) {
        errno = EIO;
        return -1;
    }
    NTSTATUS status = BCryptGenRandom(NULL, (PUCHAR)buffer, (ULONG)length,
                                      BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    if (!BCRYPT_SUCCESS(status)) {
        errno = EIO;
        return -1;
    }
    return 0;
}
#endif
