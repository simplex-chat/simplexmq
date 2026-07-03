# BBS+ Bindings for simplexmq

Haskell FFI bindings to libbbs for BBS+ signatures. General-purpose - the module knows nothing about specific applications.

## How BBS+ works

BBS+ signs a fixed list of N messages. Each message is an arbitrary byte array. The signer signs all N messages at once with one signature.

The holder of the signature can then generate a proof that selectively discloses some messages and hides others. The verifier learns the disclosed messages and confirms they were signed by the signer, but learns nothing about the hidden messages. Different proofs from the same signature are unlinkable.

Key constraint: the total number of messages N is fixed at signing time. The verifier must know N. A proof generated from a 3-message signature cannot be verified as a 2-message proof.

## Types

```haskell
newtype BBSSecretKey = BBSSecretKey ByteString  -- 32 bytes
newtype BBSPublicKey = BBSPublicKey ByteString  -- 96 bytes (BLS12-381 G2 point)
newtype BBSSignature = BBSSignature ByteString  -- 80 bytes
newtype BBSProof = BBSProof ByteString          -- 272 + 32 * numUndisclosed bytes
newtype BBSHeader = BBSHeader ByteString        -- always-disclosed context (e.g. protocol identifier)
newtype BBSPresHeader = BBSPresHeader ByteString -- random nonce for proof unlinkability
```

All newtypes get StrEncoding (base64url), ToJSON/FromJSON (via strToJSON/strParseJSON), Eq, Show.

## Functions

```haskell
bbsKeyGen :: IO (Either String BBSKeyPair)  -- BBSKeyPair = (BBSPublicKey, BBSSecretKey)

-- pk is derived from sk internally, so it is not a parameter
bbsSign
  :: BBSSecretKey
  -> BBSHeader            -- always-disclosed context
  -> [ByteString]         -- all N messages
  -> IO (Either String BBSSignature)

-- C order: pk, signature, header, presentation_header, disclosed_indexes, messages
bbsProofGen
  :: BBSPublicKey
  -> BBSSignature
  -> BBSHeader            -- must match what was signed
  -> BBSPresHeader        -- random nonce bound into the proof
  -> [Int]                -- disclosed indexes (0-based)
  -> [ByteString]         -- all N messages (needed internally, hidden ones not revealed in proof)
  -> IO (Either String BBSProof)

-- C order: pk, proof, header, presentation_header, disclosed_indexes, n, messages
bbsProofVerify
  :: BBSPublicKey
  -> BBSProof
  -> BBSHeader            -- must match what was signed
  -> BBSPresHeader        -- must match what was used in bbsProofGen
  -> [Int]                -- disclosed indexes
  -> Int                  -- total message count N
  -> [ByteString]         -- disclosed messages only
  -> IO Bool
```

## How applications use it

An application defines:
- A message layout: which index means what
- Which indexes are disclosed vs hidden
- How to encode application values as ByteString messages

### Badge example (in simplex-chat, not in this module)

Message layout (always 3 messages):
- Index 0: master secret (32 random bytes) - HIDDEN
- Index 1: expiry (UTF-8 encoded timestamp string) - DISCLOSED
- Index 2: badge type (UTF-8 encoded, e.g. "supporter") - DISCLOSED

Signing (v2, on the server):
```
bbsSign sk header [ms, encodeUtf8 "2026-07-31", encodeUtf8 "supporter"]
```

Proof generation (v2, on the client):
```
bbsProofGen pk sig header presHeader [1, 2] [ms, encodeUtf8 "2026-07-31", encodeUtf8 "supporter"]
```

Proof verification (v1, on the recipient):
```
bbsProofVerify pk proof header presHeader 3 [1, 2] [encodeUtf8 "2026-07-31", encodeUtf8 "supporter"]
```

The recipient only sees the proof, presentationHeader, expiry string, and badge type string. They verify these were signed by the server (pk is hardcoded). They never see the master secret.

Expiry is always present as a string. Monthly badges use a date like `"2026-07-31"`, lifetime badges use `"lifetime"`. BBS+ doesn't interpret the bytes - expiry semantics are the application's responsibility. This keeps the message count fixed at 3 for all badge types.

## libbbs C API mapping

```c
int bbs_keygen_full(ciphersuite, sk, pk)
int bbs_sign(ciphersuite, sk, pk, signature, header, header_len, n, messages, message_lens)
int bbs_proof_gen(ciphersuite, pk, signature, proof, header, header_len, presentation_header, presentation_header_len, disclosed_indexes, disclosed_indexes_len, n, messages, message_lens)
int bbs_proof_verify(ciphersuite, pk, proof, proof_len, header, header_len, presentation_header, presentation_header_len, disclosed_indexes, disclosed_indexes_len, n, messages, message_lens)
```

We use `bbs_sha256_ciphersuite`. The header parameter is exposed in all Haskell functions - the application decides what to put there. Tests use `"SimpleX"` as header.

The `presentation_header` parameter is what we call `presentationHeader`.

In `bbs_proof_verify`, the `n` parameter is the total number of messages (not the number of disclosed messages). The `messages` array contains only the disclosed messages, and `disclosed_indexes` maps each to its position in the original message list.

## Build

Submodules in cbits/:
- `cbits/libbbs` - https://github.com/Fraunhofer-AISEC/libbbs
- `cbits/blst` - https://github.com/supranational/blst (libbbs dependency)

C sources in cabal: `cbits/blst/src/server.c`, `cbits/blst/build/assembly.S`, libbbs source files.
Include dirs: `cbits/blst/bindings/`, `cbits/blst/src/`, `cbits/libbbs/include/`, `cbits/libbbs/src/`.
C flags: `-D__BLST_PORTABLE__` for cross-CPU-generation compatibility.

## Tests

- Keygen produces keys of correct size
- Sign + proofGen + proofVerify roundtrip succeeds
- Tampered proof fails verification
- Tampered disclosed message fails verification
- Wrong public key fails verification
- Two proofs from same credential with different nonces both verify
- Proof size matches expected (272 + 32 * numUndisclosed)
