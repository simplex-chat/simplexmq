# Ethereum crypto primitives for simplexmq

Client-side crypto for SimpleX names: enough to derive an Ethereum key from a
recovery phrase and sign EIP-712 typed data. General-purpose — these modules
know nothing about names, registrars or relayers.

This is Workstream B of the SimpleX names v2 plan. The design it serves: names
are owned by a plain EOA derived per chat profile from one BIP-39 seed, and
every post-registration action (transfer, record edit) is a one-shot EIP-712
intent signed by that key and relayed by SimpleX, which pays the gas.

## What is deliberately absent

- **No RLP encoder, and no transaction building.** RLP is only needed to
  construct raw transactions or EIP-7702 authorizations. The client does
  neither: it signs EIP-712 typed data and hands the signature to the relayer.
  The client never reads a nonce, estimates gas or broadcasts anything, so the
  `RSLV` resolver path in this repo stays strictly read-only.
- **No low-s normalization.** libsecp256k1 already emits the canonical low-`s`
  form EIP-2 requires. `isLowS` exists so tests assert that rather than assume
  it. There is deliberately no normalization entry point: we never accept a
  foreign signature, we only produce our own.
- **No BIP-32 public derivation.** We always hold the seed, so CKDpub, xpub
  serialization and fingerprints are not implemented. Non-hardened *private*
  derivation is, because BIP-44 paths end in non-hardened components.
- **No EIP-712 schema encoder.** The caller supplies the canonical type string.
  Our structs are a handful of fixed shapes agreed with the contracts, and a
  hand-written string checked against Solidity in a test is easier to audit than
  a schema encoder whose output nobody reads.
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
Simplex.Messaging.Eth.EIP712            typed data hashing
```

## Types

```haskell
newtype PrivateKey                  -- 32 bytes, validated in [1, n-1]
newtype PublicKey                   -- libsecp256k1's opaque 64-byte form
data RecoverableSignature = RecoverableSignature {rsCompact :: ByteString, rsRecId :: Int}
data PubKeyFormat = Compressed | Uncompressed

data Mnemonic                       -- validated indexes + words, always consistent
data MnemonicStrength = MS128 | MS160 | MS192 | MS224 | MS256

data ExtendedKey = ExtendedKey {xkKey :: PrivateKey, xkChainCode :: ByteString}

newtype Address                     -- 20 bytes; Show renders the EIP-55 form
data Eip712Domain = Eip712Domain {edName, edVersion :: ByteString, edChainId :: Integer, edVerifyingContract :: Address}
data Value = VUint Integer | VInt Integer | VBool Bool | VAddress Address
           | VFixedBytes ByteString | VBytes ByteString | VString ByteString
           | VArray [Value] | VStruct ByteString
```

`PrivateKey`, `Mnemonic` and `ExtendedKey` have **redacting `Show` instances**,
and `PrivateKey` compares with `constEq`. These keys authorise transfers of
assets with monetary value: a derived `Show` would put one in a log the first
time anything is traced. A chain code is secret too — it plus one child key
derives siblings.

## Functions

```haskell
-- Secp256k1
mkPrivateKey        :: ByteString -> Either String PrivateKey
publicKey           :: PrivateKey -> PublicKey            -- total: key is validated
parsePublicKey      :: ByteString -> Either String PublicKey
serializePublicKey  :: PubKeyFormat -> PublicKey -> ByteString
privateKeyTweakAdd  :: PrivateKey -> ByteString -> Maybe PrivateKey
signRecoverable     :: PrivateKey -> ByteString -> Either String RecoverableSignature
recoverPublicKey    :: RecoverableSignature -> ByteString -> Either String PublicKey
isLowS              :: RecoverableSignature -> Bool

-- BIP39
entropyToMnemonic   :: ByteString -> Either String Mnemonic
mnemonicToEntropy   :: Mnemonic -> ByteString             -- total
parseMnemonic       :: ByteString -> Either String Mnemonic
mnemonicToSeed      :: Mnemonic -> ByteString -> ByteString
randomMnemonic      :: MnemonicStrength -> TVar ChaChaDRG -> STM Mnemonic

