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
4. A repeated request for the same operation must not be executed twice.

## Solution

A service address is a contact address subtype. Both the client and the service are chat bots using the chat library over the agent. The chat library serializes a request into opaque bytes and calls the agent; the agent transports it and returns replies; the chat library deserializes them. The correlation of a reply with its request is the reply queue: each request has its own reply queue, and every message in that queue is a reply to that request.

The exchange:

1. Resolve the service name to a short link and retrieve link data (`LGET`, via proxy when IP protection is needed). Link data holds the root key for verifying replies and the service key bundle for encrypting the request.
2. Create a reply queue (`NEW`, messaging mode, subscribed at creation). The reply queue is a receive queue with an added KEM key; the service encrypts replies to the reply queue keys.
3. Send the request to the service address queue once (unauthenticated `SEND`, via proxy when IP protection is needed). The request includes the reply queue address and its KEM key, and the application payload. It is encrypted to the service key bundle with hybrid X25519 + KEM encryption at the queue layer. There is no transport retry; a reply is the success signal, and a hard error fails the call.
4. The service decrypts the request, delivers the payload to the service application, secures the reply queue, and sends replies. Each reply message includes the request hash, the previous message hash, a flag whether more messages follow, and a non-empty list of application responses; it is signed with the root key.
5. The client verifies each reply message and delivers its responses to the application. The first reply message returns from the call; later reply messages are delivered through a callback the application registered. The client deletes the reply queue on the final message, on the request deadline, or when the application cancels the request.

How this meets the objectives:

1. Unlinkability: fresh keys and a fresh reply queue per request; the sender's IP address and session are protected by existing private routing; the reply queue is deleted after the exchange; nothing is shared between two requests.
2. Encryption: hybrid X25519 + sntrup761 secret at the queue layer for the request and all replies. Request keys are published in mutable link data and rotated with `LSET`; the double ratchet is not used, because it would create per-request state before the service decides to reply and its properties serve long-lived sessions.
3. Authenticity: every reply message is signed with the root key committed in the immutable link data, over the request hash and the message; the previous-message hash in each message detects dropped and reordered messages.
4. Single execution: the service identifies a request by the hash of its payload and, within a fixed retention period, repeats the stored replies for a repeated request without running the operation again.

## Design

Syntax below uses [ABNF][1] with [case-sensitive strings extension][2]. `shortString`, `largeString` and `x509encoded` are defined in the [SMP protocol](../protocol/simplex-messaging.md); `smpServer` and `agentVersion` - in the [agent protocol](../protocol/agent-protocol.md). All hashes below are SHA3-256.

### Service address

A new contact address type - char `s` in short links, next to existing `a`/`c`/`g`/`r`:

```abnf
contactType =/ %s"s" ; service address
```

Link data has the same structure as contact addresses: immutable fixed data (root key, connection request data with the queue address) committed by the link hash, and mutable user data signed by the root key. Fixed data and contact user data encodings ignore trailing bytes, so the field below is added without a new link format.

Agents dispatch on the address type and the envelope type: a normal address rejects requests, a service address rejects invitations and confirmations.

### Service key bundle

Mutable user data of a service address includes a key bundle, appended to the existing contact user data encoding:

```abnf
userContactData = direct ownersList relaysList userLinkData [serviceKeys]
serviceKeys = %s"0" / (%s"1" serviceKeyBundle) ; absent in data from earlier versions
serviceKeyBundle = keyId reqDhKey reqKemKey
keyId = shortString ; identifies the bundle, included in requests
reqDhKey = length x509encoded ; X25519, used instead of the fixed-data queue key
reqKemKey = largeString ; sntrup761 encapsulation key, 1158 bytes
```

The service rotates the bundle with `LSET` and keeps the previous private keys long enough to decrypt requests already in the address queue - the queue message retention. The client retrieves link data for every request, so the published keys are current when the request is sent; a request becomes undecryptable only if it stays in the address queue longer than its key is kept, and such a request is not answered and fails at the client's deadline. Deleting old keys bounds the time recorded requests can be decrypted, so the retention is short and fixed. Nothing about retries or retention is published in link data.

Link data is encrypted with a symmetric key derived from the link, which is not weakened by quantum computers, so publishing the bundle in link data does not weaken the scheme.

Sizes: the KEM public key is 1158 bytes and user data is padded to 13784 bytes, so the bundle fits together with application data.

### Queue-layer PQ encryption

The single-shot queue encryption (today: crypto_box with a secret from the queue DH key and a sender ephemeral key, the ephemeral key in the message public header) is extended to a hybrid scheme in a new SMP client version. The public header gains a third variant:

```abnf
smpPubHeaderHybrid = smpClientVersion %s"2" optKeyId senderPublicDhKey kemCiphertext
optKeyId = %s"0" / (%s"1" keyId) ; present in requests to select the bundle, absent in replies
senderPublicDhKey = length x509encoded ; sender ephemeral X25519 key
kemCiphertext = largeString ; sntrup761 ciphertext, 1039 bytes
```

The secret combines both shared secrets, and the body is encrypted with NaCl secret_box, padded as today:

```
secret = HKDF(dh(recipient key, sender ephemeral key) || KEM shared secret)
```

The header is readable by the destination server, as invitation headers are today; with proxied sending it is not readable by the proxy.

