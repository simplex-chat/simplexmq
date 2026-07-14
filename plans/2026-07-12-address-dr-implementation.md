# Establishing the double ratchet from address data - implementation plan

RFC: [../rfcs/2026-07-12-address-pqdr-keys.md](../rfcs/2026-07-12-address-pqdr-keys.md)

All references are to the current tree. Names of new constructors, fields, tables and functions are provisional.

Goal: a contact address advertises the owner's X3DH parameters in link data; a requester establishes the double ratchet in its first message, so that message and the profile in it are under the ratchet with post-quantum protection. The change reuses the invitation/confirmation machinery, with the requester in the joiner role and the owner in the initiator role - opposite to today's contact flow, but every message and code path below is reused.

Version: `addressDRVersion = VersionSMPA 8`, a plain agent-layer bump; `currentSMPAgentVersion` goes 7 → 8 (Agent/Protocol.hs:317-324). It gates the `AgentConfirmation.ratchetKeyId` field and the DR-from-address behavior. The receive-at-address path relies on ratchet-on-confirmation, already present since `ratchetOnConfSMPAgentVersion = 7` (Agent/Protocol.hs:317), so there is no cross-layer version dependency; the SMP and e2e-encryption versions are unchanged.

Scope of this change: the **synchronous** DR handshake in join, gated on the address advertising `ratchetKeys`. `joinConnection`/`joinConn`/`joinConnSrv` gain an optional `Maybe AddressRatchetKeys` (the advertised `RcvE2ERatchetParamsUri` + `ratchetKeyId`), passed in from the link data the caller fetched at plan time (`LGET`); present → DR path (R2'/R3'), absent → the classic `AgentInvitation`. Chat wires that argument later (a chat change); the agent supports it now and tests pass it directly. Making the send **async** (worker retry, a "connecting" UX, the `CreatedConnLink` LGET-gate) is **deferred** - kept below under "Deferred" as future work, not part of this change.

### Implementation status (as built; `lib:simplexmq` compiles)

**Done** (compiles): version bump; `RatchetKeyId`/`AddressRatchetKeys` types + `Encoding`, `UserContactData.ratchetKeys` (appended, backward-compatible); `AgentConfirmation.ratchetKeyId` (version-gated encode/decode); `ContactRequest`/`DRRequest` sum with tagged `Encoding` + `cr_invitation` `ToField`/`FromField` (legacy-URI fallback); `address_ratchet_keys` table + `createAddressRatchetKeys`/`getAddressRatchetKeys` (SQLite + Postgres migrations `M20260712_address_dr`); join threading (`Maybe AddressRatchetKeys`); requester R2'/R3' (`joinAddressDR` + `sendConfirmationToAddress`); owner O1' dispatch, O2' `smpAddressConfirmation`, O3' (`acceptContact'` continue-ratchet branch), all three `connReq` readers (`acceptContact'`, `acceptContactAsync'` → `CMD PROHIBITED` for DR, `newConnToAccept` → shell from `drAgentVersion`/`drPQSupport`); requester R5' (`smpConfirmation` `RcvConnection … Nothing` branch, guarded on a ratchet existing); address-creation bundle generation (`mkAddressRatchetKeys`) wired into `createConnectionForLink'` (`IKUsePQ`-for-`SCMContact` prohibition lifted there).

**Deltas from the plan discovered while building:**
- **R5' emits `CONF` and reuses the allow step** (not auto-complete). The DR requester is a `RcvConnection` receiving the owner's reply - the same position as the classic contact requester, which goes `CONF` → `allowConnection'` → `connectReplyQueues` (msg 3). R5' mirrors that (differing only in that the ratchet already exists, so it `getRatchet` + `rcDecrypt` instead of building it), so the app supplies `ownConnInfo` for msg 3 at allow, exactly as today. No new storage.
- **`DRRequest` carries `drAgentVersion` + `drPQSupport`** (Part 3): the sync accept creates the connection shell via `newConnToAccept`→`newConnToJoin` before O3', and there is no URI to derive the version/PQ from.
- `RatchetX448` is JSON-serialized, so `DRRequest`'s `Encoding` embeds it as a `Large` JSON blob; `PQSupport` (no `Encoding`) is stored via its `Bool`.
- **DR is opt-in per address**: `createConnectionForLink'`/`createConnectionForLink` gain a `Maybe InitialKeys` DR parameter (separate from the existing connection-PQ `InitialKeys`) - `Nothing` = no DR (old behavior, existing callers), `Just ik` = advertise the bundle with `ik`. The `IKUsePQ`-for-`SCMContact` prohibition stays on the connection-PQ parameter and is lifted only for the DR bundle.

**Not yet done:** rotation (`rotateRatchetKeys`, Part 4), cleanup step (Part 4), the app-driven `LSET` upgrade API (Part 5), wiring the DR parameter into the non-prepared-link `newRcvConnSrv` path, tests (Part 6), regenerating `agent_schema.sql` if a schema-consistency test requires it, and chat wiring (deferred by design).

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

Completion is direct `CON` on `senderCanSecure` (SKEY) messaging-mode queues (the sender on `AgentConnInfo`, Agent.hs:2252; the receiver with no `senderKey`, Agent.hs:3459-3461); the separate `HELLO` via `helloMsg` (Agent.hs:3466) is the older non-`senderCanSecure` (duplexHandshake v2, in-band-securing) path.

## Part 2 - the DR-from-address handshake, mapped to Part 1

The address advertises Bob's Rcv X3DH parameters in link data (Part 3). Alice, when the address advertises them and versions are compatible, takes the joiner role; Bob takes the initiator role.