-- BIP32
masterKey           :: ByteString -> Either String ExtendedKey
deriveChild         :: ExtendedKey -> Word32 -> Either String ExtendedKey
derivePath          :: ExtendedKey -> [Word32] -> Either String ExtendedKey
parsePath           :: ByteString -> Either String [Word32]
renderPath          :: [Word32] -> ByteString

-- Eth
keccak256           :: ByteString -> ByteString
addressFromPrivateKey :: PrivateKey -> Address
checksumAddress     :: Address -> ByteString
parseAddress        :: ByteString -> Either String Address
ethereumPath        :: Word32 -> [Word32]                 -- m/44'/60'/i'/0/0
typeHash            :: ByteString -> ByteString
hashStruct          :: ByteString -> [Value] -> Either String ByteString
domainSeparator     :: Eip712Domain -> Either String ByteString
hashTypedData       :: Eip712Domain -> ByteString -> [Value] -> Either String ByteString
```

`randomMnemonic` is shaped like `Simplex.Messaging.Crypto.randomBytes` so it
composes with the agent's DRG instead of reaching for system entropy.

`parseMnemonic` lower-cases and splits on any whitespace, so a user retyping
their recovery key is not rejected for capitalising a word. This does not change
the derived seed: `mnemonicPhrase` always rebuilds the canonical lowercase
sentence from the wordlist, and that is what `mnemonicToSeed` hashes.

## How applications use it

An application defines the derivation path and the EIP-712 type strings. For
SimpleX names, one seed per chat database and one key per chat profile —
see `Simplex.Chat.Names.Wallet` in simplex-chat:

```haskell
m    <- either fail pure $ parseMnemonic phrase
mk   <- either fail pure $ masterKey (mnemonicToSeed m "")
xk   <- either fail pure $ derivePath mk (ethereumPath userId)
let addr = addressFromPrivateKey (xkKey xk)
```

Signing a transfer intent — the type string must match the contract's exactly,
including EIP-712 canonical form (no spaces after commas, referenced struct
types appended in alphabetical order):

```haskell
digest <- either fail pure $ hashTypedData domain
  "TransferName(address from,address to,uint256 tokenId,uint256 nonce,uint256 deadline)"
  [VAddress from, VAddress to, VUint tokenId, VUint nonce, VUint deadline]
sig <- either fail pure $ signRecoverable (xkKey xk) digest
-- Ethereum's v is rsRecId + 27
```

Nested structs go in as `VStruct` holding an already-computed `hashStruct`;
arrays as `VArray`, which hashes the concatenation of its members.

## libsecp256k1 C API mapping

```c
secp256k1_context_create(SECP256K1_CONTEXT_NONE)   /* once, then _randomize */
secp256k1_ec_seckey_verify(ctx, seckey)
secp256k1_ec_pubkey_create(ctx, pubkey, seckey)
secp256k1_ec_pubkey_parse(ctx, pubkey, input, inputlen)
secp256k1_ec_pubkey_serialize(ctx, output, outputlen, pubkey, flags)
secp256k1_ec_seckey_tweak_add(ctx, seckey, tweak)
secp256k1_ecdsa_sign_recoverable(ctx, sig, msghash32, seckey, NULL, NULL)
secp256k1_ecdsa_recoverable_signature_serialize_compact(ctx, output64, recid, sig)
secp256k1_ecdsa_recoverable_signature_parse_compact(ctx, sig, input64, recid)
secp256k1_ecdsa_recover(ctx, pubkey, sig, msghash32)
```

Passing `NULL` for the nonce function selects RFC-6979, so signing is a
deterministic pure function of (key, digest) — which is why the module exposes a
pure API over `unsafePerformIO`. The context is created and blinded once at
first use; randomization is a side-channel countermeasure that affects no
output, and signing does not mutate the context, so one shared context is safe
across threads.

`secp256k1_ec_seckey_tweak_add` returns 0 exactly when BIP-32 says "proceed with
the next index" (tweak out of range, or a zero result), which is why
`privateKeyTweakAdd` returns `Maybe` and `deriveChild` can surface it.

libsecp256k1 never reads OS entropy — RFC-6979 nonces are derived from the key
and digest, and the context blinding seed is supplied by the caller. So unlike
libbbs it raises no `getentropy` / ITMS-90338 concern on iOS, and needs no
equivalent of the `commoncrypto` flag.

## Build

Submodule in `cbits/`, same pattern as blst and libbbs:
`cbits/libsecp256k1` — https://github.com/bitcoin-core/secp256k1, pinned to
**v0.8.0**.

```
c-sources:    cbits/libsecp256k1/src/{secp256k1,precomputed_ecmult,precomputed_ecmult_gen}.c
include-dirs: cbits/libsecp256k1{,/include,/src}
cc-options:   -DENABLE_MODULE_RECOVERY=1
```

Built **without** its autotools config header. Every knob has an `#ifndef`
default in the headers, and the checked-in precomputed tables are generated for
those defaults, so only the recovery module has to be switched on. The recovery
module is `#include`d from `secp256k1.c`, so it needs no extra `c-sources`
entry. `secp256k1.c` defines `SECP256K1_BUILD` itself, so that needs no `-D`
either.

