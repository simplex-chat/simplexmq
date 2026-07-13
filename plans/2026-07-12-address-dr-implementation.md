# Establishing the double ratchet from address data - implementation plan

RFC: [../rfcs/2026-07-12-address-pqdr-keys.md](../rfcs/2026-07-12-address-pqdr-keys.md)

All references are to the current tree. Names of new constructors, fields, tables and functions are provisional.

Goal: a contact address advertises the owner's X3DH parameters in link data; a requester establishes the double ratchet in its first message, so that message and the profile in it are under the ratchet with post-quantum protection. The change reuses the invitation/confirmation machinery, with the requester in the joiner role and the owner in the initiator role - opposite to today's contact flow, but every message and code path below is reused.

## Part 1 - the current contact-address handshake, step by step

Requester Alice connects to owner Bob's contact address. Q_A is Alice's receive queue (Bob to Alice), Q_B is Bob's receive queue (Alice to Bob).

Requester side, in `joinConnSrv … CRContactUri` (Agent.hs:1398-1428):

- R1. `compatibleContactUri` (Agent.hs:1370) - version check, yields the address queue `SMPQueueInfo`.
- R2. `mkJoinInvitation` (Agent.hs:1411): creates or reuses the receive queue Q_A; `getRatchetX3dhKeys` or `generateRcvE2EParams` produces Alice's Rcv X3DH parameters, stored by `createRatchetX3dhKeys` (Agent.hs:1424); builds `cReq = CRInvitationUri crData aliceRcvParams` (Agent.hs:1426).
- R3. `sendInvitation` (Agent.hs:1408; Agent/Client.hs:1924-1934): sends `AgentInvitation {connReq = cReq, connInfo = aliceProfile}` to the address queue, per-queue encrypted with a fresh ephemeral key by `agentCbEncryptOnce` (Agent/Client.hs:1929-1934), unauthenticated. **`connInfo` (Alice's profile) is under the per-queue X25519 layer only - the gap this plan closes.**

Owner side, receiving on the contact address:

- O1. `processClientMsg` dispatch (Agent.hs:3185): state `(Nothing, Just e2ePubKey)`, `(PHEmpty, AgentInvitation {connReq, connInfo})` -> `smpInvitation` (Agent.hs:3186).
- O2. `smpInvitation` (Agent.hs:3610): stores an `Invitation`, emits `REQ` with Alice's `connInfo`.
- O3. `acceptContact'` (Agent.hs:1477): `getInvitation`, then `joinConn` with Alice's `connReq` (Agent.hs:1480).
- O4. `joinConnSrv … CRInvitationUri` (Agent.hs:1383) -> `startJoinInvitation` (Agent.hs:1395).
- O5. `startJoinInvitation` (Agent.hs:1310-1350): creates Bob's send queue to Q_A (`newSndQueue`, Agent.hs:1335); `createRatchet_` (Agent.hs:1343-1350) runs `generateSndE2EParams`, `pqX3dhSnd` against Alice's Rcv parameters, `initSndRatchet`, `createSndRatchet`.
- O6. `secureConfirmQueue` (Agent.hs:1396, 3747-3765): `agentSecureSndQueue` secures Q_A with `SKEY` (Agent.hs:3749); `mkAgentConfirmation` (Agent.hs:3780-3785) calls `createReplyQueue` to create Bob's receive queue Q_B and returns `AgentConnInfoReply (Q_B :| []) bobInfo`; `mkConfirmation` ratchet-encrypts it and wraps `AgentConfirmation {e2eEncryption_ = Just bobSndParams, encConnInfo}`; `sendConfirmation` sends it to Q_A. This is confirmation #1.

Requester side, receiving confirmation #1 on Q_A:

- R4. dispatch (Agent.hs:3181-3183): state `(Nothing, Just e2ePubKey)`, `AgentConfirmation` -> `smpConfirmation`.
- R5. `smpConfirmation`, initiating-party branch `RcvConnection … Just e2eEncryption` (Agent.hs:3405-3444): `getRatchetX3dhKeys`, `pqX3dhRcv` (Agent.hs:3408), `initRcvRatchet` (Agent.hs:3411), `createRatchet` (Agent.hs:3436), `setRcvQueueConfirmedE2E` (Agent.hs:3440); decrypts `AgentConnInfoReply` (Agent.hs:3420); `processConf` emits `CONF` (Agent.hs:3444).
- R6. `allowConnection'` (Agent.hs:1467-1474): `acceptConfirmation`, then `ICAllowSecure` secures Q_A with Bob's sender key.
- R7. `connectReplyQueues` (Agent.hs:3724-3737): `upgradeConn` creates Alice's send queue to Q_B; `agentSecureSndQueue` secures Q_B; `enqueueConfirmation … Nothing` (Agent.hs:3733) stores `AgentConnInfo aliceInfo` and sends `AgentConfirmation {e2eEncryption_ = Nothing, encConnInfo}` to Q_B. This is confirmation #2.

Owner side, receiving confirmation #2 on Q_B:

- O7. dispatch (Agent.hs:3182): `AgentConfirmation` -> `smpConfirmation`.
- O8. `smpConfirmation`, accepting-party branch `DuplexConnection … Nothing` (Agent.hs:3447-3462): `agentRatchetDecrypt` with the established ratchet; `AgentConnInfo` -> `INFO` (Agent.hs:3452); `ICDuplexSecure` or `CON`.

`HELLO`/`CON` completion follows via `helloMsg` (Agent.hs:3466).

## Part 2 - the DR-from-address handshake, mapped to Part 1

The address advertises Bob's Rcv X3DH parameters in link data (Part 3). Alice, when the address advertises them and versions are compatible, takes the joiner role; Bob takes the initiator role.

Requester side - a new branch in `joinConnSrv … CRContactUri`, chosen when the fetched link data has `ratchetKeys`:

- R2'. Replaces R2/R3. Read the advertised `linkRatchetKey`, `ratchetKeyId`, `e2eVRange`, `prekey`, and optional `kemKey` from link data; reconstruct Bob's `RcvE2ERatchetParamsUri 'C.X448` and negotiate the concrete version with `compatibleVersion` against the client e2e range, as `compatibleInvitationUri` does (Agent.hs:1362-1368). Create the receive queue Q_A subscribed (`newRcvQueue` with `subMode`), messaging mode so Bob can secure it. Run `generateSndE2EParams` (with `replyKEM_` to accept the KEM only when advertised), `pqX3dhSnd` against the negotiated parameters, `initSndRatchet`, `createSndRatchet` - the body of `createRatchet_` (Agent.hs:1343-1350), with parameters from link data rather than a received invitation.
- R3'. Build `AgentConfirmation {e2eEncryption_ = Just aliceSndParams, ratchetKeyId = Just ratchetKeyId, encConnInfo = ratchetEncrypt(AgentConnInfoReply (Q_A :| []) aliceProfile)}` - the `mkAgentConfirmation`/`mkConfirmation` bodies (Agent.hs:3780-3765) with the reply queue being Alice's own Q_A. Send it to the address queue unauthenticated with `agentCbEncryptOnce`, as `sendInvitation` sends (Agent/Client.hs:1929-1934). **Alice's profile is now inside `encConnInfo`, under the ratchet.** Alice's connection is `RcvConnection` (Q_A) with a send ratchet, until she receives Q_B.

Owner side - a new dispatch branch and a new receive handler:

- O1'. In `processClientMsg` (Agent.hs:3176-3187), add a branch in state `(Nothing, Just e2ePubKey)`: an `AgentConfirmation` with `ratchetKeyId = Just _` on a `ContactConnection` -> `smpAddressConfirmation` (new). It must be placed **before** the existing `(PHEmpty, AgentConfirmation) | senderCanSecure queueMode` case (Agent.hs:3182-3184), because a contact-address queue is `QMContact` (not `senderCanSecure`) and would otherwise fall into `prohibited "handshake: missing sender key"` (Agent.hs:3184). The address queue's `e2eDhSecret` stays `Nothing` (it is never set for a contact address - `smpInvitation` does not set it, Agent.hs:3609-3622), so every request is decrypted with its own ephemeral key via this `(Nothing, Just e2ePubKey)` path.
- O2'. `smpAddressConfirmation` (new, modeled on `smpConfirmation` initiating branch, Agent.hs:3405-3444): select the private prekey and, if any, KEM keypair by `ratchetKeyId` from `address_ratchet_keys`; `pqX3dhRcv` with the `linkRatchetKey` private key, the selected prekey private key, and the optional KEM keypair (as `PrivateRKParamsProposed`) against `aliceSndParams`; `initRcvRatchet` (its `PQSupport` follows from whether the address advertises a KEM and version compatibility, as `smpConfirmation` derives `pqSupport'`, Agent.hs:3410); `rcDecrypt` of `encConnInfo` performs the first ratchet step, giving the connection its send side too (as it does for the initiator today), so the owner can later reply; `createRatchet` stores the post-decrypt ratchet under a **new connection created now** for this request. Parse `AgentConnInfoReply (Q_A :| []) aliceProfile`, store a pending-request record referencing the new connection, its ratchet, and Q_A (not a `connReq`), and emit `REQ`. An unknown or expired `ratchetKeyId`, or a decryption failure: discard and acknowledge, as an undecryptable message is dropped today. This establishes ratchet state on unauthenticated input before the user accepts - see "Receive-time establishment, state, and abuse".
- O3'. `acceptContact'` for a DR-established request - a new branch that continues the ratchet instead of `joinConn`: reuse `mkAgentConfirmation` (Agent.hs:3780-3785) to create Bob's receive queue Q_B and return `AgentConnInfoReply (Q_B :| []) bobInfo`; create Bob's send queue to Q_A (`newSndQueue`, generating Bob's own sender key) and secure Q_A with `SKEY` using that key (`agentSecureSndQueue`, valid because Q_A is messaging mode) - the securing key is Bob's own, not taken from Alice's message; send the response to Q_A as `AgentConfirmation {e2eEncryption_ = Nothing, ratchetKeyId = Nothing, encConnInfo = ratchetEncrypt(AgentConnInfoReply (Q_B :| []) bobInfo)}`, per-queue encrypted with `agentCbEncryptOnce` (first message to Q_A). The reply content is `AgentConnInfoReply`, not `AgentConnInfo`: it takes the `mkAgentConfirmation` path with `e2eEncryption_ = Nothing`, not the `enqueueConfirmation` path (which produces `AgentConnInfo`, Agent.hs:3789).

