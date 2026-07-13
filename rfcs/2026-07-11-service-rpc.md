---
Proposed: 2026-07-11
Protocol: agent-protocol (new version)
Depends on: 2026-07-12-address-pqdr-keys
---

# One-off requests to service addresses

Implementation plan: to follow, after this and the address-DR RFC are reviewed.

## Problem

Client applications need to interact with services, for example: badge issuance, directory requests, telemetry submissions, blockchain reads and writes, LLM calls. The only communication primitive available today is a duplex connection, so each of these interactions requires the full connection procedure - creating queues, key agreement, double ratchet initialization - and leaves persistent state on both sides: queues, ratchet state, connection records, message history.

This is the wrong primitive for most service interactions:

1. Cost. To send the first request to a not yet connected service, the client and the service exchange multiple commands across two servers. For "search the directory" all of it is overhead. The setup cost also creates an incentive to keep connections open, and a service with N users who used it once permanently holds N sets of queues and ratchet states.

2. Privacy. A connection is a stable pairwise pseudonym. If a service were to use a duplex connection, it could link all requests made over it into a profile: search history in the directory, blockchain operations linked even when different on-chain keys are used, telemetry that becomes longitudinal tracking. The client also accumulates history that can be recovered from the device. Where continuity is needed, it can be provided in the application protocol (e.g., a token included in requests), without a transport-level identity.

3. Encryption. Messages sent to contact addresses outside an established connection have a single layer of X25519 encryption, with no post-quantum protection and no forward secrecy. This is not acceptable for service requests.

In-app service addresses should be stored as names resolving to links via the existing addressing layer (server host in the link authority, current link data retrieved with `LGET`), so that service links can be changed without redeploying the apps. Name resolution is already supported, and out of scope.

## Security objectives

1. Requests from the same client must not be linkable to each other by the service or by servers, and no long term state is created on either side in the transport layer.
2. Post-quantum resistant end-to-end encryption of requests and replies.
3. Reply authenticity must be verifiable against the link; substitution, replay, dropping or reordering of replies by servers must be detectable.
4. A repeated request for the same operation must not be executed twice.

## Solution

A service address is an ordinary short-link contact address. The client sends one request to the address queue and receives replies in a reply queue it creates for the request. The double ratchet is established from the address's published keys (see the address-DR RFC): the request is the first ratchet message, and replies are subsequent ratchet messages. So a request-response exchange is a short-lived one-directional double ratchet connection, established from the first message and removed after the last.

The exchange:

1. Retrieve the address link data (`LGET`, via proxy when IP protection is needed): the root key, the identity key, the prekey with its id, and the KEM key.
2. Create a reply queue (`NEW`, subscribed).
3. Establish the sending ratchet from the published keys (`pqX3dhSnd`, `initSndRatchet`). Build the request: the reply queue, the requester's X3DH parameters, and the payload encrypted under the ratchet. Encrypt the whole request to the address queue and send it once (unauthenticated `SEND`, via proxy when IP protection is needed). There is no transport retry; a reply is the success signal, and a hard error fails the request.
4. The service establishes the receiving ratchet from its private keys and the request's X3DH parameters (`pqX3dhRcv`, `initRcvRatchet`), decrypts the payload, and delivers it to the service application. To reply it creates a send connection with the ratchet and sends reply messages to the reply queue, each encrypted under the ratchet.
5. The client decrypts and delivers each reply message to the application. The first reply message returns from the request; later reply messages are delivered through a callback the application registered. The exchange ends on a reply marked final. The client deletes the reply queue and the ratchet on the final message, the deadline, or when the application cancels.

How this meets the objectives:

1. Unlinkability: fresh X3DH keys and a fresh reply queue per request; the sender's IP address and session are protected by existing private routing; the reply queue and both ratchets are removed after the exchange; nothing is shared between two requests.
2. Encryption: the double ratchet with its sntrup761 KEM, from the first message.
3. Authenticity: the ratchet is established against the identity key committed by the link hash, so a decryptable reply proves it came from the address owner; the ratchet message numbering detects dropped and reordered replies. No separate signature is needed.
4. Single execution: the service identifies a request by the hash of its decrypted payload and, within a fixed retention period, re-sends the stored replies for a repeated request without running the operation again.

## Design