32-bit targets (armv7a-android, i686 musl) are covered by libsecp256k1's own
fallback: `src/util.h` selects `SECP256K1_WIDEMUL_INT64` with the 10x26 field
and 8x32 scalar backends when `__SIZEOF_INT128__` is absent.

`include-dirs` order matters: libsecp256k1's directories come last, after
libbbs and blst. There are no filename collisions between the three (checked),
and C quoted includes prefer the including file's own directory anyway, but the
ordering keeps it that way if any library later adds a generically-named header.

`-DENABLE_MODULE_RECOVERY=1` lands on the shared `cc-options`, so it also
reaches blst, libbbs and sntrup761 — harmless, none of them use the macro, and
symmetrically `-D__BLST_PORTABLE__` reaches libsecp256k1.

No `flake.nix` change is needed in simplex-chat: the per-platform overrides
there only force `packages.simplexmq.components.library.libs` (external
libraries, i.e. openssl for `extra-libraries: crypto`) and flags. Vendored
`c-sources` need no nix entry, which is why blst and libbbs have none either.

**Cross-compilation is unproven.** This has been built and tested on x86-64
Linux only. iOS arm64 and the simulator, the Android ABIs, and the Windows
desktop build all still need proving, and that is where the remaining risk in
this workstream sits.

## Tests

`tests/CoreTests/EthCryptoTests.hs`, 98 examples. Everything is checked against
published vectors rather than our own output:

- **BIP-39** — all 24 official English vectors from
  `trezor/python-mnemonic/vectors.json`, entropy → mnemonic → entropy and
  mnemonic → seed with the `TREZOR` passphrase.
- **BIP-32** — spec test vectors 1 (all six chains) and 2. Expected private keys
  and chain codes were decoded from the published `xprv` base58 strings, since
  we do not implement xprv serialization.
- **EIP-55** — the four addresses from the EIP-55 spec, round-tripped.
- **EIP-712** — the `Mail` example from the spec: domain separator, `hashStruct`
  and the final digest.
- **BIP-44** — the well-known `0x9858EfFD232B4033E47d90003D41EC34EcaEda94` for
  the `abandon … about` mnemonic at `m/44'/60'/0'/0/0`, plus accounts 1 and 2.
- Keccak-256 against SHA3-256, so the padding-byte confusion cannot pass.
- Negative cases: zero and out-of-range private keys, wrong digest length,
  malformed public keys, bad BIP-39 checksums and word counts, out-of-range
  seeds, bad EIP-55 checksums, and every EIP-712 range and length check.

The EIP-712 and BIP-44 expectations were additionally reproduced by an
independent pure-Python secp256k1 reference written for the purpose, so they are
not just our implementation agreeing with itself.