Requester side, receiving the response on Q_A:

- R5'. `smpConfirmation` needs a new branch `RcvConnection … Nothing` (today only `RcvConnection … Just` and `DuplexConnection … Nothing` exist, Agent.hs:3403-3447): Alice already holds the send ratchet, so `agentRatchetDecrypt` advances it and creates the receive side; `setRcvQueueConfirmedE2E` on Q_A so later messages use the stored per-queue secret (as the current branches do, Agent.hs:3440,3455); parse `AgentConnInfoReply (Q_B :| []) bobInfo`; connect Q_B (create Alice's send queue to Q_B, `agentSecureSndQueue` it, upgrade `RcvConnection` to `DuplexConnection`); emit `INFO`. The accepting-party branch (Agent.hs:3447) must also accept `AgentConnInfoReply`, not only `AgentConnInfo` (Agent.hs:3451, 3462), for the reply-queue case.
- R6'/completion. The response went to Q_A, so Bob has no signal that Alice secured Q_B and would never reach `CON` on its own. The essential extra message is Alice -> Q_B: after R5' Alice sends `HELLO` on Q_B, and `helloMsg` (Agent.hs:3466) sets Q_B active on Bob's side and emits Bob's `CON`. Alice reaches `CON` from the response (Q_A active, Q_B secured). Whether Bob also needs to send `HELLO` on Q_A for Alice's `CON`, or the response suffices, follows the existing `helloMsg`/fast-path completion and is confirmed at implementation - the fixed point is that Alice must send on Q_B.