For a request, the recipient keys are the service bundle keys selected by `keyId`. For a reply, the recipient keys are the reply queue keys included in the request. The first reply message includes the hybrid header; the client computes the secret once and stores it in the reply queue record, and later reply messages use it with the plain header. This is the one-secret-per-queue model of existing queues, and the secret is stored the same way the per-queue DH secret is stored on receiving the first message. Invitations and confirmations can adopt the same scheme independently of this design.

### Request

A new agent envelope (alongside `agentConfirmation`, `agentMsgEnvelope`, `agentInvitation`, `agentRatchetKey`):

```abnf
agentRequest = agentVersion %s"Q" replyQueue requestPayload
replyQueue = smpClientVersion smpServer senderId dhPublicKey kemPublicKey
smpClientVersion = 2*2 OCTET
senderId = shortString ; sender ID of the reply queue
dhPublicKey = length x509encoded ; reply queue X25519 key
kemPublicKey = largeString ; reply queue sntrup761 encapsulation key
requestPayload = *OCTET ; remaining bytes, opaque application payload
```

The envelope type indicates to the receiving agent that no connection is created and replies are sent to the reply queue. The request does not include a key to secure the reply queue: the service generates its own sender key and secures the queue with it, as a sender does in the fast handshake. The reply queue address and keys are not part of the hashed payload.

The request hash is the SHA3-256 of `requestPayload` - the same bytes the client sends and the service reads after the server encryption layer is removed. The application sets a request ID inside the payload; two requests are the same operation when their payloads, and therefore their hashes, are equal. A request must fit in one message; a larger payload is sent as an XFTP file description in the payload.

Request delivery follows existing SEND semantics: a hard error (AUTH, QUOTA) fails the call, and the application decides whether to send a new request.

### Replies

The service secures the reply queue and sends the first reply message with one combined SMP command (see below). A reply message uses a new agent envelope, following the signature-first structure of link data:

```abnf
agentResponse = agentVersion %s"P" signature signedResponse
signature = length 64*64 OCTET ; root key signature of signedResponse
signedResponse = requestHash prevMsgHash more responses
requestHash = shortString ; hash of the request payload
prevMsgHash = shortString ; hash of the previous agentResponse message, empty in the first
more = %s"T" / %s"F" ; T - more reply messages follow
responses = length 1*responseItem ; non-empty list of application responses
responseItem = largeString ; opaque application response
```

A reply message includes a list of responses, so responses known together are sent in one message rather than several; responses that become known over time are sent in separate messages. The signature covers the whole message.

The client verifies each reply message: the signature against the root key from link data, the request hash against the sent request, the previous-message hash against the previous message. A message that fails verification is acknowledged and discarded. Forging a reply message requires the root key even if the reply queue keys are known; a signed message cannot be reused for a different request; the previous-message hash detects messages dropped or reordered by the reply queue server.

The first reply message returns from the request call. Later reply messages are delivered through the callback the application registered with the request. The exchange ends on a message with `more` set to false. The client deletes the reply queue on that message, on the request deadline, or when the application cancels the request. Deleting the queue stops further replies: later SEND commands from the service fail with AUTH. Server queue and message expiry limit the lifetime of a reply queue left after a client restart.

### Combined SKEY+SEND command

A new SMP command combining `SKEY` and `SEND` in one transmission:

```abnf
secureSend = %s"SSND " senderAuthPublicKey SP msgFlags SP smpEncMessage
senderAuthPublicKey = length x509encoded
```

The command is authorized with the key it sets, as `SKEY`, and only accepted on messaging-mode queues. The server responds `OK` or `ERR`. It is idempotent in both parts:

- key part: as `SKEY` today - a repeated command with the same key succeeds, a different key fails with AUTH.
- send part: the server keeps the hash of the message until it is acknowledged, and a repeated command with the same message within that period is reported as delivered without delivering it again.

A repeat arriving after the message was acknowledged is delivered as a duplicate and discarded by the receiving agent by message hash, so the server-side hash covers the common case and the agent covers the rest.

The service uses this command for the first reply message. The joining party uses it in the fast connection handshake, where it replaces `SKEY` followed by the `SEND` confirmation, removing one command and one round trip.

### Idempotency

The service agent identifies a request by its hash and keeps, for a fixed retention period it chooses (in the 1 to 24 hour range, in service configuration, not in link data), a record of the ordered reply messages it has sent and the reply queues subscribed under that hash. A repeat request with the same hash does not reach the service application:

- while the first request is being answered, the repeat is added to the record and receives the reply messages already sent, and each later message is sent to every reply queue in the record.
- after the operation completed, the repeat receives the whole stored sequence of reply messages, in order.

This gives single execution over at-least-once delivery. The retention period bounds it: after the record is deleted, a request with the same hash is a new operation and runs again. The application does not rely on the transport for recovery across a restart; it keeps its own state and, after a restart, sends whatever request fits what it knows, which is often a different request (for example, "is this payment still pending" rather than a repeat of "start this payment").

### Out of scope

- Recovery across restart: the transport keeps no exchange across a client restart. The application persists its own state and sends a new request when it needs to.
- Service-initiated messages: there is no standing channel; use a connection where the service must reach the client without a request.
- Abuse protection beyond existing queue quotas: services can require application-level credentials (e.g., a badge) in the request payload; rate limiting is a separate discussion.
- Scaling request reception: a single address queue bounds service throughput; distributing reception across multiple queues or relays (the existing `relays` field in contact link data) is a separate discussion.
- Name resolution: existing addressing layer.

[1]: https://tools.ietf.org/html/rfc5234
[2]: https://tools.ietf.org/html/rfc7405
