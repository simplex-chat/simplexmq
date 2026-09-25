# Ethereum crypto primitives for simplexmq

Client-side crypto for SimpleX names: enough to derive an Ethereum key and its
address from a recovery phrase. General-purpose: these modules contain nothing
specific to names, registrars or relayers.

This is the first part of Workstream B of the SimpleX names v2 plan. The design
it serves: names are owned by a plain EOA derived per name from one BIP-39 seed
held by the device.

## What is deliberately absent

- **No RLP encoder, and no transaction building.** RLP is only needed to
  construct raw transactions or EIP-7702 authorizations. The client does
  neither, so the `RSLV` resolver path in this repo stays strictly read-only.
- **No signing and no stealth addresses.** This change adds key and address
  derivation only. Signing, the EIP-712 typed-data hashing it requires, and
  stealth addresses are added with the first code that uses them.
- **No BIP-32 public derivation.** We always hold the seed, so CKDpub, xpub
  serialization and fingerprints are not implemented. Non-hardened *private*
  derivation is, because BIP-44 paths end in non-hardened components.
- **English wordlist only, and no full NFKD.** Every English BIP-39 word is
  ASCII, so NFKD normalization, which BIP-39 mandates, does not change a valid
  phrase's words. NFKD maps Unicode space characters such as U+00A0 and U+3000
  to a space; `parsePhrase` splits on any character `Data.Char.isSpace`
  accepts and lower-cases with `Data.Text.toLower`, and a word that is then not
  in the ASCII wordlist, such as one in fullwidth letters, is rejected. So no
  normalization dependency is needed. A passphrase is bytes the caller
  normalizes.

## Modules

```
Simplex.Messaging.Crypto.Secp256k1      FFI to libsecp256k1
Simplex.Messaging.Crypto.BIP39          mnemonics
Simplex.Messaging.Crypto.BIP39.English  embedded upstream 2048-word list
Simplex.Messaging.Crypto.BIP32          HD derivation
Simplex.Messaging.Eth.Address           addresses, EIP-55
```

`keccak256` is added to `Simplex.Messaging.Crypto`, next to `sha3_256`.

## Types

```haskell
newtype Secp256k1PrivateKey         -- 32 bytes, validated in [1, n-1]
newtype Secp256k1PublicKey          -- libsecp256k1's opaque 64-byte form
data PubKeyFormat = Compressed | Uncompressed

newtype WalletEntropy               -- 16, 20, 24, 28 or 32 bytes
data EntropyStrength = ES128 | ES160 | ES192 | ES224 | ES256

data ExtendedKey = ExtendedKey {xkKey :: Secp256k1PrivateKey, xkChainCode :: ScrubbedBytes}
data WalletMaster                   -- entropy with the master key it derives

data CoinType = Ethereum            -- SLIP-44 coin types
newtype AccountIndex                -- below 2^31

newtype Address                     -- 20 bytes
```

Private keys, chain codes, BIP-39 entropy and seeds are `ScrubbedBytes`:
constant-time `Eq`, no readable `Show`, and zeroed when freed. A chain code is
secret too: with the parent public key and one non-hardened child private key,
it yields the parent private key.

## Functions

```haskell
-- Secp256k1
mkPrivateKey        :: ScrubbedBytes -> Either String Secp256k1PrivateKey  -- 32 bytes in [1, n-1]
unPrivateKey        :: Secp256k1PrivateKey -> ScrubbedBytes
secp256k1PublicKey  :: TVar ChaChaDRG -> Secp256k1PrivateKey -> IO Secp256k1PublicKey  -- total: key is validated
serializePublicKey  :: TVar ChaChaDRG -> PubKeyFormat -> Secp256k1PublicKey -> IO ByteString
privateKeyTweakAdd  :: TVar ChaChaDRG -> Secp256k1PrivateKey -> ScrubbedBytes -> IO (Maybe Secp256k1PrivateKey)

-- BIP39
mkEntropy           :: ScrubbedBytes -> Either String WalletEntropy
randomEntropy       :: EntropyStrength -> TVar ChaChaDRG -> STM WalletEntropy
parsePhrase         :: Text -> Either String WalletEntropy   -- word count, wordlist, checksum
entropyPhrase       :: WalletEntropy -> ByteString           -- canonical lowercase phrase
entropyWordCount    :: WalletEntropy -> Int
entropySeed         :: WalletEntropy -> ByteString -> ScrubbedBytes  -- PBKDF2 with the passphrase

-- BIP32
masterKey           :: ScrubbedBytes -> Either String ExtendedKey
derivePath          :: TVar ChaChaDRG -> ExtendedKey -> [Word32] -> IO (Either String ExtendedKey)
renderPath          :: [Word32] -> ByteString
hardened            :: Word32 -> Word32
isHardened          :: Word32 -> Bool
mkWalletMaster      :: WalletEntropy -> ByteString -> Either String WalletMaster
parseWalletMaster   :: ScrubbedBytes -> ScrubbedBytes -> Either String WalletMaster  -- entropy and stored master
masterEntropy       :: WalletMaster -> WalletEntropy
walletMasterKey     :: WalletMaster -> ExtendedKey
masterBytes         :: WalletMaster -> ScrubbedBytes         -- key then chain code, the storage form

-- BIP44
mkAccountIndex      :: Word32 -> Maybe AccountIndex
unAccountIndex      :: AccountIndex -> Word32
bip44Path           :: CoinType -> AccountIndex -> [Word32]  -- m/44'/coin'/account'/0/0

-- Crypto
keccak256           :: ByteString -> ByteString

-- Eth
addressFromPrivateKey :: TVar ChaChaDRG -> Secp256k1PrivateKey -> IO Address
```

