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

The published keys follow the X3DH structure:

- The link ratchet key - the stable first X3DH key - goes in the immutable fixed link data, next to the root key, committed by the link hash.
- The prekey, the KEM encapsulation key, and the e2e version range go in the mutable user data as a ratchet-keys bundle with an id, signed by the root key, rotated with `LSET`.

This is backward compatible. A requester that does not use the published keys sends a current `AgentInvitation` with its own X3DH keys, and the owner does what it does today: generates fresh X3DH keys and sends them in the confirmation. The owner branches on whether the incoming message uses the published keys.

Two properties follow. The first message, including the profile, is under the double ratchet, which closes the profile gap and gives it post-quantum protection through the ratchet's sntrup761 KEM. And a decryptable message proves the sender established X3DH against the link ratchet key committed by the link hash, so it authenticates the address owner without a separate signature.

## Design

Syntax uses [ABNF][1] with [case-sensitive strings extension][2]. Key and ratchet types are as in `Crypto.Ratchet` and the [agent protocol](../protocol/agent-protocol.md); all DH keys are X448, the KEM is sntrup761.

### Published keys in link data

The link ratchet key is appended to fixed link data:

```abnf
fixedData =/ linkRatchetKey ; appended, ignored by earlier versions
linkRatchetKey = %s"0" / (%s"1" length x509encoded) ; X448, stable, the first X3DH key
```

The ratchet-keys bundle is appended to contact user data:

```abnf
userContactData =/ ratchetKeys ; appended, ignored by earlier versions
ratchetKeys = %s"0" / (%s"1" ratchetKeyId e2eVRange prekey kemKey)
ratchetKeyId = shortString ; identifies this bundle, changes on rotation, echoed in the request
e2eVRange = <e2e encryption version range, for negotiation>
prekey = length x509encoded ; X448
kemKey = %s"0" / (%s"1" largeString) ; sntrup761 encapsulation key, optional (PQ is opt-in)
```

Together these reconstruct the owner's X3DH contribution as an `RcvE2ERatchetParamsUri` - a version-range form: `linkRatchetKey` (from fixed data) as the first key, `prekey` as the second, `kemKey` as the optional KEM parameter, `e2eVRange` as the version range. The requester negotiates the concrete version against its own e2e range, as it does for an invitation, then runs `pqX3dhSnd` against the result.

The owner keeps the private prekey and, when PQ is on, the KEM keypair, indexed by `ratchetKeyId`. On rotation with `LSET` it publishes a new bundle with a new `ratchetKeyId` and keeps the previous private keys for a window covering queue message retention, so a request that used a just-rotated prekey still decrypts. The link ratchet key is stable and not rotated.

### Request confirmation

A requester that uses the published keys establishes the sending ratchet before its first message, so it sends that message as a confirmation, not an invitation - the same envelope a joining party sends in a connection. The confirmation gains an optional `ratchetKeyId` naming the bundle the requester used, so the owner selects the matching private keys:

```abnf
agentConfirmation =/ ratchetKeyId ; the bundle the requester used, echoed; absent on other confirmations
```

The confirmation holds the requester's Snd X3DH parameters (so the owner runs `pqX3dhRcv`) and, encrypted under the ratchet, the first message. A confirmation with `ratchetKeyId` on a contact address takes the published-key path; an `AgentInvitation`, as today, takes the current path where the owner generates fresh X3DH keys and returns them in its own confirmation. A connection-request URI is unchanged: it advertises the requester's Rcv parameters and must not include Snd parameters.

### Establishing the ratchet

Requester:

1. Retrieve link data (`LGET`), read the link ratchet key, the prekey with its `ratchetKeyId`, the `e2eVRange`, and the optional KEM key, reconstruct the owner's `RcvE2ERatchetParamsUri`, and negotiate the concrete version against its own e2e range.
2. `generateSndE2EParams` for its own X3DH contribution (with the KEM only when the address advertises one).
3. `pqX3dhSnd` against the owner's parameters, then `initSndRatchet` - the sending ratchet.
4. Encrypt the first message under the ratchet, and send a confirmation with its Snd parameters and `ratchetKeyId`.

Owner:

1. On a confirmation with `ratchetKeyId` on a contact address, select the private prekey and, if any, KEM keypair by `ratchetKeyId` (current or a retained previous generation).
2. `pqX3dhRcv` against the requester's Snd parameters with the link ratchet, prekey, and optional KEM private keys, then `initRcvRatchet` - the receiving ratchet. Decrypting the first message advances the ratchet and gives it a send side, so the owner can reply.
3. Decrypt, and reply under the ratchet.

A request whose `ratchetKeyId` is no longer retained cannot be decrypted; the owner does not learn the requester or its reply address, and the requester's attempt fails at its own timeout.

### Authentication

The ratchet is established against the link ratchet key committed by the link hash and the prekey signed by the root key, so a decryptable message proves the sender established X3DH against the owner's published, link-committed keys. Where a message today relies on a separate signature over its content for authenticity, this establishment provides it, and the signature is not needed. The link ratchet key is a DH key (X448) and X3DH is over crypto_box, so deniability is preserved; the signing identity (the root key) and the DH key are separate keys, both anchored to the link hash. Reusing the link ratchet key across requesters is consistent with the address already being a shared identifier.

## Uses

- Invitations to an address, and the profile in them, are under the double ratchet from the first message.
- The service RPC (see the RPC RFC) establishes the ratchet this way to send the request as the first ratchet message.

This RFC depends on nothing else here. It replaces the need for the PQ-queue RFC in the address case, because the ratchet provides post-quantum protection for the first message; the PQ-queue RFC remains for first messages that do not establish a ratchet.

[1]: https://tools.ietf.org/html/rfc5234
[2]: https://tools.ietf.org/html/rfc7405