Net code touch points: `joinConnSrv` (new requester branch), `processClientMsg` (new owner dispatch), `smpConfirmation` (new `RcvConnection … Nothing` branch and `AgentConnInfoReply` acceptance), `acceptContact'` (new continue-ratchet branch), a new `smpAddressConfirmation`, and the link data and storage of Part 3-4.

### Receive-time establishment, state, and abuse

This is the substantive departure from the current flow. Today `smpInvitation` creates only a lightweight `NewInvitation` and emits `REQ` (Agent.hs:3618-3621); no connection or ratchet exists until the user accepts. For DR the request is under the ratchet, so to show the requester's profile in `REQ` the owner must decrypt it, which means establishing the ratchet at **receive**, before accept.

Design decision (Q1): decrypt at receive. Both use cases need the request content at `REQ` - a person decides to accept from the profile, and a service bot needs the request payload to act. Deferring decryption to accept would make `REQ` contentless and does not fit the service case, so it is not done.

Consequences:

- A connection is created at receive to hold the ratchet (ratchets are keyed by `conn_id`). O2' creates a `NewConnection`, stores the post-decrypt ratchet under it, and a pending-request record with Q_A's address; O3' (accept) adds Bob's send queue to Q_A and receive queue Q_B, upgrading to `DuplexConnection`; reject deletes the connection, its ratchet, and the record.
- Per incoming `AgentConfirmation` the owner does one `pqX3dhRcv` (three DH plus, with PQ, one `sntrup761` decapsulation) and one `rcDecrypt`, on unauthenticated input, and creates a connection row and a ratchet row - more CPU and state than the current `NewInvitation`.

