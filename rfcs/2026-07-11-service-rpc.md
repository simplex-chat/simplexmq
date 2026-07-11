# One-off requests to service addresses

Implementation plan: [../plans/2026-07-11-service-rpc-implementation.md](../plans/2026-07-11-service-rpc-implementation.md)

## Problem

Client applications need to interact with services, for example: badge issuance, directory requests, telemetry submissions, blockchain reads and writes, LLM calls. The only communication primitive available today is a duplex connection, so each of these interactions requires the full connection procedure - creating queues, key agreement, double ratchet initialization - and leaves persistent state on both sides: queues, ratchet state, connection records, message history.

This is the wrong primitive for most service interactions:

1. Cost. To send the first request to a not yet connected service, the client and the service exchange multiple commands across two servers. For "search the directory" all of it is overhead. The setup cost also creates an incentive to keep connections open, and a service with N users who used it once permanently holds N sets of queues and ratchet states.

2. Privacy. A connection is a stable pairwise pseudonym. If a service were to use a duplex connection, it could link all requests made over it into a profile: search history in the directory, blockchain operations linked even when different on-chain keys are used, telemetry that becomes longitudinal tracking. The client also accumulates history that can be recovered from the device. Where continuity is needed, it can be provided in the application protocol (e.g., a token included in requests), without a transport-level identity.

3. Encryption. Messages sent to contact addresses outside an established connection (invitations) have a single layer of X25519 encryption. This was acceptable while such messages contained only a connection link and profile (though it is planned to be improved); it is not acceptable for service requests.

In-app service addresses should be stored as names resolving to links via the existing addressing layer (server host in the link authority, current link data retrieved with LGET), so that service links can be changed without redeploying the apps. Name resolution is already supported, and out of scope.

## Security objectives

1. Requests from the same client must not be linkable to each other by the service or by servers, and no state that outlives the exchange is created on either side.
2. Post-quantum resistant e2e encryption of requests and replies; decryptability of recorded requests must be bounded by key rotation, without changing the address.
3. Reply authenticity must be verifiable against the link; substitution, replay, dropping or reordering of replies by servers must be detectable.
4. A repeated or replayed request must not be executed twice.

## Solution

A service address is a contact address subtype. The client sends a request in a single message to the address queue and receives replies in a reply queue it creates for this request:

1. Resolve the service name to a short link; retrieve and cache link data (`LGET`, via proxy when IP protection is needed).
2. Create a reply queue on a client-chosen server (`NEW`, messaging mode, sender can secure, subscribed at creation).
3. Send the request to the service address queue (unauthenticated `SEND`, via proxy when IP protection is needed). The request contains the reply queue address with fresh keys, and is encrypted to rotatable service keys published in link data, using hybrid X25519 + KEM encryption at the queue layer.
4. The service secures the reply queue and sends the first reply with one combined command. Replies are encrypted to the fresh keys from the request; each reply is signed with the root key over the reply and the request hash, and includes a flag whether more replies follow.
5. The client receives replies until the final one or a deadline, then deletes the reply queue (`DEL`).

To the first request the client sends 3 commands (2 with cached link data). Streamed replies (LLM output) and delayed replies (credential issued after payment) are ordinary queue messages, distinguished only by the flag whether more replies follow.

How this meets the objectives:

1. Unlinkability: fresh keys and a fresh reply queue per request; the sender's IP address and session are protected by existing private routing; the reply queue is deleted after the exchange; nothing is shared between two requests.
2. Encryption: hybrid X25519 + sntrup761 secret at the queue layer for the request and all replies; keys are published in mutable link data, rotated with `LSET`, old keys deleted after a short window. The double ratchet is not used: it would create per-request state before the service decides to reply, and its properties serve long-lived sessions, not one-off exchanges.
3. Authenticity: every reply is signed with the root key committed in the immutable link data, over the reply and the request hash; the hash chain across replies detects dropped and reordered replies.
4. Replay protection: a retry or replay is the byte-identical request; the service agent stores sent replies for a limited window and re-sends them without executing the request again.