`Address` has a `StrEncoding` instance: `strEncode` is the EIP-55 checksummed
form and `strP` accepts bare or `0x`-prefixed hex, rejecting a bad mixed-case
checksum.

Like `Simplex.Messaging.Crypto.randomBytes`, `randomEntropy` takes a
`TVar ChaChaDRG` and runs in `STM`. Every function that calls libsecp256k1 takes
the same generator for the context blinding seed, so this code never reads
system entropy itself.

A value of one of these types is valid by construction: `WalletEntropy` has one
of the five sizes, `AccountIndex` is below 2^31, and `WalletMaster` holds a
master key derived from its entropy, so every function from them is total. The
fallible steps are the boundaries: `parsePhrase` for typed text,
`parseWalletMaster` for a stored row, `mkAccountIndex` for a number, and
`mkWalletMaster` for the one-in-2^128 seed whose master key is out of range.
The only fallible step after that is the BIP-32 child derivation, which the
specification requires to be fallible.

Because `parsePhrase` lower-cases each word, a recovery phrase with a
capitalised word is accepted. This does not change the derived seed:
`entropyPhrase` always rebuilds the canonical lowercase sentence from the
wordlist, and that is what `entropySeed` hashes.

## How applications use it

An application defines the derivation path. For SimpleX names, one seed per
device and one account per name, as in `Simplex.Chat.Wallet` in simplex-chat:

```haskell
ent    <- either fail pure $ parsePhrase phrase  -- phrase :: Text
master <- either fail pure $ mkWalletMaster ent ""
n      <- maybe (fail "account index too large") pure $ mkAccountIndex account
xk     <- either fail pure =<< derivePath g (walletMasterKey master) (bip44Path Ethereum n)
addr   <- addressFromPrivateKey g (xkKey xk)
```

## libsecp256k1 C API mapping

```c
secp256k1_context_create(SECP256K1_CONTEXT_NONE)   /* per call, then _randomize */
secp256k1_context_destroy(ctx)
secp256k1_ec_pubkey_create(ctx, pubkey, seckey)
secp256k1_ec_pubkey_serialize(ctx, output, outputlen, pubkey, flags)
secp256k1_ec_seckey_tweak_add(ctx, seckey, tweak)
```

Every function that calls libsecp256k1 runs in `IO` with its own context,
created for the call, blinded with 32 bytes from the caller's `TVar ChaChaDRG`
and destroyed after it, so no context is shared between threads.

`secp256k1_ec_seckey_tweak_add` returns 0 exactly when BIP-32 says to "proceed
with the next value for i" (tweak out of range, or a zero result), which is why
`privateKeyTweakAdd` returns `Maybe` and `derivePath` returns `Left` in that
case.

libsecp256k1 never reads OS entropy: the caller supplies the context blinding
seed. So unlike libbbs it causes no `getentropy` / ITMS-90338 issue on iOS, and
requires no equivalent of the `commoncrypto` flag.

## Build

Submodule in `cbits/`, same pattern as blst and libbbs:
`cbits/libsecp256k1`, https://github.com/bitcoin-core/secp256k1, pinned to
**v0.8.0**.

```
c-sources:    cbits/libsecp256k1/src/{secp256k1,precomputed_ecmult,precomputed_ecmult_gen}.c
```

No `include-dirs` are needed: every libsecp256k1 include is quoted and relative
to the including file. The embedded wordlist makes `file-embed` a library
dependency; before this change only the `smp-server` and `xftp-server`
executables and the test suite used it.

