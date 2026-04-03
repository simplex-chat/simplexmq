# Simplex.RemoteControl.Invitation

> XRCP invitation creation, dual-signature scheme, and URI encoding.

**Source**: [`RemoteControl/Invitation.hs`](../../../../../../src/Simplex/RemoteControl/Invitation.hs)

## Dual-signature chain

`signInvitation` applies two Ed25519 signatures in a specific order that creates a chain:

1. `ssig` signs the invitation URI with the **session** private key
2. `idsig` signs the URI **with `ssig` appended** using the **identity** private key

Verification in `verifySignedInvitation` mirrors this: `ssig` is verified against the bare URI, `idsig` against the URI+ssig concatenation. This chain means `idsig` covers both the invitation content and the session key's signature — a compromised session key cannot forge an identity-valid invitation.

## Invitation URI format

The `xrcp:/` scheme uses the SMP-style pattern: CA fingerprint as userinfo (`ca@host:port`), query parameters after `#/?`. The `app` field is raw JSON encoded in a query parameter. `RCInvitation`'s parser uses `parseSimpleQuery` + `lookup` (order-independent).

## RCVerifiedInvitation — newtype trust boundary

`RCVerifiedInvitation` is a newtype wrapper. The constructor is exported (via `RCVerifiedInvitation (..)`), so it can be constructed without validation — the trust boundary is conventional, not enforced by the type system. `verifySignedInvitation` is the intended smart constructor. [Client.hs](./Client.md) accepts only `RCVerifiedInvitation` for `connectRCCtrl`.

## RCEncInvitation — multicast envelope

`RCEncInvitation` wraps a signed invitation for UDP multicast: ephemeral DH public key + nonce + encrypted body. The encryption uses a DH shared secret between the host's DH public key (known to the controller from the pairing) and the controller's ephemeral DH private key. Uses `Tail` encoding for the ciphertext (no length prefix — consumes remaining bytes).