## Design

Syntax below uses [ABNF][1] with [case-sensitive strings extension][2]. `shortString`, `largeString` and `x509encoded` are defined in the [SMP protocol](../protocol/simplex-messaging.md); `smpServer` and `agentVersion` - in the [agent protocol](../protocol/agent-protocol.md). All hashes below are SHA3-256.

### Service address

A new contact address type - char `s` in short links, next to existing `a`/`c`/`g`/`r`:

```abnf
contactType =/ %s"s" ; service address
```

Link data has the same structure as contact addresses: immutable fixed data (root key, connection request data with the queue address) committed by the link hash, and mutable user data signed by the root key. Fixed data and contact user data encodings ignore trailing bytes, so the fields below are added without a new link format.

Agents dispatch on the address type and the envelope type: a normal address rejects requests, a service address rejects invitations and confirmations.

### Service key bundle

Mutable user data of a service address includes a key bundle, appended to the existing contact user data encoding:

```abnf
userContactData = direct ownersList relaysList userLinkData [serviceKeys]
serviceKeys = %s"0" / (%s"1" serviceKeyBundle) ; skipped by earlier versions
serviceKeyBundle = keyId reqDhKey reqKemKey
keyId = shortString ; referenced by requests
reqDhKey = length x509encoded ; X25519, used instead of the fixed-data queue key
reqKemKey = largeString ; sntrup761 encapsulation key, 1158 bytes
```

The service periodically rotates the bundle with `LSET` and keeps previous private keys for a window covering client link data caching and queue message retention. A request encrypted to an unknown key ID fails with an error; the client then re-fetches link data and retries. Deleting expired keys is what bounds decryptability of recorded requests, so the window must be short and fixed.

Link data is encrypted with a symmetric key derived from the link, which is not weakened by quantum computers, so publishing the bundle in link data does not undermine the scheme.

Sizes: KEM public key is 1158 bytes, user data is padded to 13784 bytes - the bundle fits together with application data.

### Queue-layer PQ encryption

The single-shot queue encryption (today: crypto_box with a secret from the queue DH key and a sender ephemeral key, ephemeral key in the message public header) is extended to a hybrid scheme in a new SMP client version. The public header gains a third variant:

```abnf
smpPubHeaderHybrid = smpClientVersion %s"2" optKeyId senderPublicDhKey kemCiphertext
optKeyId = %s"0" / (%s"1" keyId) ; present in requests, absent in replies
senderPublicDhKey = length x509encoded ; fresh X25519 key
kemCiphertext = largeString ; sntrup761 ciphertext, 1039 bytes
```

The secret is derived from both shared secrets, and the body is encrypted with NaCl secret_box, padded as today:

```
secret = HKDF(dh(recipient key, sender ephemeral key) || KEM shared secret)
```

The header is visible to the destination server, as invitation headers are today (with proxied sending it is not visible to the proxy).

The same scheme applies to replies, using the keys from the request: the first reply includes the hybrid header, the hybrid secret is computed once per reply queue and used for subsequent replies with the empty header - the same one-secret-per-queue model as existing sender queues. Invitations and confirmations can adopt the same scheme independently of this design, removing the single-layer X25519 exposure of the profile.

### Request

A new agent envelope (alongside `agentConfirmation`, `agentMsgEnvelope`, `agentInvitation`, `agentRatchetKey`):

```abnf
agentRequest = agentVersion %s"Q" replyQueue requestBody
replyQueue = smpClientVersion smpServer senderId dhPublicKey kemPublicKey sndAuthPublicKey
smpClientVersion = 2*2 OCTET
senderId = shortString ; sender ID of the reply queue
dhPublicKey = length x509encoded ; X25519, fresh per request
kemPublicKey = largeString ; sntrup761 encapsulation key, fresh per request
sndAuthPublicKey = length x509encoded ; key to secure the reply queue
requestBody = *OCTET ; remaining bytes, application-defined
```

