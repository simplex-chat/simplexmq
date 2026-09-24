# Ethereum crypto primitives for simplexmq

Client-side crypto for SimpleX names: enough to derive an Ethereum key and its
address from a recovery phrase. General-purpose — these modules know nothing
about names, registrars or relayers.

This is the first part of Workstream B of the SimpleX names v2 plan. The design
it serves: names are owned by a plain EOA derived per name from one BIP-39 seed
held by the device. Signing with those keys (EIP-712 typed data) and stealth addresses
land in later changes, with the code that needs them.

## What is deliberately absent

- **No RLP encoder, and no transaction building.** RLP is only needed to
  construct raw transactions or EIP-7702 authorizations. The client does
  neither, so the `RSLV` resolver path in this repo stays strictly read-only.
- **No signing.** This change derives keys and addresses. Signing, and the
  EIP-712 typed-data hashing it needs, land with the first code that signs.
- **No BIP-32 public derivation.** We always hold the seed, so CKDpub, xpub
  serialization and fingerprints are not implemented. Non-hardened *private*
  derivation is, because BIP-44 paths end in non-hardened components.
- **English wordlist only.** Every English BIP-39 word is ASCII, so the NFKD
  normalization BIP-39 mandates is a no-op on the mnemonic side and no
  normalization dependency is needed.

## Modules

```
Simplex.Messaging.Crypto.Secp256k1      FFI to libsecp256k1
Simplex.Messaging.Crypto.BIP39          mnemonics
Simplex.Messaging.Crypto.BIP39.English  generated 2048-word list
Simplex.Messaging.Crypto.BIP32          HD derivation
Simplex.Messaging.Eth.Keccak            Keccak-256
Simplex.Messaging.Eth.Address           addresses, EIP-55
```

## Types

```haskell
newtype Secp256k1PrivateKey         -- 32 bytes, validated in [1, n-1]
newtype Secp256k1PublicKey          -- libsecp256k1's opaque 64-byte form
data PubKeyFormat = Compressed | Uncompressed

data Mnemonic                       -- validated indexes + words, always consistent
data MnemonicStrength = MS128 | MS160 | MS192 | MS224 | MS256

data ExtendedKey = ExtendedKey {xkKey :: Secp256k1PrivateKey, xkChainCode :: ScrubbedBytes}

newtype Address                     -- 20 bytes
```

Private keys, chain codes and BIP-39 seeds are `ScrubbedBytes`: constant-time
`Eq`, no readable `Show`, and zeroed when freed. A chain code is secret too, as
it plus one child key derives siblings.

## Functions

```haskell
-- Secp256k1
mkPrivateKey        :: ScrubbedBytes -> IO (Either String Secp256k1PrivateKey)
unPrivateKey        :: Secp256k1PrivateKey -> ScrubbedBytes
secp256k1PublicKey  :: Secp256k1PrivateKey -> IO Secp256k1PublicKey  -- total: key is validated
serializePublicKey  :: PubKeyFormat -> Secp256k1PublicKey -> IO ByteString
privateKeyTweakAdd  :: Secp256k1PrivateKey -> ScrubbedBytes -> IO (Maybe Secp256k1PrivateKey)

-- BIP39
entropyToMnemonic   :: ByteString -> Either String Mnemonic
mnemonicToEntropy   :: Mnemonic -> ByteString             -- total
parseMnemonic       :: ByteString -> Either String Mnemonic
mnemonicToSeed      :: Mnemonic -> ByteString -> ScrubbedBytes
randomMnemonic      :: MnemonicStrength -> TVar ChaChaDRG -> STM Mnemonic

-- BIP32
masterKey           :: ScrubbedBytes -> IO (Either String ExtendedKey)
derivePath          :: ExtendedKey -> [Word32] -> IO (Either String ExtendedKey)
renderPath          :: [Word32] -> ByteString

-- Eth
keccak256           :: ByteString -> ByteString
addressFromPrivateKey :: Secp256k1PrivateKey -> IO Address
ethereumPath        :: Word32 -> Word32 -> [Word32]       -- m/44'/60'/account'/0/address
```

`Address` has a `StrEncoding` instance: `strEncode` is the EIP-55 checksummed
form and `strP` accepts bare or `0x`-prefixed hex, rejecting a bad mixed-case
checksum.

`randomMnemonic` is shaped like `Simplex.Messaging.Crypto.randomBytes` so it
composes with the agent's DRG instead of reaching for system entropy.

`parseMnemonic` lower-cases and splits on any whitespace, so a user retyping
their recovery key is not rejected for capitalising a word. This does not change
the derived seed: `mnemonicPhrase` always rebuilds the canonical lowercase
sentence from the wordlist, and that is what `mnemonicToSeed` hashes.

## How applications use it

An application defines the derivation path. For SimpleX names, one seed per
device and one account per name — see `Simplex.Chat.Wallet` in simplex-chat:

```haskell
m    <- either fail pure $ parseMnemonic phrase
mk   <- either fail pure =<< masterKey (mnemonicToSeed m "")
xk   <- either fail pure =<< derivePath mk (ethereumPath account 0)
addr <- addressFromPrivateKey (xkKey xk)
```

## libsecp256k1 C API mapping