Requester side - a new branch in `joinConnSrv … CRContactUri`, taken when the passed `Maybe AddressRatchetKeys` is present (the caller's plan-time `LGET`):

- R2'. Replaces R2/R3. Read the passed bundle - `ratchetKeyId` and `e2eParams :: RcvE2ERatchetParamsUri 'C.X448` - and negotiate the concrete version with `compatibleVersion` against the client e2e range, as `compatibleInvitationUri` does (Agent.hs:1362-1368). Create the receive queue Q_A subscribed (`newRcvQueue` with `subMode`), messaging mode so Bob can secure it. Choose the requester's KEM with `replyKEM_ v ownerKem_ pqSup` (Ratchet.hs:839): if the bundle advertises a KEM (owner `IKUsePQ`) the requester `AcceptKEM` - a **double KEM**: it both encapsulates to the address KEM (ciphertext) and includes its own new KEM public key (`generateSndE2EParams` → `sntrup761Enc` + a fresh keypair, Ratchet.hs:433-435), so PQ is bidirectional from message 1; if the bundle has no KEM and the requester wants PQ, it `ProposeKEM` (its own key only, PQ from message 2 if the owner supports it). Run `generateSndE2EParams g v (replyKEM_ …)`, `pqX3dhSnd` against the negotiated parameters, `initSndRatchet`, `createSndRatchet` - the body of `createRatchet_` (Agent.hs:1343-1350), with parameters from the passed bundle rather than a received invitation.
- R3'. Build `AgentConfirmation {e2eEncryption_ = Just aliceSndParams, ratchetKeyId = Just ratchetKeyId, encConnInfo = ratchetEncrypt(AgentConnInfoReply (Q_A :| []) aliceProfile)}` - the `mkAgentConfirmation`/`mkConfirmation` bodies (Agent.hs:3780-3765) with the reply queue being Alice's own Q_A. Send it to the address queue unauthenticated with `agentCbEncryptOnce`, one-shot (as `sendInvitation` sends, Agent/Client.hs:1929-1934) - **synchronous**, with the same send-failure UX as today's classic contact join. Nothing is stored: a retry (chat re-invokes the join → `mkJoinInvitation` reuses Q_A + keys, 1418) re-builds the confirmation, advancing the send ratchet, and the owner absorbs the advance - a **failed send** is skipped when the owner establishes the ratchet (`maxSkip = 512`, Ratchet.hs:988), and a **lost reply** carries the current content and updates the owner's request by `XContactId` (ContactRequest.hs:99-101, 269); both testable. The requester does **not** SKEY the address (`QMContact`, not `senderCanSecure`); rotation is handled because the passed params are the current advertised keys. **Alice's profile is now inside `encConnInfo`, under the ratchet.** Alice's connection is `RcvConnection` (Q_A) with a send ratchet, until she receives Q_B. This "New `RcvConnection` + `ratchets` row" is a new state (today a New `RcvConnection` holds x3dh keys but no ratchet - the classic initiator builds the ratchet only at R5, `createRatchet` Agent.hs:3436), and it composes: connection type is derived from queue rows alone while the `ratchets` table is keyed independently by `conn_id`, so subscription (Agent.hs:1551), `connectionStats` (2658), and `allowConnectionAsync'` (888) never read the ratchet for a `RcvConnection`; the only handshake reader on it is `smpConfirmation` (R5').

### Deferred (future work): async delivery + connect UX

The synchronous send above fails in the user's face on a lost reply (the same wart as today's classic contact join), even though the request may have been delivered. Making it async is a separate, later change, not part of this DR work:

