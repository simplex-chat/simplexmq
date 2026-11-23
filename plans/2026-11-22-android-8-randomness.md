# libbbs randomness on Android 8

## Problem

The Android core library fails to load on Android 8 devices whose libc has no `getentropy`. libbbs takes the seeds of `bbs_keygen_full`, `bbs_sign` and `bbs_proof_gen` from `getentropy` (`cbits/libbbs/src/bbs.c:21-23`), added with the BBS scheme in #1794. Android's libc exports `getentropy` from API level 28 (Android 9); the Android builds target API level 26. `bbs.c` declares `getentropy` itself, so the library links against the API 26 libc and the symbol is missing at load time.

On 32-bit targets (armv7a Android, the i686 static CLI), BBS proof verification fails: `bbs_proof_verify_update` hashed the message index from a 4-byte `size_t` as 8 bytes, while proof generation hashes a `uint64_t`, so badge proofs of other users are not verified (`verifyBadge` in simplex-chat).

## Decisions

- Linux, Android included: `getrandom(2)` through `syscall(2)`, with `/dev/urandom` where the kernel answers `ENOSYS` or the headers do not define `SYS_getrandom`.
- Apple with `BBS_CRYPTO_CC`: `SecRandomCopyBytes`, unchanged.
- Other systems: `getentropy(3)`, unchanged; Windows keeps the shim `cbits/getentropy_win.c`.
- `getrandom` flags: 0; the call waits until the kernel pool is initialised.
- The change is commit 5a51a430 on simplex-chat/libbbs branch `simplex` (#4); `cbits/libbbs` points to it. The branch also has the fix of proof verification on 32-bit targets (#6) and CI that builds libbbs as simplexmq does on every shipped platform (#5).
- `protocol/crypto-registry.md`: the libbbs randomness sources and the pinned libbbs commit.

## Randomness source

```
bbs_get_random(buffer, length) on Linux:
  while length > 0:
    n <- syscall(SYS_getrandom, buffer, length, 0)
    n > 0          -> buffer += n; length -= n
    EINTR          -> retry
    ENOSYS         -> bbs_get_urandom(buffer, length)
    other error    -> -1
  0

bbs_get_urandom(buffer, length):
  open /dev/urandom, O_RDONLY | O_CLOEXEC, else -1
  read until length bytes; EINTR -> retry; error or end of file -> close, -1
  close; 0
```

```mermaid
flowchart TD
    C[bbs_get_random] --> P{platform}
    P -- "BBS_CRYPTO_CC" --> S[SecRandomCopyBytes]
    P -- "Linux, Android" --> G[getrandom through syscall]
    P -- "other" --> E[getentropy]
    G -- "ENOSYS, or no SYS_getrandom" --> U[/dev/urandom]
    G -- "bytes" --> OK[0]
    U -- "bytes" --> OK
    G -- "other error" --> F[-1]
    U -- "error" --> F
```

## Tests

- libbbs: its CMake tests (`make test`).
- simplexmq: `/Core tests/Encryption tests/BBS+/` and `/Core tests/Encryption tests/Entitlement/`.
- Android: `getentropy` absent from the undefined symbols of the armv7a and aarch64 `libsimplex.so` built from simplex-chat with this simplexmq; the app started on an Android 8 device.