Syntax uses [ABNF][1] with [case-sensitive strings extension][2]. `SMPQueueInfo`, `agentVersion`, and the X3DH and ratchet types are as in the [agent protocol](../protocol/agent-protocol.md) and `Crypto.Ratchet`.

### Correlation and chat

A reply is connected to its request by the reply queue: each request has its own reply queue, and every message in that queue is a reply to that request. The request hash (of the decrypted payload) is used only for idempotency. The application sets an id inside the payload to make two requests the same operation or different ones; the agent does not read it.

Both ends are chat bots on the chat library over the agent. The chat library serializes a service command into the request payload and deserializes the responses; the agent transports them, establishes and removes the ratchet, and correlates by reply queue.

### Request

A new agent envelope, shaped like `AgentConfirmation` (X3DH parameters to establish the ratchet, plus a body encrypted under it):

```abnf
agentRequest = agentVersion %s"Q" replyQueues prekeyId sndE2EParams encRequest
replyQueues = length 1*SMPQueueInfo ; the first is used; more are for redundancy
prekeyId = shortString ; the published prekey used, from link data
sndE2EParams = <requester Snd X3DH parameters, see address-DR RFC>
encRequest = <ratchet-encrypted request payload>
```

The whole `agentRequest` is encrypted to the address queue with the per-queue layer and sent with `SEND`, as an invitation is today. The reply queue keys and the X3DH parameters are not visible to servers. A request must fit one message; a larger payload is an XFTP file description in the payload.

The request hash is the SHA3-256 of the decrypted payload - the same bytes on both sides. There is no transport retry; a hard error (`AUTH`, `QUOTA`) fails the request, and the application decides whether to send a new one.

### Replies

The service creates a send connection with the ratchet and sends reply messages to the reply queue, each encrypted under the ratchet. A reply message uses a new agent envelope:

```abnf
agentResponse = agentVersion %s"P" final responses
final = %s"T" / %s"F" ; T - no more reply messages follow
responses = length 1*responseItem ; non-empty list of application responses
responseItem = largeString ; opaque application response
```

Each message includes a list of responses, so responses known together are sent in one message and responses that become known over time are sent in separate messages. The message is encrypted and numbered by the ratchet, which authenticates it against the committed identity key and detects dropped or reordered messages; no separate signature is used.

The first reply message returns from the request. Later reply messages are delivered through the callback the application registered with the request, while the process runs. The exchange ends on a message with `final = T`. The client deletes the reply queue and the ratchet on that message, on the deadline, or when the application cancels. Deleting the reply queue stops further replies. The transport keeps no exchange across a client restart; the application keeps its own state and sends a new request when it needs to.

### Rejection

The service refuses a request with the `AgentRejection` envelope from the [communicating rejection RFC](../../simplex-chat/docs/rfcs/2024-03-22-communicating-reject.md), sent to the reply queue under the ratchet, with an opaque application reason. The same envelope communicates refusal of a connection request, where today it is dropped silently. A rejection ends the exchange like a final reply.

### Idempotency

The service keeps, for a fixed retention period it chooses (1 to 24 hours, in service configuration, not in link data), the request hash, the ordered response messages it produced, and the reply queues and ratchets subscribed under that hash. A repeat request with the same hash does not reach the service application:

- while the first request is being answered, the repeat establishes its own ratchet and reply queue, is added to the record, receives the responses already produced, and receives each later response too.
- after the operation completed, the repeat receives the whole stored sequence of responses, re-encrypted under its own ratchet.

The stored responses are the application response bytes, not the ratchet ciphertext, because a repeat establishes a new ratchet and the responses are re-encrypted for it. This gives single execution over at-least-once delivery. After the retention period a request with the same hash is a new operation and runs again.

### Out of scope

- Recovery across restart: the transport keeps no exchange across a client restart; the application persists its own state and sends a new request when it needs to.
- Service-initiated messages: there is no standing channel; use a connection where the service must reach the client without a request.
- Abuse protection beyond existing queue quotas: services can require application-level credentials (e.g., a badge) in the request payload; rate limiting is a separate discussion.
- Scaling request reception: a single address queue bounds service throughput; distributing reception across multiple queues or relays (the existing `relays` field in contact link data) is a separate question, but it would fit well with name resolving to multiple addresses, both for redundancy, reliability and higher throughput.
- Name resolution: existing addressing layer.

[1]: https://tools.ietf.org/html/rfc5234
[2]: https://tools.ietf.org/html/rfc7405
