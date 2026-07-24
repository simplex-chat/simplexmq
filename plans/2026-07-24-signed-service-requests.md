# Signed service requests

Optional Ed25519 signature on service RPC requests, constructed and verified in the agent (not the bot), bound to the request's double ratchet. Requests only — responses stay authenticated by the address/ratchet. Signing is optional; a bot decides whether to require it. The agent is stateless: the meaning of a signer key (identity, resource) is the bot's concern.

## Wire — `Simplex.Messaging.Agent.Protocol`

Extend the existing `'A'` inner message; `Maybe` absent = unsigned, so the unsigned path is unchanged:

```haskell
AgentServiceRequest (NonEmpty SMPQueueInfo) (Maybe RequestSignature) MsgBody

data RequestSignature = RequestSignature C.PublicKeyEd25519 (C.Signature 'C.Ed25519)
```

## Binding

```
binding = sha3-256("SimpleXService" <> rcAD)
sig     = Ed25519.sign(sk, binding <> payload)
```
The service recomputes `binding` from its own `rcAD` and verifies.

- `rcAD` = the ratchet associated data (`Ratchet.rcAD`) — the shared connection security code: identical on both ratchets by construction (`pubKey(requester ephemeral) <> pubKey(service key)`), stable, and unique per request (fresh requester ephemeral). Already on the ratchet; nothing derived or stored.
- sha3-256 here is not for uniformity or secrecy (both moot: the value is signed, not keyed, and only a ratchet holder can craft a valid request). It gives a canonical fixed-length, domain-tagged binding; the 32-byte fixed prefix also makes `binding <> payload` unambiguous.
- Domain string `"SimpleXService"`: separates this signature from other uses of the signing key.
- Not covered: reply queues (the AEAD protects them in transit; addresses may use redundant queues).
- Anti-relay: a signature bound to one session's rcAD does not verify under another's (both parties' keys differ). Replay of the encrypted blob is handled separately by transport dedup.

## Sign (requester) — `Simplex.Messaging.Agent`

- `sendServiceRequest` / `sendServiceRequestAsync` gain a `Maybe` Ed25519 signing key.
- `joinConnSrv'` DR path takes the ratchet straight from the `createRatchet_`/`getSndRatchet` line (both now yield `(RatchetX448, params)`) and computes `serviceReqBinding` from its `rcAD`; the `mkInner :: SMPQueueInfo -> ByteString -> AgentMessage` closure calls `signServiceReq signKey_ binding payload` — `RequestSignature pub (sign' pk (binding <> payload))` when a key is given, `Nothing` otherwise.
- Async carries the key in `JRServiceReq {requestKey :: Maybe C.PrivateKeyEd25519}` (enabled `StrEncoding (PrivateKey Ed25519)`); the JOIN worker deserializes it and signs after building the ratchet.

**Status:** implemented and tested in simplexmq-3 (sync + async); invalid signature → `A_SERVICE ASEBadSignature` (logs + `ERR` event), no invitation.

## Verify (service) — `smpContactRequest`

After `initRcvRatchet_` + decrypt, on `AgentServiceRequest (replyQueue :| _) sig_ payload`, one helper does the check:

`verifyServiceReq rc payload sig_ :: Either String (Maybe C.PublicKeyEd25519)`
- `Nothing` → `Right Nothing` (unsigned).
- `Just (RequestSignature key sig)` → recompute `serviceReqBinding rc` and `C.verify' key sig (binding <> payload)`; `Right (Just key)` if valid, else `Left err`.

Then:
- `Right key_` → `storeInvitation … True` + `notify $ SREQ invId key_ payload`.
- `Left err` → `logError` + `notify (ERR (AGENT (A_SERVICE ASEBadSignature)))`, no invitation.

Dedup unchanged.

## Event / API

- `SREQ :: InvitationId -> Maybe C.PublicKeyEd25519 -> MsgBody -> AEvent AEConn`.
- `StrEncoding (PrivateKey Ed25519)` enabled so a caller (e.g. via `JRServiceReq`) can carry the signing key.

## Tests

- `testSignedServiceRequest` (sync) + `testSignedServiceRequestAsync` — signed round-trip delivers the exact signer key on `SREQ` (`sigKey_ == Just signPub`).
- Unsigned path unchanged (existing service tests carry `Nothing` for the new field).