- Delivery cannot use the message-delivery worker: a `SndQueue` is unique per `(host, port, snd_id)` and belongs to one connection (schema PK), while a contact address is one queue that many connections send to, so no per-connection SndQueue to it can exist. It would go through the **async command worker**, keyed by `(connId, server)` (`getAsyncCmdWorker`, Agent.hs:1856-1858), which already retries the `JOIN` command (`tryMoveableCommand` → `retrySndOp`, 2016-2024); each retry re-runs `joinConnSrv` (re-build + ratchet advance, which the owner absorbs - above), so nothing is stored. (`joinConnSrvAsync` for `CRContactUri` is `CMD PROHIBITED` today, Agent.hs:1452, and the `JOIN` handler falls back to sync `joinConnSrv`, 1899-1902; the `TBC` at Agent.hs:1897 is about async *receive*-queue creation - Q_A - and is orthogonal.)
- The async join returns "connecting" early and completes via the events chat already handles (`joinContact` sets `ConnJoined`; the DR requester emits `CONF` in R5' and the chat allows it, exactly as the classic contact requester, driving msg 3 → `CON`; a permanent send failure still surfaces as `ERR → ConnFailed`).
- This needs a chat change: the join API takes a `CreatedConnLink` (full + short link), not the bare `ConnectionRequestUri` it takes today, so the agent can LGET-gate on the owner's server (a real reachability check) and verify the fetched `linkConnReq` equals the passed full link before reporting success. Used only for DR addresses (link data advertises `ratchetKeys`); old / non-DR addresses stay on the current sync path.

Owner side - a new dispatch branch and a new receive handler:

- O1'. In `processClientMsg` (Agent.hs:3176-3187), add a branch in state `(Nothing, Just e2ePubKey)`: an `AgentConfirmation` with `ratchetKeyId = Just _` **and** `e2eEncryption_ = Just _` on a `ContactConnection` -> `smpAddressConfirmation` (new). A `ratchetKeyId` without `e2eEncryption_` is ignored (it does not match this branch and falls through as a non-DR confirmation). It must be placed **before** the existing `(PHEmpty, AgentConfirmation) | senderCanSecure queueMode` case (Agent.hs:3182-3184), because a contact-address queue is `QMContact` (not `senderCanSecure`) and would otherwise fall into `prohibited "handshake: missing sender key"` (Agent.hs:3184). The address queue's `e2eDhSecret` stays `Nothing` (it is never set for a contact address - `smpInvitation` does not set it, Agent.hs:3609-3622), so every request is decrypted with its own ephemeral key via this `(Nothing, Just e2ePubKey)` path.
- O2'. `smpAddressConfirmation` (new, modeled on `smpConfirmation` initiating branch, Agent.hs:3405-3444): select the private triple `(pk1, pk2, pKem)` by `ratchetKeyId` from `address_ratchet_keys`; `pqX3dhRcv pk1 pk2 pKem aliceSndParams`; `initRcvRatchet` with the address connection's stored `PQSupport` (`connPQEncryption` of the address `InitialKeys` - `On` for `IKUsePQ` and `IKPQOn`, `Off` for `IKPQOff`; this is what lets `IKPQOn` accept the requester's proposed KEM), combined with version compatibility as `smpConfirmation` derives `pqSupport'` (Agent.hs:3410); `rcDecrypt` of `encConnInfo` performs the first ratchet step, giving the ratchet its send side too (as it does for the initiator today), so the owner can later reply. Parse `AgentConnInfoReply (Q_A :| []) aliceProfile`. Store the request with `createInvitation` on the address connection (`contact_conn_id`), exactly as a classic invitation - except the request value is the `CRConfirmation` variant (Part 3) carrying the post-decrypt ratchet state and Q_A, and `recipient_conn_info` is `aliceProfile` - so **no connection or `ratchets` row is created at receive**, as with a classic invitation. Emit `REQ` with the `invitation_id`. A resend is not deduplicated: like a resent classic invitation it produces another `REQ` (the connect-UX fix for that is separate chat work). An unknown or expired `ratchetKeyId`, or a decryption failure: discard and acknowledge, as an undecryptable message is dropped today. This establishes ratchet state on unauthenticated input before the user accepts - see "Receive-time establishment, state, and abuse".
- O3'. `acceptContact'` for a DR request - a new branch that continues the ratchet instead of `joinConn`. `getInvitation` returns the request; its `CRConfirmation` variant gives the stored ratchet state and Q_A. Create the connection now (as `joinConn` does for a classic invitation) and `createRatchet` (AgentStore.hs:1419) from the stored ratchet state. Reuse `mkAgentConfirmation` (Agent.hs:3780-3785) to create Bob's receive queue Q_B and return `AgentConnInfoReply (Q_B :| []) bobInfo`; create Bob's send queue to Q_A (`newSndQueue`, generating Bob's own sender key) and secure Q_A with `SKEY` using that key (`agentSecureSndQueue`, valid because Q_A is messaging mode) - the securing key is Bob's own, not taken from Alice's message; send the response to Q_A as `AgentConfirmation {e2eEncryption_ = Nothing, ratchetKeyId = Nothing, encConnInfo = ratchetEncrypt(AgentConnInfoReply (Q_B :| []) bobInfo)}` via `sendConfirmation` (`agentCbEncrypt` over Bob's send queue to Q_A, `PHEmpty` because Q_A is `senderCanSecure`) - exactly the current contact msg 2 path (Client.hs:1916), not `agentCbEncryptOnce`. The reply content is `AgentConnInfoReply`, not `AgentConnInfo`: it takes the `mkAgentConfirmation` path with `e2eEncryption_ = Nothing`, not the `enqueueConfirmation` path (which produces `AgentConnInfo`, Agent.hs:3789). `rejectContact'` deletes the `conn_invitations` row (the current behaviour), discarding the inline ratchet; no connection was created, so there is nothing else to clean up.

Requester side, receiving the response on Q_A:

- R5'. `smpConfirmation` needs a new branch `RcvConnection … Nothing` (today only `RcvConnection … Just` and `DuplexConnection … Nothing` exist, Agent.hs:3403-3447). It looks up the ratchet first (`getRatchet`) and, if there is none, falls through to `prohibited "conf: incorrect state"` - so a classic initiator (a New `RcvConnection` with x3dh keys but no ratchet) that receives a stray `Nothing`-confirmation keeps today's exact outcome; only a DR requester, which holds a send ratchet, takes the new path. Alice already holds the send ratchet, so `rcDecrypt` advances it and creates the receive side; parse `AgentConnInfoReply (Q_B :| []) bobInfo`. **This mirrors the classic contact requester exactly**: `setRcvQueueConfirmedE2E` on Q_A, `createRatchet` the advanced ratchet, store the reply as a `NewConfirmation`, and emit **`CONF`** - the app then calls `allowConnection'` (supplying `ownConnInfo` for msg 3), which drives `connectReplyQueues` (create Alice's send queue to Q_B, `SKEY`, upgrade to `DuplexConnection`, `enqueueConfirmation` the `AgentConnInfo` msg 3). Because Q_B is sender-securable, sending `AgentConnInfo` completes Alice with `CON` (Agent.hs:2252) - no `HELLO`. The only difference from the classic requester is that the ratchet is pre-built (from R2') rather than built from Bob's Snd params here, so there is no `CONF`-less auto-completion and no separate storage of Alice's own info.
- R6'/completion. Unchanged from the current contact handshake, and modern (no `HELLO`). The exchange is three agent↔agent wire messages - Alice → address queue (msg 1), Bob → Q_A (msg 2, an `AgentConfirmation` carrying `AgentConnInfoReply` with Q_B), Alice → Q_B (msg 3, an `AgentConfirmation` carrying `AgentConnInfo`) - the same shape as the current contact flow, where msg 1 was `AgentInvitation`; here it is the ratchet-establishing `AgentConfirmation`. (`CON` is not a wire message - it is the agent→app event; `HELLO` and `AgentConnInfo` are the wire messages.) `HELLO` belongs to the older non-`senderCanSecure` path (duplexHandshake v2, before SKEY): there the confirmation secures the queue in-band (`PHConfirmation` carries the sender key, Client.hs:1918) and the receiver replies with `HELLO` (`ICDuplexSecure` → `enqueueDuplexHello`, Agent.hs:3457-3458). Both Q_A and Q_B here are messaging-mode - Q_A by R2', Q_B via `createReplyQueue` → `SCMInvitation` → `QMMessaging` (Agent.hs:1233,1458,3783) - so the sender secures with SKEY and sends `PHEmpty` (Client.hs:1918), the dispatch takes the `senderCanSecure` branch (Agent.hs:3182-3184), and each agent raises the `CON` app event locally off msg 3 - Bob on receiving it (`senderKey = Nothing`, Agent.hs:3459-3461), Alice on sending it (Agent.hs:2252) - with no separate `HELLO` wire message. (msg 2's `AgentConnInfoReply` only sets Q_A `Confirmed`, Agent.hs:2254.) Invitations are two messages because the initiator's queue is already in the link; a contact address needs three because Bob's receive queue Q_B is only delivered in msg 2. The third message no longer has a ratchet role: Bob's X3DH params are pre-published, so the agreement is complete once Bob receives msg 1 (in the current flow Bob's Snd params instead arrive in msg 2). msg 2 and msg 3 are queue setup - msg 2 delivers Q_B, msg 3 secures Q_B so Alice can send to Bob and signals Bob's `CON`; neither negotiates the ratchet. A one-directional exchange (the RPC) needs no Q_B and is two messages.

Net code touch points: `joinConnSrv` (new requester branch), `processClientMsg` (new owner dispatch), `smpConfirmation` (new `RcvConnection … Nothing` branch and `AgentConnInfoReply` acceptance), `acceptContact'` (new continue-ratchet branch), a new `smpAddressConfirmation` reusing `createInvitation`/`getInvitation` with the sum request value, and the link data and storage of Part 3-4. `rejectContact'` is unchanged (it deletes the `conn_invitations` row either way).

### Receive-time establishment, state, and abuse

This is the substantive departure from the current flow. Today `smpInvitation` creates only a lightweight `NewInvitation` and emits `REQ` (Agent.hs:3618-3621); no connection or ratchet exists until the user accepts. For DR the request is under the ratchet, so to show the requester's profile in `REQ` the owner must decrypt it, which means establishing the ratchet at **receive**, before accept.

Design decision (Q1): decrypt at receive. Both use cases need the request content at `REQ` - a person decides to accept from the profile, and a service bot needs the request payload to act. Deferring decryption to accept would make `REQ` contentless and does not fit the service case, so it is not done.

Consequences:

- No connection is created at receive, exactly as for a classic invitation. O2' stores the request with `createInvitation` on the address connection; the post-decrypt ratchet state and Q_A live inline in the `CRConfirmation` request value (`cr_invitation`). O3' (accept) creates the connection, `createRatchet` from the stored state, and adds Bob's queues, becoming a `DuplexConnection`; `rejectContact'` deletes the `conn_invitations` row.
- Per incoming `AgentConfirmation` the owner does one `pqX3dhRcv` (three DH plus, with PQ, one `sntrup761` decapsulation) and one `rcDecrypt`, on unauthenticated input, and writes one `conn_invitations` row - more CPU than the current `NewInvitation`, the same order of state (no connection, no `ratchets` row until accept).

Abuse (Q2): a contact address already accepts and processes unauthenticated invitations today, so this is a degree-worse version of an existing surface, not a new class. It is bounded by the address queue quota (an attacker fills it, the owner drains and acknowledges) and, optionally, by basic auth on the address (already supported for contact addresses, `optBasicAuth`). The per-request state is a single `conn_invitations` row - the same class as a classic contact request - so it is subject to the same limits and lifecycle, with no DR-specific dedup or TTL. Proof-of-work or a stricter gate can be added later; it is out of scope here and noted as a follow-up.

`acceptContact'`/`rejectContact'` keep taking the `invitation_id` from `REQ` unchanged; the only difference is that `getInvitation` returns a request that is either a `CRInvitation` URI (current `joinConn` path, O3-O6) or a `CRConfirmation` (continue-ratchet path, O3'). Nothing in the `REQ`/accept/reject flow or the chat client changes - the change is contained in the agent.

### The four communication layers, per message (verified against code)

Layers, outermost (server-visible) first:

- **L1 `ClientMsgEnvelope`** (Protocol.hs:1089), `PubHeader {phVersion, phE2ePubDhKey :: Maybe PublicKeyX25519}` (1096) - **this is where per-queue encryption is agreed** (not L2). `phE2ePubDhKey` is the sender's e2e DH public key; the recipient combines it with the queue's e2e private key: `(e2eDhSecret, e2ePubKey_) -> (Nothing, Just e2ePubKey) -> e2eDh = dh' e2ePubKey e2ePrivKey` (Agent.hs:3172-3178). `agentCbEncryptOnce` (Client.hs:2214) puts a **fresh ephemeral** pubkey (generated 2217, set 2223) - used when the sender has no send queue (the address queue), whose `e2eDhSecret` stays `Nothing`, so it decrypts every message with the per-message ephemeral. `agentCbEncrypt` (Client.hs:2203) puts the **send queue's persistent** e2e pubkey (`Just` on a confirmation, 2210); the recipient stores the secret via `setRcvQueueConfirmedE2E`, and *later* messages send `phE2ePubDhKey = Nothing` (`sendAgentMessage`, 2080).
- **L2 `ClientMessage PrivHeader`** (Protocol.hs:1113), `PrivHeader = PHConfirmation APublicAuthKey | PHEmpty` (1115) - **queue securing / authorization, not encryption**. `PHConfirmation` carries the sender's AUTH key for in-band securing (v2, non-`senderCanSecure`); `PHEmpty` when the sender secured the queue with SKEY out-of-band. `PHEmpty` on every message here is about securing, and says nothing about encryption (that is L1). Set in `sendConfirmation` (Client.hs:1918), `sendInvitation` (1934), `sendAgentMessage` (2079).
- **L3 `AgentMsgEnvelope`** (Agent/Protocol.hs:829, encoding 851) - outside the ratchet. `AgentConfirmation` ('C') carries `e2eEncryption_` (Snd X3DH params, agrees DR) + `encConnInfo`; `AgentInvitation` ('I') carries `connReq` (Rcv X3DH params) + plaintext `connInfo` (no DR); `AgentMsgEnvelope` ('M') carries `encAgentMessage`.
- **L4 `AgentMessage`** (Agent/Protocol.hs:883, encoding 893) - inside the ratchet. `AgentConnInfo` ('I'), `AgentConnInfoReply` ('D', reply queues + info), `AgentMessage APrivHeader AMessage` ('M'; `AMessage` includes `HELLO`, Agent/Protocol.hs:1018-1020). **Absent when L3 is `AgentInvitation`** (that profile is per-queue-only - the gap this plan closes).

Send routing: msg 1 (to address) → `sendInvitation` today / a new `agentCbEncryptOnce` confirmation send for DR; msg 2 → `secureConfirmQueue` → `sendConfirmation` (Agent.hs:3747); msg 3 → `connectReplyQueues` → `enqueueConfirmation` → delivery worker `AM_CONN_INFO` → `sendConfirmation` (Agent.hs:3733,3789,2183). `AM_CONN_INFO`/`AM_CONN_INFO_REPLY` both go through `sendConfirmation` (2183-2184); other `AMessage`s go through `sendAgentMessage` wrapping `AgentMsgEnvelope` 'M' (2192-2193).

Current contact handshake (address does **not** advertise DR):

| msg | L1 `PubHeader.phE2ePubDhKey` (per-queue enc) | L2 `PrivHeader` (securing) | L3 `AgentMsgEnvelope` | L4 `AgentMessage` |
|---|---|---|---|---|
| 1 Alice→addr | `Just` fresh ephemeral, `agentCbEncryptOnce` (Client.hs:1933,2223) | `PHEmpty` (1934) | `AgentInvitation` {connReq = Alice Rcv params, connInfo = profile} (Client.hs:1932) | — none (profile per-queue only) |
| 2 Bob→Q_A | `Just` Bob's send-queue e2e pubkey, `agentCbEncrypt` (1920,2210) | `PHEmpty` [`senderCanSecure`] (1918) | `AgentConfirmation` {e2eEncryption_ = **Just Bob Snd params**, encConnInfo} (Agent.hs:3765) | `AgentConnInfoReply` (Q_B) bobInfo, DR-enc (Agent.hs:3785) |
| 3 Alice→Q_B | `Just` Alice's send-queue e2e pubkey, `agentCbEncrypt` (1920,2210) | `PHEmpty` [`senderCanSecure`] (1918) | `AgentConfirmation` {e2eEncryption_ = **Nothing**, encConnInfo} (Agent.hs:3802) | `AgentConnInfo` aliceInfo, DR-enc (Agent.hs:3789) |

New DR handshake (address advertises DR):

| msg | L1 `PubHeader.phE2ePubDhKey` (per-queue enc) | L2 `PrivHeader` (securing) | L3 `AgentMsgEnvelope` | L4 `AgentMessage` |
|---|---|---|---|---|
| 1 Alice→addr | `Just` fresh ephemeral, `agentCbEncryptOnce` [same] | `PHEmpty` [same] | **`AgentConfirmation`** {e2eEncryption_ = **Just Alice Snd params**, **ratchetKeyId = Just**, encConnInfo} [was `AgentInvitation`] | **`AgentConnInfoReply`** (Q_A) aliceProfile, **DR-enc** [was plaintext connInfo] |
| 2 Bob→Q_A | `Just` Bob's send-queue e2e pubkey, `agentCbEncrypt` [same] | `PHEmpty` [same] | `AgentConfirmation` {e2eEncryption_ = **Nothing**, ratchetKeyId = Nothing, encConnInfo} [was Just Bob Snd params] | `AgentConnInfoReply` (Q_B) bobInfo, DR-enc [same] |
| 3 Alice→Q_B | `Just` Alice's send-queue e2e pubkey, `agentCbEncrypt` [same] | `PHEmpty` [same] | `AgentConfirmation` {e2eEncryption_ = Nothing, encConnInfo} [same] | `AgentConnInfo` aliceInfo, DR-enc [same] |

Net difference: **only msg 1 and msg 2's L3/L4 change.** msg 1's L3 becomes `AgentConfirmation` (was `AgentInvitation`) carrying Alice's Snd params + `ratchetKeyId`, and the profile moves from plaintext L3 to DR-encrypted L4 (`AgentConnInfoReply`) - the whole point of the change. msg 2 drops `e2eEncryption_` (Bob no longer sends Snd params - the ratchet is agreed from msg 1). msg 3 is unchanged. L1 (per-queue encryption - each queue agrees its own secret via the sender's e2e pubkey in the `PubHeader` on the first message to it) and L2 (securing, `PHEmpty` because SKEY is used) are unchanged throughout; the DR change is entirely at L3/L4. The only new send code is msg 1 (an `AgentConfirmation` fired to the address with `agentCbEncryptOnce`, like `sendInvitation` but with a confirmation envelope).

## Part 3 - types and link data

### Fixed data - unchanged

`FixedLinkData` (Protocol.hs:1824) is not touched. The double-ratchet keys go entirely in mutable data, so an existing address advertises them without a new link (the fixed data is hash-committed and cannot change). Fixed data keeps only `agentVRange`, `rootKey`, `linkConnReq`, `linkEntityId`.

### Mutable data - ratchet keys bundle

Appended to `UserContactData` (Protocol.hs:1840); the encoding stops at a trailing tail (Protocol.hs:1981), so earlier versions ignore it:

```haskell
newtype RatchetKeyId = RatchetKeyId ByteString -- opaque short id; one Encoding instance, shared below

data AddressRatchetKeys = AddressRatchetKeys
  { ratchetKeyId :: RatchetKeyId, -- identifies this bundle; changes on rotation, echoed in the request
    e2eParams :: CR.RcvE2ERatchetParamsUri 'C.X448 -- version range + both X3DH keys + optional KEM
  }
instance Encoding AddressRatchetKeys where ... -- the key-bundle instance; both fields required

data UserContactData = UserContactData
  { direct :: Bool, owners :: [OwnerAuth], relays :: [ConnShortLink 'CMContact],
    userData :: UserLinkData,
    ratchetKeys :: Maybe AddressRatchetKeys -- whole bundle optional, one Encoding instance
  }
```

`e2eParams` is the existing `RcvE2ERatchetParamsUri 'C.X448` (`E2ERatchetParamsUri VersionRangeE2E k1 k2 (Maybe (RKEMParams s))`, Ratchet.hs:282-286) - the same type a `CRInvitationUri` advertises - with `StrEncoding`/`Encoding` already defined (Ratchet.hs:302-374). There is no bespoke key type and no reconstruction: the requester negotiates the concrete version with `compatibleVersion` against its own e2e range, exactly as `compatibleInvitationUri` does for an invitation (Agent.hs:1362-1368), giving `RcvE2ERatchetParams` for `pqX3dhSnd`. The KEM is optional: `Nothing` gives an X448-only ratchet (as when `PQSupport` is off), `Just` a hybrid one, matching `generateRcvE2EParams`'s `PQSupport` gate (Ratchet.hs:439-445).

The address-creation parameter is `InitialKeys` (Ratchet.hs:864) - the same 3-way choice as invitations, not a bare `PQSupport`. Currently `IKUsePQ` is prohibited for `SCMContact` (Agent.hs:990,1198) because a contact address carries no owner keys; this change lifts that prohibition. The bundle plays the published-contact-request role, so its KEM follows `initialPQEncryption False pqInitKeys` (Ratchet.hs:882) - exactly as the requester's contact request does today (Agent.hs:1422):

- `IKUsePQ` - the bundle advertises the KEM; the requester encapsulates to it, so PQ from message 1.
- `IKPQOn` (`IKLinkPQ PQSupportOn`) - the bundle is X448-only (no KEM advertised), but the owner's ratchet supports PQ (`connPQEncryption` = On, Ratchet.hs:888); the requester proposes its own KEM (R2'), so PQ from message 2.
- `IKPQOff` (`IKLinkPQ PQSupportOff`) - X448-only, and the owner's ratchet does not support PQ even if the requester proposes it.

Advertising the KEM adds ~1158 B to the rotated, widely-fetched link data, which is why `IKPQOn` exists (PQ one round later, without the size cost). The owner generates the bundle with `generateRcvE2EParams g v (initialPQEncryption False pqInitKeys)` (Ratchet.hs:439), stores the private triple `(pk1, pk2, pKem)` (Part 4), and advertises `e2eParams` by wrapping the public `E2ERatchetParams` in the address's e2e version range (`toVersionRangeT`; or `mkRcvE2ERatchetParams` from the stored privates, Ratchet.hs:412) - the same private-key shape `createRatchetX3dhKeys`/`getRatchetX3dhKeys` already store (AgentStore.hs:1362-1367). `ratchetKeys` is set by the agent when it signs mutable link data (`Crypto.ShortLink.encodeSignUserData`), not by the application.

### Authentication of the advertised keys

No signature is added on the keys: the mutable link data already signs them. `decryptLinkData` (Crypto/ShortLink.hs:106-114) verifies `sig2` over the mutable `UserContactData` by `rootKey`, so `ratchetKeys` is root-signed. This is the X3DH anti-substitution property: an SMP server cannot substitute the keys without forging the root signature. The signer is the root Ed25519 key (the address's signing identity); the X3DH keys are separate DH keys (X448, which cannot sign). A single owner signs address data ("we don't use multiple owners"), so the root signature alone is sufficient - no per-key signature. A malicious server can still serve an older but validly-signed `UserContactData` (rollback to a retired bundle); this is bounded by the retention window and by the ratchet advancing after the first message, and a signature does not prevent it. Inline ratchet params in a `CRInvitationUri` contact request are not in signed link data and remain unsigned - a separate change, out of scope here.

### Request envelope

`AgentConfirmation` (Protocol.hs:830-834) gains an optional `ratchetKeyId` - the `ratchetKeyId` of the `AddressRatchetKeys` bundle the requester used, so the owner selects the matching private keys:

```haskell
AgentConfirmation
  { agentVersion :: VersionSMPA,
    e2eEncryption_ :: Maybe (SndE2ERatchetParams 'C.X448), -- reused: Alice's Snd params in DR msg 1
    ratchetKeyId :: Maybe RatchetKeyId,                    -- selects the owner's key generation
    encConnInfo :: ByteString
  }
```

`ratchetKeyId` is a separate optional selector (the shared `RatchetKeyId` newtype), not the bundle - the owner already holds the published public bundle and looks up its private keys by this id. It reuses the existing `e2eEncryption_` for Alice's Snd params rather than a new combined bundle; the minor cost is two correlated `Maybe`s (`ratchetKeyId = Just` is only meaningful with `e2eEncryption_ = Just`). **A `ratchetKeyId` with `e2eEncryption_ = Nothing` is ignored** - O2' requires both (there are no Snd params to run `pqX3dhRcv`), so such a message falls through to the current dispatch as if it had no `ratchetKeyId`.

Encoding (extends Protocol.hs:853-866): from `addressDRVersion`, `smpEncode (agentVersion, 'C', e2eEncryption_, ratchetKeyId, Tail encConnInfo)`; `ratchetKeyId` is `Just` for an address-DR confirmation and `Nothing` for the current joiner-to-initiator and initiator-to-joiner confirmations; earlier versions omit the field entirely and use `smpEncode (agentVersion, 'C', e2eEncryption_, Tail encConnInfo)`. Parsing gates the field on `agentVersion`. `CRInvitationUri` is unchanged - a connection request URI holds Rcv parameters and must not hold Snd parameters.

### Stored request - the invitation record

The `conn_invitations` record stays; only the type of the stored request widens. From chat's point of view a DR request is still an invitation - it "contains a confirmation" instead of an invitation URI - so `REQ`, `acceptContact'`/`rejectContact'`, and the chat side are unchanged; the change is contained in the agent. The `NewInvitation`/`Invitation` request field (`cr_invitation`, stays `NOT NULL`) becomes a sum:

```haskell
data ContactRequest
  = CRInvitation (ConnectionRequestUri 'CMInvitation) -- classic: joinConn on accept (O3-O6)
  | CRConfirmation DRRequest                          -- DR: continue the ratchet on accept (O3')

data DRRequest = DRRequest
  { drRatchet :: RatchetX448,        -- post-decrypt receiving ratchet (with send side), stored inline
    drReplyQueue :: SMPQueueInfo,    -- Q_A, where the owner replies
    drAgentVersion :: VersionSMPA,   -- negotiated at receive; needed to build the connection shell at accept
    drPQSupport :: PQSupport         -- the address's PQ setting for this connection
  }
```

`recipient_conn_info` holds the profile in both cases. `getInvitation`/`createInvitation` carry `ContactRequest`; `acceptContact'` branches on the constructor. There is no dedup column: a resent request produces another `REQ`, exactly as a resent classic invitation does.

`drAgentVersion`/`drPQSupport` are stored because the accept flow creates the connection **shell** through `newConnToAccept` → `newConnToJoin` (via `prepareConnectionToAccept`, called by chat's sync accept before `acceptContact'`, Internal.hs:914,925) and `newConnToJoin` today derives `connAgentVersion`/`pqSupport` from the `ConnectionRequestUri` (Agent.hs:1277-1293); a `CRConfirmation` has no URI, so the values negotiated at receive (O2') are stored and used to build the shell.

Three readers of the widened `connReq` field (all via `getInvitation`) branch on the constructor:
- `acceptContact'` (Agent.hs:1479, sync): `CRInvitation cr` → `joinConn … cr` (classic, unchanged); `CRConfirmation dr` → the O3' continue-ratchet path.
- `newConnToAccept` (Agent.hs:1296, via `prepareConnectionToAccept`): `CRInvitation cr` → `newConnToJoin … cr` (unchanged); `CRConfirmation dr` → create the `NewConnection` shell from `drAgentVersion`/`drPQSupport` (`createNewConn`, generating the connId).
- `acceptContactAsync'` (Agent.hs:900): `CRInvitation cr` → `joinConnAsync … cr` (unchanged); `CRConfirmation _` → `throwE $ CMD PROHIBITED` (async DR accept is deferred; DR requests accept synchronously). Chat's REQ/accept is unaffected either way - it only ever passes `invId`, never the `ContactRequest`, which stays internal to the agent.

Storage: `cr_invitation`'s `ToField`/`FromField` (AgentStore.hs:2074-2076) change from `strEncode`/`strDecode` of `ConnectionRequestUri` to a tagged `ContactRequest` encoding (`smpEncode ('I', cr)` / `('C', dr)`). `FromField` tries the tagged decode first and falls back to decoding a legacy bare-URI blob as `CRInvitation`, so un-accepted pre-upgrade rows still decode. `smpInvitation` (Agent.hs:3618) wraps its `connReq` in `CRInvitation`; `smpAddressConfirmation` (O2') writes `CRConfirmation`.

## Part 4 - key rotation (separate concern)

Rotation is required but independent of the handshake above. The whole ratchet-keys bundle - both X448 keys and the KEM - rotates on a schedule, generated fresh each time.

### Schema

```sql
-- one row per ratchet-keys generation for an address; current plus retired-within-window.
-- private side of the advertised RcvE2ERatchetParamsUri - same shape as the ratchets x3dh
-- columns and createRatchetX3dhKeys (AgentStore.hs:1362-1367).
CREATE TABLE address_ratchet_keys(
  address_ratchet_key_id INTEGER PRIMARY KEY AUTOINCREMENT,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  ratchet_key_id BLOB NOT NULL,     -- the published id echoed by requests
  x3dh_priv_key_1 BLOB NOT NULL,    -- X448
  x3dh_priv_key_2 BLOB NOT NULL,    -- X448
  pq_priv_kem BLOB,                 -- RcvPrivRKEMParams (sntrup761 keypair); NULL when PQ is off for this address
  created_at TEXT NOT NULL,
  retired_at TEXT                   -- set on rotation
);
CREATE UNIQUE INDEX idx_address_ratchet_keys ON address_ratchet_keys(conn_id, ratchet_key_id);

-- a DR request stays in conn_invitations with NO schema change: cr_invitation now holds a ContactRequest
-- sum (an invitation URI or a confirmation carrying the post-decrypt ratchet + reply queue), so it stays
-- NOT NULL - no nullable change, no new column on conn_invitations, no new table for the request.
```

`cr_invitation` stays `NOT NULL` - only its decoded value gains a variant (Part 3), so the invitations flow, `REQ`, and chat are unchanged; the only new storage is the `address_ratchet_keys` table. The link signing key is already on the address queue (`rcv_queues.link_priv_sig_key`, M20250322), so nothing is added there - rotation and retrofit re-sign mutable data with it. PostgreSQL mirrors this. Migration `M20260712_address_dr`.

### Rotation logic

`rotateRatchetKeys` (new), run on address subscription, at most every 2 weeks (skip if the current generation is younger):

1. `generateRcvE2EParams` (Ratchet.hs:439) for a fresh generation - two X448 keys, and an sntrup761 keypair only if PQ is on for this address - with a fresh `ratchetKeyId`.
2. Recompute mutable link data with the new `AddressRatchetKeys` (the public `e2eParams`), re-sign with the root key (`encodeSignUserData`, key from `rcv_queues.link_priv_sig_key`), and `LSET` it to the address queue (`setConnShortLink` path).
3. Insert the new `address_ratchet_keys` row (`x3dh_priv_key_1`, `x3dh_priv_key_2`, `pq_priv_kem`); set `retired_at` on the previous row.

Retention window equals queue message retention (`storedMsgDataTTL`, Env/SQLite.hs:237), covering a request that used a just-retired bundle and is still in the address queue. The 2-week cadence bounds how long a recorded first message stays decryptable after a compromise of the current private keys - a retired generation is deleted after the window and then decrypts nothing.

### Cleanup

`cleanupManager` (Agent.hs:2994) gains one step: delete `address_ratchet_keys` rows with `retired_at` older than the window, batched like `deleteRcvMsgHashesExpired` (Agent.hs:3001). Unaccepted DR request rows in `conn_invitations` are handled exactly like unaccepted classic invitation requests - no DR-specific cleanup (a DR request is one `conn_invitations` row, the same class of state as a classic contact request).

## Part 5 - backward compatibility

- A requester older than `addressDRVersion`, or an address without `ratchetKeys`, uses R2/R3 (`AgentInvitation`); the owner uses O1-O8. Unchanged.
- The owner dispatches on the envelope: `AgentInvitation` -> `smpInvitation` (current); `AgentConfirmation` with `ratchetKeyId` on a `ContactConnection` -> `smpAddressConfirmation` (new). Both coexist.
- `AgentConfirmation` without `ratchetKeyId` remains the current confirmation on established connections.
- An existing address gains `ratchetKeys` via a new agent API (e.g. `updateContactAddressLink`) that the app calls with the mutable link data (profile/badge and any other short-link data): the agent generates the DR bundle if absent (the first `address_ratchet_keys` row and its stored private keys), adds `ratchetKeys` to `UserContactData`, re-signs with `rcv_queues.link_priv_sig_key`, and `LSET`s it. **Only mutable data changes - the address (link) is unchanged**, because the keys are in mutable, not fixed, data. Requesters that fetch the updated data use DR; older ones still use `AgentInvitation`. The agent does not do this on its own (it lacks the profile and the user's intent); the app drives it, combined with the full→short address migration.

## Part 6 - tests

- Encoding roundtrips: `UserContactData` with and without `ratchetKeys`, and with the KEM present and absent; `AgentConfirmation` with and without `ratchetKeyId`, across versions.
- Address creation advertises `ratchetKeys` (the `RcvE2ERatchetParamsUri`); `decryptLinkData` (Crypto/ShortLink.hs:100) verifies signatures and the requester negotiates the advertised params to a concrete version, with and without the KEM.
- Both PQ modes: an address whose bundle carries a KEM gives a hybrid ratchet (`pqEncryption` on); one without gives an X448-only ratchet.
- End to end: a DR-advertising address; a new requester establishes the ratchet, sends its profile under it, owner emits `REQ`, accepts, both reach `CON`; assert the profile never travels under per-queue-only encryption; assert `pqEncryption` on.
- Rotation and retrofit: request against the current bundle; against a just-retired bundle within the window still decrypts; against a bundle past the window is discarded and the requester times out; an address that adds `ratchetKeys` via `LSET` is then reached by DR while an old requester still uses `AgentInvitation`.
- Backward compatibility: old requester against a DR address connects via `AgentInvitation`; new requester against a non-DR address falls back to `AgentInvitation`.

## Part 7 - phases

1. Link data: `AddressRatchetKeys` in `UserContactData` (reusing `RcvE2ERatchetParamsUri`), encoding, `encodeSignUserData`; `AgentConfirmation.ratchetKeyId`; address creation taking `InitialKeys` (lifting the `IKUsePQ`-for-`SCMContact` prohibition), generating (`generateRcvE2EParams`, KEM per `initialPQEncryption False`) and storing the first `address_ratchet_keys` row.
2. Handshake: thread the optional `Maybe AddressRatchetKeys` through `joinConnection`/`joinConn`/`joinConnSrv` (present → DR branch, absent → classic); requester R2'/R3' (synchronous one-shot send); owner O1'/O2'/O3' storing the DR request as a `conn_invitations` row whose request value is the `CRConfirmation` variant; `smpConfirmation` `RcvConnection … Nothing` branch and `AgentConnInfoReply` acceptance; end-to-end connection with the profile under the ratchet. Tests pass `AddressRatchetKeys` directly (chat wiring is later work).
3. Rotation and retrofit: schema migration, `rotateRatchetKeys`, retention window, cleanup step, app-driven `LSET` retrofit (with the full→short address migration), rotation/retrofit tests.