Abuse (Q2): a contact address already accepts and processes unauthenticated invitations today, so this is a degree-worse version of an existing surface, not a new class. It is bounded by the address queue quota (an attacker fills it, the owner drains and acknowledges) and, optionally, by basic auth on the address (already supported for contact addresses, `optBasicAuth`). The pending-request state is bounded by a request TTL: `cleanupManager` deletes pending DR connections never accepted or rejected past that TTL (Part 4 cleanup). Proof-of-work or a stricter gate can be added later; it is out of scope here and noted as a follow-up.

The `acceptContact'` dispatch branches on the pending record: a classic invitation (`connReq` present) takes the current `joinConn` path (O3-O6); a DR request (pending connection and ratchet present, no `connReq`) takes the continue-ratchet path (O3').

## Part 3 - types and link data

### Fixed data - link ratchet key

Appended to `FixedLinkData` (Protocol.hs:1824); the encoding already stops at a trailing tail (Protocol.hs:1928), so earlier versions ignore it:

```haskell
data FixedLinkData c = FixedLinkData
  { agentVRange :: VersionRangeSMPA,
    rootKey :: C.PublicKeyEd25519,
    linkConnReq :: ConnectionRequestUri c,
    linkEntityId :: Maybe ByteString,
    linkRatchetKey :: Maybe C.PublicKeyX448 -- stable X448 key, the first X3DH key
  }
```

### Mutable data - ratchet keys bundle

Appended to `UserContactData` (Protocol.hs:1840); the encoding stops at a trailing tail (Protocol.hs:1981), so earlier versions ignore it:

```haskell
data RatchetKeys = RatchetKeys
  { ratchetKeyId :: ByteString, -- identifies this bundle; changes on rotation
    e2eVRange :: VersionRangeE2E, -- advertised e2e version range, for negotiation
    prekey :: C.PublicKeyX448,
    kemKey :: Maybe KEMPublicKey -- opt-in, as PQ is opt-in in the ratchet (PQSupport)
  }

data UserContactData = UserContactData
  { direct :: Bool, owners :: [OwnerAuth], relays :: [ConnShortLink 'CMContact],
    userData :: UserLinkData,
    ratchetKeys :: Maybe RatchetKeys
  }
```

Reconstruction produces `RcvE2ERatchetParamsUri 'C.X448` (a version range, `E2ERatchetParamsUri VersionRangeE2E k1 k2 (Maybe kem)`), not concrete params: `e2eVRange` as the range, `linkRatchetKey` (from fixed data) as the first key, `prekey` as the second, `kemKey` as the optional KEM parameter. The requester negotiates the concrete version with `compatibleVersion` against its own e2e range, exactly as `compatibleInvitationUri` does for an invitation (Agent.hs:1362-1368), then uses the resulting `RcvE2ERatchetParams` in `pqX3dhSnd`. The KEM is optional: with `kemKey = Nothing` the ratchet is X448-only, as when `PQSupport` is off; with `Just` it is hybrid, matching `E2ERatchetParams … (Maybe (RKEMParams s))` (Ratchet.hs:220-221) and `generateRcvE2EParams`'s `PQSupport` gate (Ratchet.hs:439-445).

The owner does not use `generateRcvE2EParams` (which generates both keys together, Ratchet.hs:439): `linkRatchetKey` (k1) is generated once at address creation, the prekey (k2) and KEM per rotation. To advertise it derives the public keys with `mkRcvE2ERatchetParams` (Ratchet.hs:412), whose argument is `(PrivateKey a, PrivateKey a, Maybe RcvPrivRKEMParams)`, from the stored link ratchet private key, the current prekey private key, and the current KEM keypair; the published `e2eVRange` is stored alongside, so the version in `mkRcvE2ERatchetParams` is only a carrier for the public keys. `ratchetKeys` and `linkRatchetKey` are set by the agent when it signs link data (`Crypto.ShortLink.encodeSignFixedData`/`encodeSignUserData`), not by the application.

### Authentication of the advertised keys

No signature is added on the keys: the link data already signs them. `decryptLinkData` (Crypto/ShortLink.hs:106-114) verifies `sig1` over fixed data and `sig2` over the mutable `UserContactData`, both by `rootKey`, and checks `linkKey = sha3_256(fixedData)`. So `linkRatchetKey` is hash-committed and root-signed, and `ratchetKeys` (prekey, KEM, `e2eVRange`) is root-signed as part of `UserContactData`. This is the X3DH anti-substitution property: an SMP server cannot substitute the prekey or KEM without forging the root signature or breaking the link hash. The signer is the root Ed25519 key, not `linkRatchetKey` (X448, which cannot sign) - the DH identity and the signing identity are separate keys, both anchored to the link hash. A malicious server can still serve an older but validly-signed mutable data (rollback to a retired prekey); this is bounded by the prekey retention window and by the ratchet advancing after the first message, and a signature does not prevent it. Inline ratchet params in a `CRInvitationUri` contact request are not in signed link data and remain unsigned - a separate change, out of scope here.

### Request envelope

`AgentConfirmation` (Protocol.hs:830-834) gains an optional `ratchetKeyId` - the `ratchetKeyId` of the `RatchetKeys` bundle the requester used, so the owner selects the matching private keys:

```haskell
AgentConfirmation
  { agentVersion :: VersionSMPA,
    e2eEncryption_ :: Maybe (SndE2ERatchetParams 'C.X448),
    ratchetKeyId :: Maybe ByteString,
    encConnInfo :: ByteString
  }
```

Encoding (extends Protocol.hs:853-866): from `addressDRVersion`, `smpEncode (agentVersion, 'C', e2eEncryption_, ratchetKeyId, Tail encConnInfo)`, where `ratchetKeyId` is `Just` for an address-DR confirmation and `Nothing` for the current joiner-to-initiator and initiator-to-joiner confirmations; earlier versions omit the field entirely and use `smpEncode (agentVersion, 'C', e2eEncryption_, Tail encConnInfo)`. Parsing gates the field on `agentVersion`. `CRInvitationUri` is unchanged - a connection request URI holds Rcv parameters and must not hold Snd parameters.

## Part 4 - key rotation (separate concern)

Rotation is required but independent of the handshake above. The link ratchet key is stable; the prekey and KEM pair rotate on a schedule.

### Schema

```sql
-- private stable link ratchet key on the contact address receive queue
ALTER TABLE rcv_queues ADD COLUMN link_ratchet_priv_key BLOB; -- X448

-- one row per ratchet-keys generation for an address; current plus retired-within-window
CREATE TABLE address_ratchet_keys(
  address_ratchet_key_id INTEGER PRIMARY KEY AUTOINCREMENT,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  ratchet_key_id BLOB NOT NULL,            -- the published id echoed by requests
  prekey_priv_key BLOB NOT NULL,           -- X448 private key (public derivable with publicKey)
  kem_keypair BLOB,                        -- sntrup761 keypair (public + secret): the ratchet keeps the KEM keypair, and the retired public is not otherwise retained after LSET; NULL when PQ is off for this address
  created_at TEXT NOT NULL,
  retired_at TEXT                          -- set on rotation
);
CREATE UNIQUE INDEX idx_address_ratchet_keys ON address_ratchet_keys(conn_id, ratchet_key_id);
```

PostgreSQL mirrors this. Migration `M20260712_address_dr`.

### Rotation logic

`rotateRatchetKeys` (new), scheduled while the address is subscribed:

1. Generate an X448 prekey pair, and an sntrup761 pair only if PQ is on for this address, with a fresh `ratchetKeyId`.
2. Recompute mutable link data with the new `RatchetKeys`, re-sign with the root key (`encodeSignUserData`), and `LSET` it to the address queue (`addSMPQueueLink`/`setConnShortLink` path).
3. Insert the new `address_ratchet_keys` row; set `retired_at` on the previous row.

Retention window equals queue message retention (`storedMsgDataTTL`, Env/SQLite.hs:237), covering a request that used a just-retired prekey and is still in the address queue. Cadence is configuration; it bounds how long a recorded first message stays decryptable after a compromise of the current prekey - the link ratchet key alone decrypts nothing.

### Cleanup

`cleanupManager` (Agent.hs:2994) gains two steps: delete `address_ratchet_keys` rows with `retired_at` older than the window; and delete pending DR request connections (below) never accepted or rejected, past a request TTL. Both are batched like `deleteRcvMsgHashesExpired` (Agent.hs:3001).

## Part 5 - backward compatibility

- A requester older than `addressDRVersion`, or an address without `ratchetKeys`, uses R2/R3 (`AgentInvitation`); the owner uses O1-O8. Unchanged.
- The owner dispatches on the envelope: `AgentInvitation` -> `smpInvitation` (current); `AgentConfirmation` with `ratchetKeyId` on a `ContactConnection` -> `smpAddressConfirmation` (new). Both coexist.
- `AgentConfirmation` without `ratchetKeyId` remains the current confirmation on established connections.

## Part 6 - tests

- Encoding roundtrips: `FixedLinkData` with and without `linkRatchetKey`; `UserContactData` with and without `ratchetKeys`, and with `kemKey` present and absent; `AgentConfirmation` with and without `ratchetKeyId`, across versions.
- Address creation advertises `linkRatchetKey`, `prekey`, and optionally `kemKey`; `decryptLinkData` (Crypto/ShortLink.hs:100) verifies hash and signatures and reconstructs the advertised `RcvE2ERatchetParamsUri` (then negotiates to concrete) with and without the KEM.
- Both PQ modes: an address with `kemKey` gives a hybrid ratchet (`pqEncryption` on); an address without gives an X448-only ratchet.
- End to end: a DR-advertising address; a new requester establishes the ratchet, sends its profile under it, owner emits `REQ`, accepts, both reach `CON`; assert the profile never travels under per-queue-only encryption; assert `pqEncryption` on.
- Rotation: request against the current prekey; request against a just-retired prekey within the window still decrypts; request against a prekey past the window is discarded and the requester times out.
- Backward compatibility: old requester against a DR address connects via `AgentInvitation`; new requester against a non-DR address falls back to `AgentInvitation`.

## Part 7 - phases

1. Link data: `linkRatchetKey`, `RatchetKeys` (with optional `kemKey`), encodings, reconstruction, `encodeSignFixedData`/`encodeSignUserData`; address creation generating and storing the link ratchet private key and the first prekey row.
2. Handshake: requester R2'/R3', `AgentConfirmation.ratchetKeyId`, owner O1'/O2'/O3', `smpConfirmation` `RcvConnection … Nothing` branch and `AgentConnInfoReply` acceptance; end-to-end connection with the profile under the ratchet.
3. Rotation: schema migration, `rotateRatchetKeys`, retention window, cleanup step, rotation tests.
