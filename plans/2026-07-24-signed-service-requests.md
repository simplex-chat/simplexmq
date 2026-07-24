# Signed service requests

Optional Ed25519 signature on service RPC requests, constructed and verified in the agent (not the bot), bound to the request's double ratchet. Requests only — responses stay authenticated by the address/ratchet. Signing is optional; a bot decides whether to require it. The agent is stateless: the meaning of a signer key (identity, resource) is the bot's concern.

## Wire — `Simplex.Messaging.Agent.Protocol`

Extend the existing `'A'` inner message; `Maybe` absent = unsigned, so the unsigned path is unchanged:

```haskell
AgentServiceRequest (NonEmpty SMPQueueInfo) (Maybe RequestSignature) MsgBody

data RequestSignature = RequestSignature C.PublicKeyEd25519 C.Signature
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
- `joinConnSrv'` DR path takes the ratchet straight from the `createRatchet_`/`getSndRatchet` line (both now yield `(RatchetX448, params)`) and computes `serviceReqBinding` from its `rcAD`; the `mkInner :: SMPQueueInfo -> ByteString -> AgentMessage` closure signs the transcript when a key is given and emits `AgentServiceRequest … (Just (RequestSignature pub sig)) payload`, else `Nothing`.
- Async carries the key in `JRServiceReq {requestKey :: Maybe C.PrivateKeyEd25519}` (enabled `StrEncoding (PrivateKey Ed25519)`); the JOIN worker deserializes it and signs after building the ratchet.

**Status:** implemented and tested in simplexmq-3 (sync + async); invalid signature → `prohibited` (logs + `ERR` event), no invitation.

## Verify (service) — `smpContactRequest`

After `initRcvRatchet_` + decrypt, on `AgentServiceRequest _ sig_ payload`:

- `Just (RequestSignature key sig)`: verify over `serviceReqSignatureDomain <> rcRK <> payload`.
  - valid → `storeInvitation` + `notify $ SREQ invId (Just key) payload`.
  - invalid → log + `notify $ ERR …`, no invitation.
- `Nothing` → `notify $ SREQ invId Nothing payload`.

Dedup unchanged.

## Event / API

- `SREQ :: InvitationId -> Maybe C.PublicKeyEd25519 -> MsgBody`.

## Chat — `simplex-chat`

- `APISendServiceRequest` gains an optional signer key.
- `CEvtServiceRequest {…, signerKey :: Maybe C.PublicKeyEd25519}` (base64 field).
- Docs.

## Tests

- Signed round-trip → verified key delivered on `SREQ`.
- Tampered payload/signature → `ERR`, no invitation.
- Relay/replay under a different ratchet → signature fails.
- Unsigned path unchanged.
