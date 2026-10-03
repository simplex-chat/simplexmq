Revision 1, 2026-10-01

# SimpleX Network: cryptographic primitive registry

The cryptographic primitives, constructions and domain-separation strings used by this repository, and which of them new code may use. For the threat model see [Security](./security.md).

Module aliases follow the codebase: `C` = [Simplex.Messaging.Crypto](../src/Simplex/Messaging/Crypto.hs), `LC` = [Crypto.Lazy](../src/Simplex/Messaging/Crypto/Lazy.hs), `CR` = [Crypto.Ratchet](../src/Simplex/Messaging/Crypto/Ratchet.hs), `SL` = [Crypto.ShortLink](../src/Simplex/Messaging/Crypto/ShortLink.hs), `KEM` = [Crypto.SNTRUP761](../src/Simplex/Messaging/Crypto/SNTRUP761.hs) and [its bindings](../src/Simplex/Messaging/Crypto/SNTRUP761/Bindings.hs), `BBS` = [Crypto.BBS](../src/Simplex/Messaging/Crypto/BBS.hs). Lengths are in bytes.

## Table of contents

- [Policy](#policy)
- [Defaults for new code](#defaults-for-new-code)
- [Primitives](#primitives)
- [SimpleX box constructions](#simplex-box-constructions)
- [Domain separation and KDF inputs](#domain-separation-and-kdf-inputs)
- [Nonces and IVs](#nonces-and-ivs)
- [Implementation sources](#implementation-sources)
- [xftp-web (TypeScript)](#xftp-web-typescript)
- [Tests](#tests)

## Policy

- New code uses the default primitive for its purpose from [Defaults for new code](#defaults-for-new-code).
- Using any other primitive, or a primitive marked *restricted* outside its listed purpose, requires a written justification in the pull request and review by a maintainer responsible for cryptography.
- *Legacy-only* primitives stay only for the existing wire formats and stored data listed below. Do not add call sites.
- Every new HKDF info string or hash prefix must be unique, start with `SimpleX`, and be added to [Domain separation and KDF inputs](#domain-separation-and-kdf-inputs).
- Changing a primitive, key length, KDF input, info string or nonce construction changes the wire format. It requires a protocol version and an update of this registry and of the affected `protocol/` specification.

Status values used below:

| Status | Meaning |
|---|---|
| Default | Approved and preferred for new code for this purpose |
| Approved | Approved for new code for this purpose when the default does not fit |
| Restricted | Approved only for the listed purpose (external interoperability or a single protocol) |
| Legacy-only | Kept for existing wire formats or stored data; no new call sites |

## Defaults for new code

| Purpose | Default | Functions |
|---|---|---|
| Signature | Ed25519 | `C.sign'`, `C.verify'` with `C.SEd25519` |
| Key agreement | X25519 | `C.generateKeyPair`, `C.dh'` |
| Post-quantum KEM | sntrup761 | `KEM.sntrup761Keypair`, `sntrup761Enc`, `sntrup761Dec` |
| Hybrid DH + KEM secret | HKDF-SHA512 over `dh \|\| kemSecret` with a new info string, as in `CR.rootKdf` | `C.hkdf` |
| Authenticated encryption | XSalsa20-Poly1305 [SimpleX secretbox](#simplex-box-constructions) | `C.sbEncrypt`/`C.sbDecrypt`, `LC.sbEncryptTailTag` for streams |
| Authenticated encryption with a DH secret | XSalsa20-Poly1305 [SimpleX crypto_box](#simplex-box-constructions) | `C.cbEncrypt`/`C.cbDecrypt` |
| Forward-secret symmetric session | HKDF-SHA512 key chain | `C.sbcInit`, `C.sbcHkdf` |
| KDF | HKDF-SHA512 | `C.hkdf` |
| Hash commitment, derived identifier | SHA3-256 | `C.sha3_256` |
| Certificate fingerprint | SHA-256 X.509 fingerprint | `C.signedFingerprint`, `C.certificateFingerprint` |
| Randomness | ChaChaDRG seeded from system entropy | `C.newRandom`, `C.randomBytes` and the `random*` helpers |

## Primitives

| Primitive | Status | Purpose and protocol | Implementation | Lengths |
|---|---|---|---|---|
| Ed25519 | Default | SMP/NTF/XFTP queue and file keys (agent default `rcvAuthAlg`, `sndAuthAlg` in [Agent/Env/SQLite.hs](../src/Simplex/Messaging/Agent/Env/SQLite.hs)), short-link signatures and owner auth (`SL.encodeSign`, `SL.newOwnerAuth`), XRCP identity and session keys ([RemoteControl/Invitation.hs](../src/Simplex/RemoteControl/Invitation.hs)), agent service request signatures, client/service TLS certificates ([Transport/Credentials.hs](../src/Simplex/Messaging/Transport/Credentials.hs)) | crypton `Crypto.PubKey.Ed25519` via `C.sign'`/`C.verify'` | pub 32, priv 32, sig 64; X.509 SPKI 44 |
| Ed448 | Approved | Server CA and online certificates (default `signAlgorithm = ED448` in [Server/CLI.hs](../src/Simplex/Messaging/Server/CLI.hs)); accepted for SMP command signatures and TLS | crypton `Crypto.PubKey.Ed448`; server key generation by the `openssl genpkey` CLI | pub 57, priv 57, sig 114; SPKI 69 |
| X25519 | Default | Per-queue e2e and server-to-recipient `crypto_box` keys, SMP session DH, command authenticator (SMP v7+), proxy (PRXY/PFWD), notification tokens, XFTP chunk transport, XRCP hello and announcements | crypton `Crypto.PubKey.Curve25519` via `C.dh'` | pub 32, priv 32, secret 32; SPKI 44 |
| X448 | Restricted | E2E double ratchet only: X3DH and DH ratchet (`CR.RatchetX448`, E2E v3) | crypton `Crypto.PubKey.Curve448` | pub 56, priv 56, secret 56 |
| sntrup761 | Default | PQ KEM in double ratchet (E2E v3, agent v5+) and XRCP v1 hello | Vendored C [cbits/sntrup761.c](../cbits/sntrup761.c) via FFI; randomness from ChaChaDRG through `haskell_rng_func` ([Bindings/RNG.hs](../src/Simplex/Messaging/Crypto/SNTRUP761/Bindings/RNG.hs)) | pk 1158, sk 1763, ct 1039, shared 32 |
| XSalsa20-Poly1305, SimpleX crypto_box | Default | SMP message bodies (server to recipient), per-queue e2e envelope, confirmations, proxy forwarding, notifications, XRCP hello, XFTP chunk transport | crypton `Crypto.Cipher.XSalsa`, `Crypto.MAC.Poly1305`; `C.cryptoBox`, `LC.cbInit` | key 32 (DH secret), nonce 24, tag 16 |
| XSalsa20-Poly1305, SimpleX secretbox | Default | SMP transport block encryption (SMP v11+), short-link data (SMP v15+), XFTP file encryption, local file encryption ([Crypto/File.hs](../src/Simplex/Messaging/Crypto/File.hs)), XRCP session | same; `C.sbEncrypt`, `LC.sbEncryptTailTag`, `LC.sbInit` | key 32, nonce 24, tag 16 |
| crypto_box authenticator | Approved | Deniable sender command authorization with X25519 queue keys (SMP v7+); agent currently creates Ed25519 keys | `C.cbAuthenticate`, `C.cbVerify`: `crypto_box(sha512(msg))` | 80 = 64 + 16 |
| AES-256-GCM, 16-byte IV | Legacy-only | Double ratchet header and body (E2E v3, [pqdr.md](./pqdr.md)) | crypton `Crypto.Cipher.AES`, `Crypto.Cipher.Types`; `C.encryptAEAD`, `C.decryptAEAD`, `C.initAEAD`; J0 = GHASH(IV) as NIST SP 800-38D defines for non-96-bit IVs | key 32, IV 16, tag 16; padded header 88 (PQ off) or 2310 (PQ on), `CR.paddedHeaderLen` |
| AES-256-GCM, 12-byte IV | Restricted | WebRTC frame encryption in simplex-chat (`Simplex.Chat.Mobile.WebRTC`), for WebCrypto interoperability | `C.encryptAESNoPad`, `C.decryptAESNoPad`, `C.initAEADGCM`, `C.GCMIV` | key 32, IV 12, tag 16 |
| HKDF-SHA512 | Default | All KDFs listed in [Domain separation](#domain-separation-and-kdf-inputs) | crypton `Crypto.KDF.HKDF` with `SHA512`; `C.hkdf` (extract + expand) | output per use, at most 255 * 64 |
| SHA-256 | Default for X.509 fingerprints, otherwise Restricted | X.509 fingerprints (`C.KeyHash`, server identity, XRCP CA, service certificate hash, SMP v16+), XFTP chunk digests, agent message hashes, `requestCode`, ratchet key dedup hash, security code `codeAD = sha256(rcAD)` | crypton; `C.sha256Hash`, `LC.sha256Hash`, `getFingerprint ... HashSHA256` | 32 |
| SHA-512 | Restricted | XFTP file digests and file description hash, input of the crypto_box authenticator | crypton; `C.sha512Hash`, `LC.sha512Hash` | 64 |
| SHA-512 (inside sntrup761) | Restricted | sntrup761 internal hash | [cbits/sha512.c](../cbits/sha512.c) calls OpenSSL `SHA512()` from the system `libcrypto` (`extra-libraries: crypto`) | 64 |
| SHA3-256 | Default | Short-link key `sha3_256(fixedData)` (SMP v15+), XRCP hybrid secret, service request binding (agent v8) | crypton; `C.sha3_256`, `KEM.kemHybridSecret` | 32 |
| SHA3-384 | Restricted | Client-supplied sender ID: first 24 bytes of `sha3_384(corrId)`, computed by the agent (`prepareConnectionLink'`, `newRcvConnSrv`) and the server (`createQueue`) | crypton; `C.sha3_384` | 48, truncated to 24 |
| Keccak-256 | Restricted | Label hash for SMP name queries (`NameQuery NQHash`), must match the on-chain registry | crypton `Keccak_256`; `labelHash` in [SimplexName.hs](../src/Simplex/Messaging/SimplexName.hs) | 32 |
| MD5 | Legacy-only, non-security | XOR-aggregated queue ID hash `IdsHash` for service subscription reconciliation (SUBS, NSUBS, SOKS, ENDS) | crypton (`C.md5Hash`, `Protocol.queueIdHash`); SQLite UDF `simplex_xor_md5_combine` ([Agent/Store/SQLite.hs](../src/Simplex/Messaging/Agent/Store/SQLite.hs)); PostgreSQL pgcrypto `digest(..., 'md5')` in server and NTF schemas | 16 |
| ChaChaDRG | Default | Keys, nonces, correlation IDs, random IDs, sntrup761 randomness | crypton `Crypto.Random`; `C.newRandom` seeds with `drgNew` from system entropy | n/a |
| BBS+ over BLS12-381, SHA-256 suite | Restricted | Badge entitlement credentials and proofs ([Crypto/Entitlement.hs](../src/Simplex/Messaging/Crypto/Entitlement.hs)), XFTP storage-time extension | Vendored submodules libbbs and blst (C and assembly) via FFI; randomness from libbbs `getentropy`, `SecRandomCopyBytes` with the `commoncrypto` flag, `BCryptGenRandom` on Windows ([cbits/getentropy_win.c](../cbits/getentropy_win.c)) | sk 32, pk 96, sig 80, proof 272 + 32 per undisclosed message |
| ECDSA with SHA-256 (ES256) | Restricted | APNS provider JWT ([Push/APNS.hs](../src/Simplex/Messaging/Notifications/Server/Push/APNS.hs)) | crypton `Crypto.PubKey.ECC.ECDSA.sign`; key read by cryptostore `Crypto.Store.PKCS8`; curve taken from the key file | signature DER `SEQUENCE {r, s}`, base64url |
| TLS 1.3 / 1.2 | Restricted | SMP, XFTP, NTF, XRCP transport: `TLS_CHACHA20_POLY1305_SHA256` (1.3), `ECDHE_ECDSA_CHACHA20POLY1305_SHA256` (1.2), groups X448 and X25519, Ed448 and Ed25519 signatures (`defaultSupportedParams`) | `tls` 1.9 | n/a |
| TLS for browsers | Restricted | XFTP server with HTTPS credentials (`defaultSupportedParamsHTTPS`: `ciphersuite_strong`, FFDHE, P-521, ECDSA and RSA signatures); SMP server HTTPS requires RSA-4096 (`checkHTTPSCredentials`) | `tls`, `warp-tls` | n/a |
| X.509 | Restricted | Certificate chains, fingerprints, signed session keys (`C.signX509`, `C.verifyX509`) | `crypton-x509`, `crypton-x509-validation`, `cryptostore` | n/a |
| SQLCipher | Restricted | Agent SQLite database at rest (`PRAGMA key`); cipher parameters are SQLCipher defaults, not set in this repository | `direct-sqlcipher` (git dependency, [cabal.project](../cabal.project)) | n/a |

## SimpleX box constructions

`C.cryptoBox` and `LC.sbInit_` compute, for a 32-byte key `k` and 24-byte nonce `n`:

```
k1 = HSalsa20(k, 0^16)
subkey = HSalsa20(k1, n[0..16])
stream = Salsa20(subkey, n[16..24])
polyKey = stream[0..32]
ct = msg XOR stream[32..]
tag = Poly1305(polyKey, ct)
```

| Construction | Key `k` | Equivalent libsodium call | Layout |
|---|---|---|---|
| SimpleX crypto_box (`C.cbEncrypt`, `LC.cbInit`) | X25519 shared secret | `crypto_box_easy` (`crypto_box_beforenm` is `HSalsa20(dh, 0^16)`) | strict: `tag \|\| ct`; lazy tail-tag: `ct \|\| tag` |
| SimpleX secretbox (`C.sbEncrypt`, `LC.sbInit`, `KEM.kcb*`) | 32-byte symmetric key | `crypto_secretbox_easy` with key `crypto_core_hsalsa20(0^16, k)`, not with `k` | same |

Padding before encryption: `C.pad` prefixes a 2-byte big-endian length and fills with `#` (message at most 65533 bytes); `LC.pad` prefixes an 8-byte length. `*NoPad` variants skip padding.

## Domain separation and KDF inputs

HKDF is `C.hkdf salt ikm info len` (HKDF-SHA512).

| Info string | Salt | IKM | Output (split) | Function | Use |
|---|---|---|---|---|---|
| `"SimpleXX3DH"` | 64 zero bytes | `dh1 \|\| dh2 \|\| dh3 [\|\| kemShared]` | 96: `hk`, `nhk`, root key (32 each) | `CR.pqX3dh` | Ratchet initialization, added in E2E v2; KEM secret from E2E v3 (current minimum) |
| `"SimpleXVerifyCode"` | 64 zero bytes | same as `SimpleXX3DH` | 32: `rcVCPQ` | `CR.pqX3dh` | Verification code covering all handshake keys, new ratchets |
| `"SimpleXRootRatchet"` | root key | `dh [\|\| kemShared]` | 96: root key, chain key, next header key | `CR.rootKdf` | DH/PQ ratchet step |
| `"SimpleXChainRatchet"` | empty | chain key | 96: chain key, message key (32 each), message IV (16), header IV (16) | `CR.chainKdf` | Per-message keys |
| `"SimpleXSbChainInit"` | SMP session ID | X25519 session secret | 64: two 32-byte chain keys | `C.sbcInit` from `Transport.blockEncryption` | SMP transport block encryption, SMP v11+ |
| `"SimpleXSbChainInit"` | empty | XRCP hybrid secret (below) | 64: two 32-byte chain keys | `C.sbcInit` in [RemoteControl/Client.hs](../src/Simplex/RemoteControl/Client.hs) | XRCP v1 session |
| `"SimpleXSbChain"` | empty | chain key | 88: chain key (32), secretbox key (32), nonce (24) | `C.sbcHkdf` | Each SMP block and XRCP message |
| `"SimpleXContactLink"` | empty | link key (32) | 56: link ID (24), secretbox key (32) | `SL.contactShortLinkKdf` | Contact short links, SMP v15+ |
| `"SimpleXInvLink"` | empty | link key (32) | 32: secretbox key | `SL.invShortLinkKdf` | Invitation short links, SMP v15+ |

Other derivations:

| Value | Construction | Function | Use |
|---|---|---|---|
| Service request binding | `sha3_256("SimpleXService" \|\| rcAD)` | `serviceReqBinding` in [Agent.hs](../src/Simplex/Messaging/Agent.hs) | Agent RPC, agent v8 |
| BBS header | `"SimpleX badges v1"` | `entitlementBBSHeader` | Badge credentials |
| XRCP hybrid secret | `sha3_256(x25519Dh \|\| kemShared)` | `KEM.kemHybridSecret` | XRCP v1 |
| Short-link key | `sha3_256(smpEncode FixedLinkData)` | `SL.encodeSignFixedData`, checked in `SL.decryptLinkData` | SMP v15+ |
| Sender ID | `take 24 (sha3_384 corrId)` | `prepareConnectionLink'`, `newRcvConnSrv` in Agent.hs; `createQueue` in [Server.hs](../src/Simplex/Messaging/Server.hs) | Client-supplied sender ID with link data, SMP v15+; the server rejects a mismatch to prevent an ID oracle |
| Ratchet associated data | `pubKeyBytes sk1 \|\| pubKeyBytes rk1` (raw X448, 112) | `CR.pqX3dh` | AD of every ratchet AEAD |
| Security code | `sha256(rcAD)` | `ratchetVerifyCodes` in [AgentStore.hs](../src/Simplex/Messaging/Agent/Store/AgentStore.hs) | Connection verification |
| Contact request code | `sha256(smpEncode (k1, k2, kem, sndId))` | `requestCode` in Agent.hs | Contact request binding |
| Command authenticator | `crypto_box(sha512(authorized))` | `C.cbAuthenticate` | SMP v7+ |
| Queue IDs hash | `xor` of `md5(queueId)` | `Protocol.queueIdsHash` | Service subscriptions |

`"SimpleXSbChainInit"` and `"SimpleXSbChain"` are shared by SMP block encryption and XRCP. Their outputs are separated only by the IKM (and the salt for `sbcInit`).

## Nonces and IVs

| Use | Construction |
|---|---|
| SMP command authenticator, proxied command | `C.cbNonce corrId`, where `corrId` is a random 24-byte nonce (`C.randomCbNonce`) |
| SMP proxied responses | `C.reverseNonce` of the request nonce |
| Server-to-recipient message body | `C.cbNonce msgId`; `msgIdBytes = 24` in [Server/Main.hs](../src/Simplex/Messaging/Server/Main.hs) |
| Per-queue e2e envelope, short-link data, notifications, XRCP hello, XFTP chunk download | Random 24-byte nonce, sent with the ciphertext |
| XFTP file, local encrypted file | Random key and nonce per file (`C.randomSbKey`, `C.randomCbNonce`) |
| SMP block, XRCP session messages | Key and nonce from `C.sbcHkdf`, one per block |
| Ratchet header, body | 16-byte IVs from `CR.chainKdf`; header IV is sent, body IV is not |
| WebRTC frames | 12-byte `C.GCMIV` supplied by the caller in simplex-chat |

## Implementation sources

| Source | Version or pin | Provides |
|---|---|---|
| crypton | 0.34 | Ed25519, Ed448, X25519, X448, XSalsa20, Poly1305, AES-GCM, HKDF, SHA-2, SHA-3, Keccak, MD5, ChaChaDRG, ECDSA |
| tls, crypton-x509, crypton-x509-validation, cryptostore | 1.9.0, 1.7.6, 1.6.12, 0.3.0.1 | TLS, X.509, PKCS#8 |
| [cbits/sntrup761.c](../cbits/sntrup761.c) | Copy of draft-josefsson-ntruprime-streamlined-00 ([cbits/README.md](../cbits/README.md)) | sntrup761 |
| [cbits/sha512.c](../cbits/sha512.c) and system OpenSSL `libcrypto` | system | SHA-512 for sntrup761 |
| `cbits/libbbs` submodule ([simplex-chat/libbbs](https://github.com/simplex-chat/libbbs)) | `59a0f4bf` | BBS+ (`bbs_sha256_ciphersuite`), SHA-256, SHAKE256 |
| `cbits/blst` submodule ([supranational/blst](https://github.com/supranational/blst)) | `db3defd0` | BLS12-381 (C and `build/assembly.S`, `-D__BLST_PORTABLE__`) |
| direct-sqlcipher | git `f814ee68` | SQLCipher |
| `openssl` CLI | system | Server CA and certificate key generation (`createServerX509_`) |

## xftp-web (TypeScript)

[xftp-web](../xftp-web/) reimplements a subset for the browser XFTP client. It has no AES-GCM, HKDF, SHA-3, MD5, X448 or sntrup761 code.

| Primitive | Implementation | Haskell counterpart |
|---|---|---|
| Ed25519 sign, verify, keys | libsodium-wrappers-sumo (`crypto_sign_*`), [src/crypto/keys.ts](../xftp-web/src/crypto/keys.ts) | `C.sign'`, `C.verify'` |
| Ed448 verify | `@noble/curves/ed448`, keys.ts `verifyEd448` | `C.verify'` |
| X25519 | libsodium `crypto_scalarmult`, `crypto_box_keypair` | `C.dh'` |
| SimpleX crypto_box, secretbox, tail-tag streaming | Salsa20 block function written in TypeScript, libsodium `crypto_core_hsalsa20` and `crypto_onetimeauth_*`, [src/crypto/secretbox.ts](../xftp-web/src/crypto/secretbox.ts) | `C.cryptoBox`, `LC.sbInit_` |
| crypto_box authenticator | [src/protocol/client.ts](../xftp-web/src/protocol/client.ts) `cbAuthenticate`, `cbVerify` | `C.cbAuthenticate`, `C.cbVerify` |
| SHA-256, SHA-512 | libsodium `crypto_hash_sha256`, `crypto_hash_sha512*`, [src/crypto/digest.ts](../xftp-web/src/crypto/digest.ts) | `C.sha256Hash`, `C.sha512Hash` |
| Random | WebCrypto `crypto.getRandomValues`; libsodium for key generation | `C.randomBytes` |

## Tests

None of the tests below compares against published reference vectors (NIST, RFC 8032, RFC 7748, RFC 5869, NaCl, the sntrup761 draft or the BBS draft). Interoperability is tested between this repository's own implementations.

| Area | Test module (hspec group) | Kind |
|---|---|---|
| Ed25519, Ed448, X25519 crypto_box, secretbox, lazy and tail-tag secretbox, AES-GCM 12-byte IV, X.509 key encoding, X.509 chains, sntrup761, BBS+, entitlements, padding | [tests/CoreTests/CryptoTests.hs](../tests/CoreTests/CryptoTests.hs) | Round-trip; fixed lengths for BBS+; fixed bytes for padding |
| Double ratchet (X25519 and X448), PQ KEM agreement, AES-GCM 16-byte IV | [tests/AgentTests/DoubleRatchetTests.hs](../tests/AgentTests/DoubleRatchetTests.hs) | Round-trip; decoding of a stored v2 ratchet JSON |
| Short links (HKDF info strings, SHA3-256 link key) | [tests/AgentTests/ShortLinkTests.hs](../tests/AgentTests/ShortLinkTests.hs) | Round-trip, tamper rejection |
| File encryption | [tests/CoreTests/CryptoFileTests.hs](../tests/CoreTests/CryptoFileTests.hs) | Round-trip |
| XRCP session (SHA3-256 hybrid, sb chain) | [tests/RemoteControl.hs](../tests/RemoteControl.hs) | End-to-end |
| SMP authenticators, block encryption, `IdsHash` (MD5) | [tests/ServerTests.hs](../tests/ServerTests.hs) | End-to-end; with the PostgreSQL queue store this checks Haskell MD5 against pgcrypto |
| Haskell and xftp-web: SHA-256/512, Ed25519, Ed448 identity proof, X25519, DER keys, crypto_box, secretbox, tail-tag, authenticator, file encryption | [tests/XFTPWebTests.hs](../tests/XFTPWebTests.hs) (`XFTP Web Client`) | Byte-identical cross-language output |
