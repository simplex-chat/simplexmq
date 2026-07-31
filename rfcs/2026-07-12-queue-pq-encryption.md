---
Proposed: 2026-07-12
Protocol: smp-client (new version)
---

# Post-quantum encryption of the SMP queue layer

## Problem

A message sent to a queue outside an established double ratchet has one layer of end-to-end encryption: NaCl crypto_box over an X25519 DH secret. The sender generates an ephemeral X25519 key, computes the secret with the recipient's per-queue DH key, and puts its ephemeral key in the message public header (`agentCbEncryptOnce`). This layer protects invitations, confirmations, and the profile sent with them.

It is not post-quantum. An adversary that records this traffic and later has a quantum computer can recover the X25519 secret and decrypt it. The double ratchet adds a post-quantum KEM once it is established, but the first message to a queue, before the ratchet, has only X25519.

This RFC adds post-quantum protection to the single-shot queue encryption itself, for cases that do not establish a double ratchet from the first message. Where a double ratchet is established from the first message (see the address-DR RFC), the ratchet provides post-quantum protection and this layer is not needed.

## Solution

Extend the single-shot queue encryption to a hybrid X25519 + sntrup761 scheme, in a new SMP client version. The recipient publishes a KEM encapsulation key alongside its per-queue DH key. The sender encapsulates to it, combines the KEM shared secret with the X25519 DH secret, and encrypts the body with the combined secret. The KEM ciphertext travels in the message public header next to the ephemeral X25519 key.

Recording the traffic and breaking X25519 later is not sufficient: without breaking sntrup761 as well, the combined secret is not recoverable.

## Design

The message public header (`PubHeader`) gains a hybrid variant, selected by a version and a tag, so older senders and the empty-header case are unchanged:

```abnf
smpPubHeaderHybrid = smpClientVersion %s"2" senderPublicDhKey kemCiphertext
senderPublicDhKey = length x509encoded ; sender ephemeral X25519 key
kemCiphertext = largeString ; sntrup761 ciphertext, 1039 bytes
```

The secret combines both shared secrets, and the body is encrypted with NaCl secret_box (the DH-only path uses crypto_box today; the combined secret is no longer a plain DH result, so it is used as a secret_box key), padded to the same lengths:

```
secret = HKDF(dh(recipient key, sender ephemeral key) || KEM shared secret)
```

The recipient's KEM encapsulation key is distributed the same way its per-queue DH key is today - in the queue address for a connection request, and in link data for a short link. The KEM ciphertext is stored the same way the ephemeral DH key is: in the public header, readable by the destination server (and not by the proxy with proxied sending), which cannot derive the secret without the recipient's KEM private key.

The recipient stores the computed secret the way the per-queue DH secret is stored on receiving the first message (`setRcvQueueConfirmedE2E`), and reuses it for later messages on the queue.

Sizes: the KEM ciphertext is 1039 bytes and the encapsulation key 1158 bytes. Link data user data is padded to 13784 bytes, so the key fits with application data. This RFC is independent of the RPC, SSND, and address-DR RFCs.
