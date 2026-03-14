# XRCP - Cross-Device Remote Control

XRCP enables a desktop application to control a mobile device over the local network. The protocol establishes an encrypted session between two devices using TLS, post-quantum hybrid key exchange, and optional multicast discovery.

This document covers the cross-module flows that are not visible from individual module specs. For message formats and cryptographic operations, see [protocol/xrcp.md](../../protocol/xrcp.md). For per-module details: [Client](../modules/Simplex/RemoteControl/Client.md) · [Invitation](../modules/Simplex/RemoteControl/Invitation.md) · [Discovery](../modules/Simplex/RemoteControl/Discovery.md) · [Types](../modules/Simplex/RemoteControl/Types.md).

**Terminology note**: in the code, "host" is the mobile device (being controlled) and "ctrl" is the desktop (controlling). The protocol spec uses the reverse convention - "host" serves, "controller" connects. This document uses the code convention.

- [Session handshake flow](#session-handshake-flow)
- [KEM hybrid key exchange](#kem-hybrid-key-exchange)
- [Multicast discovery](#multicast-discovery)
- [Block framing and padding](#block-framing-and-padding)

---

## Session handshake flow

**Source**: [RemoteControl/Client.hs](../../src/Simplex/RemoteControl/Client.hs), [RemoteControl/Discovery.hs](../../src/Simplex/RemoteControl/Discovery.hs)

The handshake spans `Client.connectRCHost` (controller side, despite the name), `Client.connectRCCtrl` (host side), `Invitation.mkInvitation`, and `Discovery.startTLSServer`. The full sequence:

1. **Controller starts TLS server**: generates ephemeral session keys + DH keys, creates a signed invitation containing the CA fingerprint and identity key, starts a TLS server on an ephemeral port. The TLS hook `onNewHandshake` enforces single-session - a second connection attempt is rejected by checking whether the session TMVar is already filled.

2. **Invitation delivery**: the invitation reaches the host either out-of-band (QR code scan for first pairing) or via encrypted multicast announcement (subsequent sessions - see [Multicast discovery](#multicast-discovery)).

3. **Host connects via TLS**: `connectRCCtrl` establishes a TLS connection. Both sides validate 2-certificate chains (leaf + CA root). On reconnection, the host validates the controller's CA fingerprint against `KnownHostPairing`; on first pairing, it stores the fingerprint.

4. **User confirmation barrier**: after TLS connects, the controller extracts the TLS channel binding (`tlsUniq`) as a session code. The application displays this code; the user verifies it on the host. `confirmCtrlSession` uses a double `putTMVar` - the first put signals the decision (accept/reject), the second blocks until the session thread consumes it, creating a synchronization point that prevents the session from proceeding before confirmation completes.

5. **Hello exchange** (asymmetric encryption):
  - Controller sends `RCHostEncHello`: DH public key in plaintext + encrypted body containing the KEM encapsulation key, CA fingerprint, and app info. Encrypted with `cbEncrypt` (classical DH secret).
  - Host decrypts the hello, performs KEM encapsulation (see [KEM hybrid key exchange](#kem-hybrid-key-exchange)), derives the hybrid session key, and sends `RCCtrlEncHello` encrypted with `sbEncrypt` (post-quantum hybrid key).
  - The asymmetry is deliberate: at the time the controller sends its hello, KEM hasn't completed yet, so only classical DH encryption is available. After the host encapsulates, both sides have the hybrid key.

6. **Chain key initialization**: both sides call `sbcInit` with the hybrid key to derive send/receive chain keys. The controller explicitly **swaps** the key pair (`swap` call in `prepareCtrlSession`) - both sides derive keys in the same order from `sbcInit`, but have opposite send/receive roles, so the controller must reverse them. The host does not swap.

7. **Error path**: if KEM encapsulation fails, the host sends `RCCtrlEncError` encrypted with the DH key (not the hybrid key, which doesn't exist yet). The controller can decrypt the error because it has the DH secret from step 5.

---

## KEM hybrid key exchange

**Source**: [RemoteControl/Client.hs](../../src/Simplex/RemoteControl/Client.hs)

The session key combines classical Diffie-Hellman with SNTRUP761 (lattice-based KEM) via `SHA3_256(dhSecret || kemSharedKey)` (`kemHybridSecret` in Client.hs). This provides protection against quantum computers while maintaining classical security as a fallback.

**First session** - KEM public key is too large for a QR code invitation, so it travels in the encrypted hello body:

1. Controller generates DH + KEM key pairs, puts KEM encapsulation key in the hello body
2. Host decrypts hello with DH secret, extracts KEM encapsulation key
3. Host encapsulates: produces `(kemCiphertext, kemSharedKey)`
4. Host derives hybrid key: `SHA3_256(dhSecret || kemSharedKey)`
5. Host sends `kemCiphertext` in the controller hello body
6. Controller decapsulates `kemCiphertext` to recover `kemSharedKey`, derives the same hybrid key

**Subsequent sessions** (via multicast) - the previous session's KEM secret is cached in the pairing:

- Both sides already know each other's KEM capabilities from the previous session
- Fresh DH keys are generated per session for forward secrecy
- The hybrid key derivation uses the new DH secret + the cached KEM secret
- `updateKnownHost` (called in `prepareHostSession`) updates the stored DH public key for the next session

**Key rotation and `prevDhPrivKey`**: when the host updates its DH key pair for a new session, it retains the previous private key in `RCCtrlPairing.prevDhPrivKey`. This is critical for multicast - during the transition window, the controller may send announcements encrypted with the old public key. `findRCCtrlPairing` tries decryption with both the current and previous DH keys. Without this fallback, key rotation would break multicast discovery.

---

## Multicast discovery

**Source**: [RemoteControl/Client.hs](../../src/Simplex/RemoteControl/Client.hs), [RemoteControl/Invitation.hs](../../src/Simplex/RemoteControl/Invitation.hs), [RemoteControl/Discovery.hs](../../src/Simplex/RemoteControl/Discovery.hs)

For subsequent sessions (after initial QR pairing), the controller announces its presence via UDP multicast so the host can connect without scanning a new QR code. The flow spans `Client.announceRC`, `Client.discoverRCCtrl`, `Client.findRCCtrlPairing`, `Invitation.signInvitation`/`verifySignedInvitation`, and `Discovery.joinMulticast`/`withSender`.

**Announcement creation** (`announceRC`):

1. The invitation is signed with a dual-signature chain: the session key signs the invitation URI, then the identity key signs the URI + session signature concatenated. This chain means a compromised session key alone cannot forge a valid identity-signed announcement - the identity key must also be compromised.
2. The signed invitation is encrypted with a DH shared secret between the host's known DH public key and the controller's ephemeral DH private key.
3. The encrypted packet is padded to 900 bytes (privacy: all announcements are indistinguishable by size).
4. Sent 60 times at 1-second intervals to multicast group `224.0.0.251:5227`.
5. Runs as a cancellable async task - cancelled in `prepareHostSession` once the session is established.

**Listener and discovery** (`discoverRCCtrl`):

1. Host calls `joinMulticast` to subscribe to the multicast group. A shared `TMVar Int` counter tracks active listeners - OS-level `IP_ADD_MEMBERSHIP` is only issued on 0→1 transition, `IP_DROP_MEMBERSHIP` on 1→0. This prevents duplicate syscalls when multiple listeners are active.
2. For each received packet, `findRCCtrlPairing` iterates over known pairings and tries decryption with the current DH key, falling back to `prevDhPrivKey` if present.
3. After successful decryption, the invitation's `dh` field is verified against the announcement's `dhPubKey` to prevent relay attacks.
4. Dual signatures are verified: session signature first, then identity signature.
5. 30-second timeout on the entire discovery process (`RCENotDiscovered` on expiry).

---

## Block framing and padding

**Source**: [RemoteControl/Client.hs](../../src/Simplex/RemoteControl/Client.hs), [RemoteControl/Types.hs](../../src/Simplex/RemoteControl/Types.hs)

XRCP uses three padding sizes at different protocol layers:

- **16,384 bytes** - XRCP block size for all session messages (hello, commands, responses). Matches SMP's block size. Hides message content size variation within the TLS session.
- **12,288 bytes** - hello body padding within the 16,384-byte block, after encryption overhead.
- **900 bytes** - multicast announcement padding. Constrained by typical UDP MTU to avoid fragmentation.

All padding uses the standard `pad`/`unPad` format (2-byte length prefix + `#` fill). The fixed sizes ensure that an observer monitoring network traffic cannot distinguish different XRCP operations by packet size.
