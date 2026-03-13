# Simplex.RemoteControl.Client

> XRCP session establishment: controller-host handshake with KEM hybrid key exchange, multicast discovery, and session encryption.

**Source**: [`RemoteControl/Client.hs`](../../../../../../src/Simplex/RemoteControl/Client.hs)

## Overview

This module implements the two sides of the XRCP remote control protocol: the **controller** side (`connectRCHost`) and the **host** side (`connectRCCtrl`). The naming follows [Types.md](./Types.md) — "host" means connecting **to** the host (controller's perspective).

The handshake is a multi-step flow using `RCStepTMVar` — a `TMVar (Either RCErrorType a)` that allows each phase to be observed and controlled by the application. The application receives the session code (TLS channel binding) for user verification before the session proceeds.

## Handshake flow

1. **Controller** starts TLS server, creates invitation with ephemeral session key + DH key + identity key
2. **Host** connects via TLS (with mutual certificate authentication), receives invitation out-of-band or via multicast
3. **Host** sends `RCHostEncHello`: ephemeral DH public key + nonce + encrypted hello body (containing KEM public key, CA fingerprint, app info)
4. **Controller** decrypts hello, verifies CA fingerprint matches TLS certificate, performs KEM encapsulation, derives hybrid key (DH + KEM), sends `RCCtrlEncHello` with KEM ciphertext + encrypted response
5. **Host** decrypts with KEM hybrid key, session established with `TSbChainKeys`

## KEM hybrid key derivation

The session key combines DH and post-quantum KEM via `kemHybridSecret`: `SHA3_256(dhSecret || kemSharedKey)`. This is used to initialize `sbcInit` chain keys. The chain keys are **swapped** between controller and host — `prepareCtrlSession` explicitly calls `swap` on the `sbcInit` result so that the controller's send key matches the host's receive key.

## Two-phase session with user confirmation

`connectRCCtrl` (host side) splits the session into two phases via `confirmSession` TMVar:

1. TLS connection established → first `RCStepTMVar` resolved with session code
2. Application displays session code for user verification → calls `confirmCtrlSession` with `True`/`False`
3. If confirmed, `runSession` proceeds with hello exchange → second `RCStepTMVar` resolved with session

`confirmCtrlSession` does a double `putTMVar` — the first signals the decision, the second blocks until the session thread does `takeTMVar` (synchronization point).

## TLS hooks — single-session enforcement

`tlsHooks` on the controller side enforces at most one TLS session: `onNewHandshake` checks if the result TMVar is still empty (`isNothing <$> tryReadTMVar r`). A second TLS connection attempt is rejected because `r` is already filled. Similarly, `onClientCertificate` validates the host's CA certificate chain (must be exactly 2 certs: leaf + CA) and checks the CA fingerprint against the known host pairing.

## Multicast discovery — prevDhPrivKey fallback

`findRCCtrlPairing` tries to decrypt the multicast announcement with each known pairing's current DH key, falling back to `prevDhPrivKey` if present. This handles the case where the host rotated its DH key (in `updateCtrlPairing` during `connectRCCtrl`) but the controller still has the old public key — the announcement is encrypted with the host's old DH public key, so the host needs its old private key to decrypt.

`discoverRCCtrl` wraps this in a 30-second timeout (`timeoutThrow RCENotDiscovered 30000000`) and an error-recovery loop — failed decryption attempts are logged and retried rather than aborting discovery.

After decryption, the invitation's `dh` field is verified against the announcement's `dhPubKey` to prevent a relay attack where someone re-encrypts a legitimate invitation with a different DH key.

## announceRC — fire-and-forget loop

Sends the signed invitation encrypted to the known host's DH key, repeated `maxCount` times (default 60) with 1-second intervals via UDP multicast. The announcement is padded to `encInvitationSize` (900 bytes). The announcer runs as a separate async that is cancelled when the session is established (`uninterruptibleCancel` in `runSession`).

## Session encryption — no padding

`rcEncryptBody` / `rcDecryptBody` use `sbEncryptTailTagNoPad` / `sbDecryptTailTagNoPad` — lazy streaming encryption without padding. This is for application-level data after the handshake, where message sizes are variable and padding would be wasteful. The auth tag is appended at the tail (not prepended).

## putRCError — error propagation to TMVar

`putRCError` is an error combinator that catches all errors from an `ExceptT` action and writes them to the step TMVar before re-throwing. This ensures the application observes the error via the TMVar even if the async thread terminates. Uses `tryPutTMVar` (not `putTMVar`) so the TMVar write is idempotent — if already filled, the write is skipped, but the error is still re-thrown via `throwE`.

## Asymmetric hello encryption

The two directions of the hello exchange use different encryption primitives. The host encrypts `RCHostEncHello` with `cbEncrypt` using the DH shared key directly (classical DH only). The controller encrypts `RCCtrlEncHello` with `sbEncrypt` using a key derived from `sbcHkdf` on the KEM-hybrid chain key (post-quantum protected). This asymmetry means the host's initial hello is only protected by classical DH, while the controller's response has post-quantum protection.

## Packet framing

`sendRCPacket` / `receiveRCPacket` use fixed-size 16384-byte blocks with `C.pad`/`C.unPad` (2-byte length prefix + '#' padding). The hello exchange uses a smaller 12288-byte block size (`helloBlockSize`) for the encrypted hello bodies within the padded packet.