The envelope type indicates to the receiving agent that no connection is created and replies are sent to the provided queue. The reply queue keys never appear outside the encrypted request. Requests must fit in one message; larger payloads are passed as an XFTP file description in the request body.

A retry is the byte-identical stored request message, so all correlation uses one value: the request hash - the hash of the message body, the same bytes as sent by the client and as received by the service after the server encryption layer is removed.

Request delivery failures follow existing SEND semantics: on QUOTA (the address queue is full) the client retries with backoff within the request deadline.

### Replies

The service secures the reply queue with the sender key from the request and sends the first reply in one combined SMP command (see below). Replies use a new agent envelope, following the signature-first structure of link data:

```abnf
agentResponse = agentVersion %s"P" signature signedReply
signature = length 64*64 OCTET ; root key signature of signedReply
signedReply = requestHash prevMsgHash final replyBody
requestHash = shortString ; hash of the request message body
prevMsgHash = shortString ; hash of the previous agentResponse, empty in the first reply
final = %s"T" / %s"F" ; F - more replies follow
replyBody = *OCTET ; remaining bytes, application-defined
```

The client verifies each reply: the signature against the root key from link data, the request hash against the sent request, the hash chain against the previous reply. Forging a reply requires the root key even if the reply queue keys are compromised; a signed reply cannot be replayed for a different request; the hash chain detects replies dropped or reordered by the reply queue server.

The client deletes the reply queue on the final flag, on the request deadline (application-defined per request), or on cancellation. Deleting the queue also cancels the stream: subsequent SEND commands from the service fail with AUTH. Router queue and message expiry limit the lifetime of abandoned queues. Stream length between client acknowledgements is bounded by queue capacity.

Delayed replies (e.g., a credential issued after payment) are stored in the reply queue within message retention time and received when the client subscribes again; notification credentials can be added to the reply queue with existing commands. Messages in the reply queue that fail decryption or verification are acknowledged and dropped.

### Combined SKEY+SEND command

A new SMP command combining `SKEY` and `SEND` in one transmission:

```abnf
secureSend = %s"SSND " senderAuthPublicKey SP msgFlags SP smpEncMessage
senderAuthPublicKey = length x509encoded
```

The command is authorized with the key it sets, as `SKEY`, and only accepted on messaging-mode queues. The server responds `OK` or `ERR`. It is idempotent in both parts:

- key part: as `SKEY` today - repeated command with the same key succeeds, different key fails with AUTH
- send part: the server stores a hash of the message body until the message is acknowledged; within that window a repeated command with the same body is not delivered again and is reported as delivered

A retry arriving after the message was acknowledged is delivered as a duplicate and suppressed by the receiving agent (by message hash), so the server-side marker covers the common case and the agent covers the rest.

It is used by the service for the first reply, and by the joining party in the fast connection handshake (currently `SKEY` then `SEND` confirmation), removing one command and round trip from both flows.

### Idempotency

Handled uniformly by the agent: it stores the request hash and sent replies for a window declared in link data (with a default), and re-sends stored replies for a repeated request without invoking the service application. This gives exactly-once execution over at-least-once delivery for all services; services with idempotent semantics of their own lose nothing.

The guarantee is bounded by the window: the client must not retry after the request deadline, and the deadline must not exceed the declared window. Stored replies may be evicted under storage pressure; a retry whose replies were evicted receives an error prompting a new request. Within the window a request is never executed twice.

### Out of scope

- Continuity: sessions across requests are an application concern (tokens in request and reply bodies).
- Service-initiated messages: there is no standing channel; use a connection where push is needed.
- Abuse protection beyond existing queue quotas: services can require application-level credentials (e.g., a badge) in request bodies; rate limiting options are a separate discussion.
- Scaling request reception: a single address queue bounds service throughput; distributing reception across multiple queues or relays (the existing `relays` field in contact link data) is a separate discussion.
- Name resolution: existing addressing layer.

[1]: https://tools.ietf.org/html/rfc5234
[2]: https://tools.ietf.org/html/rfc7405
