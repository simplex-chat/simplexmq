# Encryption

TODO - subjects to cover:

## TLS layer

**Protocol**: [simplex-messaging.md#tls-transport-encryption](../../protocol/simplex-messaging.md#tls-transport-encryption)
**Code**: [Transport.hs](../../src/Simplex/Messaging/Transport.hs), [Transport/Credentials.hs](../../src/Simplex/Messaging/Transport/Credentials.hs)

- **Cipher suites**: CHACHA20-POLY1305-SHA256 (TLS 1.3), ECDHE-ECDSA-CHACHA20-POLY1305 (TLS 1.2)
- **Signature algorithms**: Ed448, Ed25519 (HashIntrinsic)
- **DH groups**: X448, X25519
- **Certificate fingerprints**: SHA256
- **Browser-compatible extension**: RSA, ECDSA-SHA256/384/512, P521 for XFTP web

## Transport block encryption (optional, v11+)

**Protocol**: [simplex-messaging.md#transport-handshake](../../protocol/simplex-messaging.md#transport-handshake)
**Code**: [Crypto.hs#sbcInit](../../src/Simplex/Messaging/Crypto.hs), [Transport.hs#tPutBlock](../../src/Simplex/Messaging/Transport.hs)

- **Algorithm**: XSalsa20-Poly1305 (NaCl secret_box)
- **Key derivation**: `sbcInit` - HKDF-SHA512(salt=sessionId, ikm=dhSecret, info="SimpleXSbChainInit")
- **Chain advancement**: `sbcHkdf` - HKDF-SHA512(salt="", ikm=chainKey, info="SimpleXSbChain")
- **16-byte auth tag** reduces available payload

## SMP queue layer

**Protocol**: [simplex-messaging.md#cryptographic-algorithms](../../protocol/simplex-messaging.md#cryptographic-algorithms), [simplex-messaging.md#deniable-client-authentication-scheme](../../protocol/simplex-messaging.md#deniable-client-authentication-scheme)
**RFC** (design rationale): [2026-03-09-deniability.md](../../rfcs/standard/2026-03-09-deniability.md)
**Code**: [Crypto.hs#cbEncrypt](../../src/Simplex/Messaging/Crypto.hs), [Protocol.hs](../../src/Simplex/Messaging/Protocol.hs)

- **Message body encryption**: NaCl crypto_box (X25519 + XSalsa20-Poly1305) with per-queue DH secret
- **Recipient/notifier commands**: Ed25519/Ed448 signatures
- **Sender commands**: X25519 DH-based `CbAuthenticator` (80 bytes = SHA512 hash encrypted with crypto_box) - provides deniability
- **Nonce**: correlation ID (24 bytes)
- **Server-to-recipient encryption**: `encryptMsg` with XSalsa20-Poly1305, nonce derived from message ID

## SMP proxy layer

**Protocol**: [simplex-messaging.md#sending-messages-via-proxy-router](../../protocol/simplex-messaging.md#sending-messages-via-proxy-router)
**Code**: [Protocol.hs#PRXY](../../src/Simplex/Messaging/Protocol.hs), [Server.hs](../../src/Simplex/Messaging/Server.hs)

- **Double encryption**: client encrypts for relay (s2r), proxy adds layer for relay (p2r)
- **Per-session X25519 keys**: PKEY response contains relay's DH key signed by relay certificate
- **Session ID binding**: `tlsunique` from proxy-relay TLS session included in encrypted transmission
- **PFWD/RFWD**: correlation ID (24 bytes) used as crypto_box nonce

## Agent/E2E layer (double ratchet)

**Protocol**: [pqdr.md](../../protocol/pqdr.md)
**RFC** (versioning/migration): [2026-03-09-pqdr-version.md](../../rfcs/standard/2026-03-09-pqdr-version.md)
**Code**: [Crypto/Ratchet.hs](../../src/Simplex/Messaging/Crypto/Ratchet.hs), [Crypto/SNTRUP761.hs](../../src/Simplex/Messaging/Crypto/SNTRUP761.hs)

- **DH algorithm**: X448 (not X25519) - `RatchetX448`
- **Post-quantum KEM**: SNTRUP761, hybrid secret = SHA3-256(DHSecret || KEMSharedKey)
- **Key derivation**: HKDF-SHA512 with context strings
- **Header encryption**: AES-256-GCM with header key (HKs)
- **Body encryption**: AES-256-GCM with message key derived from chain key
- **Associated data**: ratchet AD concatenated with encrypted header
- **Split-phase**: header encryption (API thread, serialized) vs body encryption (delivery worker, parallel)

## XFTP file layer

**Protocol**: [xftp.md#cryptographic-algorithms](../../protocol/xftp.md#cryptographic-algorithms)
**Code**: [Crypto/File.hs](../../src/Simplex/Messaging/Crypto/File.hs), [Crypto/Lazy.hs](../../src/Simplex/Messaging/Crypto/Lazy.hs), [FileTransfer/Crypto.hs](../../src/Simplex/FileTransfer/Crypto.hs)

- **File encryption**: XSalsa20-Poly1305 (NaCl secret_box), random 32-byte key + 24-byte nonce per file
- **File integrity**: SHA512 digest in FileDescription
- **Command signing**: Ed25519 per-chunk keys from FileDescription
- **Transit encryption**: per-download X25519 DH, server returns ephemeral key with FGET response
- **Streaming**: Poly1305 state updated per chunk, 16-byte auth tag at end (tail tag pattern)

## NTF (notifications)

**Protocol**: [push-notifications.md](../../protocol/push-notifications.md)
**Code**: [Notifications/Protocol.hs](../../src/Simplex/Messaging/Notifications/Protocol.hs), [Notifications/Transport.hs](../../src/Simplex/Messaging/Notifications/Transport.hs)

- **E2E encryption**: NaCl crypto_box between router and client
- **Key exchange**: X25519 DH (clientDhPubKey in TNEW, routerDhPubKey in response)
- **Command auth**: Ed25519

## Short links

**Protocol**: [agent-protocol.md#short-invitation-links](../../protocol/agent-protocol.md#short-invitation-links)
**Code**: [Crypto/ShortLink.hs](../../src/Simplex/Messaging/Crypto/ShortLink.hs)

- **Link key derivation**: SHA3-256(fixedLinkData)
- **Data encryption**: NaCl secret_box (XSalsa20-Poly1305) with HKDF-derived key
- **Fixed/user data**: padded to fixed sizes (2008/13784 bytes) for traffic analysis resistance
- **Signatures**: Ed25519 for owner authentication

## Remote control (XRCP)

**Protocol**: [xrcp.md](../../protocol/xrcp.md)
**Code**: [RemoteControl/Client.hs](../../src/Simplex/RemoteControl/Client.hs), [Crypto/SNTRUP761.hs](../../src/Simplex/Messaging/Crypto/SNTRUP761.hs)

- **Session key**: SHA3-256(dhSecret || kemSharedKey) - hybrid DH + SNTRUP761 KEM
- **Chain keys**: `sbcInit` with HKDF-SHA512, keys swapped between controller and host
- **Command signing**: Ed25519 session key + long-term key (dual signature)

## Service certificates

**Protocol**: [simplex-messaging.md#service-certificates](../../protocol/simplex-messaging.md#service-certificates)
**RFC** (design rationale): [2026-03-10-client-certificates.md](../../rfcs/standard/2026-03-10-client-certificates.md)
**Code**: [Agent/Client.hs#getServiceCredentials](../../src/Simplex/Messaging/Agent/Client.hs), [Transport/Credentials.hs](../../src/Simplex/Messaging/Transport/Credentials.hs)

- **Certificate type**: X.509 with Ed25519 signing key
- **Per-session keys**: fresh Ed25519 key pair per connection, signed by X.509 key
- **Fingerprint**: SHA256 of identity certificate
- **Proof-of-possession**: session key signed by service certificate

## Primitives reference

**Code**: [Crypto.hs](../../src/Simplex/Messaging/Crypto.hs)

- **NaCl crypto_box** (`cbEncrypt`/`cbDecrypt`): X25519 DH + XSalsa20-Poly1305
- **NaCl crypto_secretbox** (`sbEncrypt`/`sbDecrypt`): symmetric XSalsa20-Poly1305
- **AES-256-GCM** (`encryptAEAD`/`decryptAEAD`): for ratchet message bodies
- **SNTRUP761**: post-quantum KEM via C FFI bindings - [Crypto/SNTRUP761.hs](../../src/Simplex/Messaging/Crypto/SNTRUP761.hs)
- **CbAuthenticator**: 80-byte authenticator = crypto_box(SHA512(message))
- **HKDF**: SHA512-based, used with various context strings
- **Hashes**: SHA256 (fingerprints), SHA512 (authenticators, HKDF), SHA3-256 (hybrid KEM, short links)

## Padding

**Code**: [Crypto.hs#pad](../../src/Simplex/Messaging/Crypto.hs)

- **Message padding** (`pad`/`unPad`): 2-byte big-endian length prefix + '#' fill
- **Short link data**: fixed-size encrypted blobs
- **XFTP hello**: 16384 bytes (indistinguishable from commands)
- **Ratchet header**: padded before encryption to hide KEM state

## Key type constraints

**Code**: [Crypto.hs](../../src/Simplex/Messaging/Crypto.hs)

- `SignatureAlgorithm`: Ed25519, Ed448 only
- `DhAlgorithm`: X25519, X448 only
- `AuthAlgorithm`: Ed25519, Ed448, X25519 (NOT X448) - for queue command auth