```c
secp256k1_context_create(SECP256K1_CONTEXT_NONE)   /* per call, then _randomize */
secp256k1_context_destroy(ctx)
secp256k1_ec_seckey_verify(ctx, seckey)
secp256k1_ec_pubkey_create(ctx, pubkey, seckey)
secp256k1_ec_pubkey_serialize(ctx, output, outputlen, pubkey, flags)
secp256k1_ec_seckey_tweak_add(ctx, seckey, tweak)
```

Every function runs in `IO` with its own context, created and blinded with a
fresh seed for the call and destroyed after it, so no context is shared between
threads.

`secp256k1_ec_seckey_tweak_add` returns 0 exactly when BIP-32 says "proceed with
the next index" (tweak out of range, or a zero result), which is why
`privateKeyTweakAdd` returns `Maybe` and `derivePath` can surface it.

libsecp256k1 never reads OS entropy — the context blinding seed is supplied by
the caller. So unlike
libbbs it raises no `getentropy` / ITMS-90338 concern on iOS, and needs no
equivalent of the `commoncrypto` flag.

## Build

Submodule in `cbits/`, same pattern as blst and libbbs:
`cbits/libsecp256k1` — https://github.com/bitcoin-core/secp256k1, pinned to
**v0.8.0**.

```
c-sources:    cbits/libsecp256k1/src/{secp256k1,precomputed_ecmult,precomputed_ecmult_gen}.c
include-dirs: cbits/libsecp256k1{,/include,/src}
```

Built **without** its autotools config header, and with no `-D` of our own.
Every knob has an `#ifndef` default in the headers, and the checked-in
precomputed tables are generated for those defaults. `secp256k1.c` defines
`SECP256K1_BUILD` itself.

32-bit targets (armv7a-android, i686 musl) are covered by libsecp256k1's own
fallback: `src/util.h` selects `SECP256K1_WIDEMUL_INT64` with the 10x26 field
and 8x32 scalar backends when `__SIZEOF_INT128__` is absent.

`include-dirs` order matters: libsecp256k1's directories come last, after
libbbs and blst. There are no filename collisions between the three (checked),
and C quoted includes prefer the including file's own directory anyway, but the
ordering keeps it that way if any library later adds a generically-named header.

No `flake.nix` change is needed in simplex-chat: the per-platform overrides
there only force `packages.simplexmq.components.library.libs` (external
libraries, i.e. openssl for `extra-libraries: crypto`) and flags. Vendored
`c-sources` need no nix entry, which is why blst and libbbs have none either.

### Cross-compilation status

Verified by building simplex-chat through its flake:

| Target | Result |
|---|---|
| `x86_64-linux` (native, nix) | compiles and links |
| `aarch64-android` | **compiles and links** into the final shared object |
| `armv7a-android` | libsecp256k1 compiles; final link not reached (see below) |
| `x86_64-windows` (mingw) | blocked before our code — see below |
| `aarch64-darwin-ios` | not yet run (needs a darwin host) |

`aarch64-android` is the meaningful pass: it proves the C both cross-compiles
and links into the artifact the app actually ships.

`armv7a-android` gets far enough to prove the 32-bit path compiles — that is,
libsecp256k1's `SECP256K1_WIDEMUL_INT64` fallback builds under the NDK — but the
build then dies in simplex-chat's own `Simplex.Chat.Operators`, on the
`$(embedFile "PRIVACY.md")` splice. Cross-compiled Template Haskell runs the
splice on the target via `iserv-proxy` under `qemu-arm`, and that interpreter
fails to resolve `realpath` out of `libHSdirectory` and segfaults. It is
unrelated to this work: none of these modules use Template Haskell, and
simplexmq (which does) builds for armv7a fine. So 32-bit *linking* remains
unproven, though there is no plausible mechanism by which it would fail given
aarch64 links and the 32-bit objects compile.

`x86_64-windows` fails while bootstrapping the mingw cross-GHC, long before any
of our code is considered: haskell.nix applies
`ghc-9.6-fix-code-symbol-jumps.patch` to `rts/linker/PEi386.c` twice from the
same store path, and the second application aborts. That is a duplicate entry in
the patch list of the pinned haskell.nix branch
(`github:input-output-hk/haskell.nix/armv7a`), not something this change can
influence.

Both gaps can be closed without GHC by compiling the three C files with the
cross toolchain directly and linking a program that calls into both the core and
the recovery module — that isolates the C question from the Haskell build
entirely.

## Tests

`tests/CoreTests/EthCryptoTests.hs`, 72 examples. Everything is checked against
published vectors rather than our own output:

- **BIP-39** — all 24 official English vectors from
  `trezor/python-mnemonic/vectors.json`, entropy → mnemonic → entropy and
  mnemonic → seed with the `TREZOR` passphrase.
- **BIP-32** — spec test vectors 1 (all six chains) and 2. Expected private keys
  and chain codes were decoded from the published `xprv` base58 strings, since
  we do not implement xprv serialization.
- **EIP-55** — the four addresses from the EIP-55 spec, round-tripped.
- **BIP-44** — the well-known `0x9858EfFD232B4033E47d90003D41EC34EcaEda94` for
  the `abandon … about` mnemonic at `m/44'/60'/0'/0/0`, plus accounts 1 and 2.
- Keccak-256 against SHA3-256, so the padding-byte confusion cannot pass.
- Negative cases: zero, short and out-of-range private keys, bad BIP-39
  checksums and word counts, out-of-range seeds, and bad EIP-55 checksums.

The BIP-44 expectations were additionally reproduced by an independent
pure-Python secp256k1 reference written for the purpose, so they are not just
our implementation agreeing with itself.