Built with no `-D` of our own. The table-size settings (`ECMULT_WINDOW_SIZE`,
`COMB_BLOCKS`, `COMB_TEETH`) have `#ifndef` defaults in the headers, and the
checked-in precomputed tables are generated for those defaults; every other
option, such as the optional modules and x86-64 assembly, is off unless a `-D`
enables it. `secp256k1.c` defines `SECP256K1_BUILD` itself.

32-bit targets (armv7a-android, i686 musl) are covered by libsecp256k1's own
fallback: `src/util.h` selects `SECP256K1_WIDEMUL_INT64`, and with it the 10x26
field and 8x32 scalar backends, when the target has neither a native 128-bit
integer nor 64-bit pointers.

No `flake.nix` change is needed in simplex-chat: the per-platform overrides
there only force `packages.simplexmq.components.library.libs` (external
libraries, i.e. openssl for `extra-libraries: crypto`) and flags. Vendored
`c-sources` require no nix entry, which is why blst and libbbs have none either.

### Cross-compilation status

Verified by building simplex-chat through its flake, before the wordlist in
`Simplex.Messaging.Crypto.BIP39.English` was embedded with Template Haskell
(`embedFile`), the construct the armv7a build fails on below. These builds have
to be rerun:

| Target | Result |
|---|---|
| `x86_64-linux` (native, nix) | compiles and links |
| `aarch64-android` | **compiles and links** into the final shared object |
| `armv7a-android` | libsecp256k1 compiles; final link not reached (see below) |
| `x86_64-windows` (mingw) | blocked before our code, see below |
| `aarch64-darwin-ios` | not yet run (requires a darwin host) |

`aarch64-android` is the meaningful pass: it proves the C both cross-compiles
and links into the shared object included in the app.

The `armv7a-android` build compiles libsecp256k1, which proves that its
`SECP256K1_WIDEMUL_INT64` fallback builds under the NDK, but the build then
fails in simplex-chat's own `Simplex.Chat.Operators`, on the
`$(embedFile "PRIVACY.md")` splice. Cross-compiled Template Haskell runs the
splice on the target via `iserv-proxy` under `qemu-arm`, and that interpreter
fails to resolve `realpath` from `libHSdirectory` and segfaults. So 32-bit
*linking* remains unproven.

`x86_64-windows` fails while bootstrapping the mingw cross-GHC, before any
simplexmq code is compiled: haskell.nix applies
`ghc-9.6-fix-code-symbol-jumps.patch` to `rts/linker/PEi386.c` twice from the
same store path, and the second application aborts. That is a duplicate entry in
the patch list of the pinned haskell.nix branch
(`github:input-output-hk/haskell.nix/armv7a`), not something this change can
influence.

Both gaps can be closed without GHC by compiling the three C files with the
cross toolchain directly and linking a test program against them, which verifies
the C code independently of the Haskell build.

## Tests

`tests/CoreTests/EthCryptoTests.hs`, 92 examples, with published vectors read
from vendored upstream files in `tests/fixtures`, each pinned by a sha256 test:

- **BIP-39**: all 24 English vectors of `trezor/python-mnemonic/vectors.json`:
  entropy to phrase, phrase to entropy, seed with the `TREZOR` passphrase, and
  the master key against the vector's `xprv`.
- **BIP-32**: vectors 1 to 4 of `bip-0032.mediawiki`, every chain, against its
  `xprv`; the two vector 5 keys outside `[1, n-1]` drive the `mkPrivateKey`
  rejections. The test decodes base58check itself; the library does not parse
  `xprv`, so vector 5's malformed serializations do not apply.
- **EIP-55**: the eight addresses from the EIP-55 spec, round-tripped.
- **BIP-44**: the well-known `0x9858EfFD232B4033E47d90003D41EC34EcaEda94` for
  the `abandon ... about` mnemonic at `m/44'/60'/0'/0/0`, plus accounts 1 and 2.
- Keccak-256 of the empty string and of `abc`.
- Recovery phrases with capitalised words, extra whitespace, and non-breaking or
  ideographic spaces between words.
- Negative cases: zero, short and out-of-range private keys, a tweak that makes
  the key zero or is not 32 bytes, bad BIP-39 checksums and word counts,
  out-of-range seeds, a stored master that does not match its entropy, account
  indexes at or above 2^31, and bad EIP-55 checksums.

The BIP-44 expectations were additionally reproduced by an independent
pure-Python secp256k1 reference written for the purpose, so they were not
computed only by this implementation.
