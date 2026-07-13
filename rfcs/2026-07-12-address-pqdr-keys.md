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

- The identity key goes in the immutable fixed link data, next to the root key, committed by the link hash. It is stable.
- The prekey and the KEM encapsulation key go in the mutable user data, signed by the root key, rotated with `LSET`.

This is backward compatible. A requester that does not use the published keys sends a current `AgentInvitation` with its own X3DH keys, and the owner does what it does today: generates fresh X3DH keys and sends them in the confirmation. The owner branches on whether the incoming message uses the published keys.

Two properties follow. The first message, including the profile, is under the double ratchet, which closes the profile gap and gives it post-quantum protection through the ratchet's sntrup761 KEM. And a decryptable message proves the sender established X3DH against the identity key committed by the link hash, so it authenticates the address owner without a separate signature.

## Design

Syntax uses [ABNF][1] with [case-sensitive strings extension][2]. Key and ratchet types are as in `Crypto.Ratchet` and the [agent protocol](../protocol/agent-protocol.md); all DH keys are X448, the KEM is sntrup761.

### Published keys in link data

The identity key is appended to fixed link data:

```abnf
fixedData =/ addressIdentityKey ; appended, ignored by earlier versions
addressIdentityKey = %s"0" / (%s"1" length x509encoded) ; X448
```

The prekey and KEM key are appended to contact user data:

```abnf
userContactData =/ addressRatchetKeys ; appended, ignored by earlier versions
addressRatchetKeys = %s"0" / (%s"1" prekeyId prekey kemKey)
prekeyId = shortString ; identifies the prekey, echoed in the request
prekey = length x509encoded ; X448
kemKey = largeString ; sntrup761 encapsulation key
```

Together with the version range in fixed data these reconstruct an `RcvE2ERatchetParams` (the owner's X3DH contribution): identity key as the first key, prekey as the second, KEM key as the KEM parameter.

The owner keeps the private prekey and KEM key indexed by `prekeyId`. On rotation with `LSET` it publishes a new pair with a new id and keeps the previous private pair for a window covering queue message retention, so a request that used a just-rotated prekey still decrypts. The identity key is not rotated.

### Existential ratchet in the request

`CRInvitationUri` fixes the ratchet parameters to `RcvE2ERatchetParamsUri 'C.X448` today. It becomes existential over the establishment form, so a message can include either the current inline parameters or a reference to the published address keys:

```haskell
data AddressE2EParams
  = InlineE2EParams (RcvE2ERatchetParamsUri 'C.X448) -- current: requester's own keys
  | PublishedE2EParams ByteString (SndE2ERatchetParams 'C.X448) -- prekeyId, requester's Snd params
```

`InlineE2EParams` is the current message. `PublishedE2EParams` names the prekey the requester used (so the owner selects the matching private keys) and includes the requester's Snd X3DH parameters (so the owner runs `pqX3dhRcv`). The owner branches on the constructor: `PublishedE2EParams` takes the published-key path with `pqX3dhRcv` against the stored private keys; `InlineE2EParams` takes the current path, generating fresh Snd params and sending them in the confirmation.

### Establishing the ratchet

Requester:

1. Retrieve link data (`LGET`), read the identity key, the prekey with its id, and the KEM key, and reconstruct the owner's `RcvE2ERatchetParams`.
2. `generateSndE2EParams` for its own X3DH contribution.
3. `pqX3dhSnd` against the owner's parameters, then `initSndRatchet` - the sending ratchet.
4. Encrypt the first message under the ratchet, and include `PublishedE2EParams prekeyId sndParams`.

Owner:

1. On a message with `PublishedE2EParams prekeyId sndParams`, select the private prekey and KEM key by `prekeyId` (current or a retained previous pair).
2. `pqX3dhRcv` against `sndParams` with the identity, prekey, and KEM private keys, then `initRcvRatchet` - the receiving ratchet.
3. Decrypt, and reply under the ratchet.

A request whose `prekeyId` is no longer retained cannot be decrypted; the owner does not learn the requester or its reply address, and the requester's attempt fails at its own timeout.

### Authentication

The ratchet is established against the identity key committed by the link hash, so a decryptable message proves the sender holds that identity key. Where a message today relies on a separate signature over its content for authenticity, this establishment provides it, and the signature is not needed. The identity key is a DH key and X3DH is over crypto_box, so deniability is preserved, and reuse of the identity key across requesters is consistent with the address already being a shared identifier.

## Uses

- Invitations to an address, and the profile in them, are under the double ratchet from the first message.
- The service RPC (see the RPC RFC) establishes the ratchet this way to send the request as the first ratchet message.

This RFC depends on nothing else here. It replaces the need for the PQ-queue RFC in the address case, because the ratchet provides post-quantum protection for the first message; the PQ-queue RFC remains for first messages that do not establish a ratchet.

[1]: https://tools.ietf.org/html/rfc5234
[2]: https://tools.ietf.org/html/rfc7405
