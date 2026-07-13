---
Proposed: 2026-07-12
Protocol: agent-protocol (new version)
---

# Establishing the double ratchet from address data

## Problem

A contact address receives a connection request as an `AgentInvitation` message, encrypted only with the per-queue X25519 layer. The double ratchet is established later: the address owner joins the requester's connection request, generates its X3DH keys, and sends them in the confirmation. So the first message to an address - the invitation and the profile in it - is not under the double ratchet, and has no post-quantum protection.

The cause is that the address owner's X3DH contribution is generated per request and sent in the confirmation, so it cannot exist before the requester's first message.

## Solution

Publish the address owner's X3DH contribution in the address link data, so a requester can establish the double ratchet in its first message. The requester runs the existing `pqX3dhSnd` against the published keys, initializes a sending ratchet, and encrypts its first message under it. The owner runs the existing `pqX3dhRcv` against its stored private keys and the requester's X3DH keys from the message, initializes a receiving ratchet, and decrypts it.

Publish the owner's X3DH contribution - two X448 keys and an optional sntrup761 KEM key, with the e2e version range - as one bundle in the mutable contact user data, signed by the root key. The bundle is the existing `RcvE2ERatchetParamsUri` type that a one-time invitation already advertises, with an id for rotation.

This is backward compatible. A requester that does not use the published bundle sends a current `AgentInvitation` with its own X3DH keys, and the owner does what it does today: generates fresh X3DH keys and sends them in the confirmation. The owner branches on whether the incoming message uses the published bundle.

Three properties follow. The first message, including the profile, is under the double ratchet, which closes the profile gap and gives it post-quantum protection through the ratchet's sntrup761 KEM. A decryptable message proves the sender established X3DH against the root-signed keys, so it authenticates the address owner without a separate signature. And because the bundle is in mutable data, an existing address can advertise the double ratchet by updating its mutable data - no new link.

## Design

Syntax uses [ABNF][1] with [case-sensitive strings extension][2]. Key and ratchet types are as in `Crypto.Ratchet` and the [agent protocol](../protocol/agent-protocol.md); all DH keys are X448, the KEM is sntrup761.

### Published keys in link data

The owner's X3DH contribution is a ratchet-keys bundle appended to the mutable contact user data, signed by the root key. Nothing is added to the immutable fixed link data:

```abnf
userContactData =/ ratchetKeys ; appended, ignored by earlier versions
ratchetKeys = %s"0" / (%s"1" ratchetKeyId e2eParams)
ratchetKeyId = shortString ; identifies this bundle, changes on rotation, echoed in the request
e2eParams = <RcvE2ERatchetParamsUri: e2e version range, two X448 keys, optional sntrup761 key>
```

`e2eParams` is the existing `RcvE2ERatchetParamsUri` - the same type a one-time invitation advertises - so a requester reads it, negotiates the concrete e2e version against its own range, and runs `pqX3dhSnd` against it, exactly as it does for an invitation. The KEM key is optional (the params' KEM field is a `Maybe`), controlled by the address's initial-keys mode, the same 3-way choice as invitations: advertise the KEM (post-quantum from the first message), advertise X448-only but still support post-quantum if the requester proposes its own KEM (one message later, avoiding the ~1158-byte key in link data), or no post-quantum.

The owner keeps the private side of each bundle - the two X448 private keys and, when PQ is on, the KEM keypair - indexed by `ratchetKeyId`. On rotation with `LSET` it publishes a new bundle with a new `ratchetKeyId` and keeps the previous private keys for a window covering queue message retention, so a request that used a just-rotated bundle still decrypts. Because the bundle is in mutable data, an existing address advertises the double ratchet by updating its mutable data - no new link, no re-creation.

### Request confirmation

A requester that uses the published keys establishes the sending ratchet before its first message, so it sends that message as a confirmation, not an invitation - the same envelope a joining party sends in a connection. The confirmation gains an optional `ratchetKeyId` naming the bundle the requester used, so the owner selects the matching private keys:

```abnf
agentConfirmation =/ ratchetKeyId ; the bundle the requester used, echoed; absent on other confirmations
```

The confirmation holds the requester's Snd X3DH parameters (so the owner runs `pqX3dhRcv`) and, encrypted under the ratchet, the first message. A confirmation with `ratchetKeyId` on a contact address takes the published-key path; an `AgentInvitation`, as today, takes the current path where the owner generates fresh X3DH keys and returns them in its own confirmation. A connection-request URI is unchanged: it advertises the requester's Rcv parameters and must not include Snd parameters.

### Establishing the ratchet

Requester:

1. Retrieve link data (`LGET`), read the bundle - its `ratchetKeyId` and `e2eParams` (`RcvE2ERatchetParamsUri`) - and negotiate the concrete e2e version against its own range.
2. `generateSndE2EParams` for its own X3DH contribution - encapsulating to the bundle's KEM if it advertises one, or proposing its own KEM if the requester wants post-quantum and the bundle is X448-only.
3. `pqX3dhSnd` against the bundle's parameters, then `initSndRatchet` - the sending ratchet.
4. Encrypt the first message under the ratchet, and send a confirmation with its Snd parameters and `ratchetKeyId`.

Owner:

1. On a confirmation with `ratchetKeyId` on a contact address, select the private X3DH keys and, if any, KEM keypair by `ratchetKeyId` (current or a retained previous generation).
2. `pqX3dhRcv` against the requester's Snd parameters with those private keys, then `initRcvRatchet` - the receiving ratchet. Decrypting the first message advances the ratchet and gives it a send side, so the owner can reply.
3. Decrypt, and reply under the ratchet.

A request whose `ratchetKeyId` is no longer retained cannot be decrypted; the owner does not learn the requester or its reply address, and the requester's attempt fails at its own timeout.

### Authentication

The ratchet-keys bundle is in the mutable link data, signed by the root key. A decryptable message proves the sender established X3DH against those root-signed keys: an SMP server cannot substitute them without forging the root signature (`decryptLinkData` verifies it), which is the X3DH anti-substitution property. Where a message today relies on a separate signature over its content for authenticity, this establishment provides it, and the signature is not needed. The root Ed25519 key is the address's signing identity; the X3DH keys are separate DH keys (X448), and X3DH is over crypto_box, so deniability is preserved. A malicious server can still serve an older but validly-signed bundle (rollback to a retired generation); this is bounded by the retention window and by the ratchet advancing after the first message, and a per-key signature would not prevent it. Reusing a bundle across requesters is consistent with the address already being a shared identifier.

## Uses

- Invitations to an address, and the profile in them, are under the double ratchet from the first message.
- An existing address gains the double ratchet when the app updates its mutable link data (`LSET`, with the user's confirmation and current profile, combined with the full→short address migration); no new link is issued.
- The service RPC (see the RPC RFC) establishes the ratchet this way to send the request as the first ratchet message.

This RFC depends on nothing else here. It replaces the need for the PQ-queue RFC in the address case, because the ratchet provides post-quantum protection for the first message; the PQ-queue RFC remains for first messages that do not establish a ratchet.

[1]: https://tools.ietf.org/html/rfc5234
[2]: https://tools.ietf.org/html/rfc7405
