# Client certificates for high volume clients

## Problem

The absense of user and client identification benefits privacy, but it requires separately authorizing subscription for each messaging queue, that simply doesn't scale even for the current traffic and network size.

While chat relays (aka super-peers) would reduce the number of subscriptions required for the usual clients, by replacing connections with each group member to 1-3 connections with chat relays per group/community, it would shift the burden to the chat relays, that are also clients.

While self-hosted chat relays may want to retain privacy, this is not needed (and counter-productive) for the chat relays provided by network operators.

Even today, directory service subscribing to all queues may take 15-20 minutes, which is experienced as downtime by the end users.

Notification servers are also, effectively, clients that subscribe to the messaging servers, and it also takes 15-20 minutes.

Not only these subscription take a lot of time, they also consume a large amount of memory both in the clients and in the servers, as association between clients and queues is currently session-scoped and not persisted anywhere (and it should not be, because end-users' clients do need privacy).

## Solution

High volume "clients" (operators' chat relays, directory service, SimpleX Chat team support client, SimpleX Status bot, etc.) that don't need privacy will identify themselves to the messaging servers at a point of connection by providing client sertificate in TLS handshake.

All subscriptions made in this session will be creating a permanent association of the messaging queue with the client, and on subsequent reconnections the client will be automatically "subscribed" to all their queues.

This will save a lot of time subscribing and resubscribing on server and client restarts, servers' bandwidth, servers' traffic spikes, and memory of both clients and servers.

## Protocol

Client certificate and the signature key to be used for client authorization will be passed in handshake.

To transition existing queues, the subscription command will have to be double-signed - by the queue key, and then by client key - specific protocol syntax is TBC.

When server receives such "hand-over" subscription it would create a permanent association between the client certificate and the queue, and on subsequent re-connections the client would be automatically subscribed to all the existing queues still associated with the client.

It would be helpful for server to notify the client about the number of queues it was subscribed to - it would both inform the client that it has to re-connect in case of interruption, and can be used for client and server statistics.

When client creates a new queue, it would also sign the request with client key only (or, possibly, with two keys?). There may be a benefit to double-sign queue creation too, as while subscriptions would happen automatically, other queue operations (e.g., deletion, or changing associated queue data for short links) would still require signature with queue key (or two signatures).

The open question is whether there is any value in allowing to remove the association between the client and the queue. Probably not, as threat model should assume that the server would retain this information, and the use-case for users controlling their servers is narrow.

## Protocol connection handshake

Currently, the types for handshakes are:

```haskell
data ServerHandshake = ServerHandshake
  { smpVersionRange :: VersionRangeSMP,
    sessionId :: SessionId,
    -- pub key to agree shared secrets for command authorization and entity ID encryption.
    -- todo C.PublicKeyX25519
    authPubKey :: Maybe (X.CertificateChain, X.SignedExact X.PubKey)
  }

data ClientHandshake = ClientHandshake
  { -- | agreed SMP server protocol version
    smpVersion :: VersionSMP,
    -- | server identity - CA certificate fingerprint
    keyHash :: C.KeyHash,
    -- | pub key to agree shared secret for entity ID encryption, shared secret for command authorization is agreed using per-queue keys.
    authPubKey :: Maybe C.PublicKeyX25519,
    -- | Whether connecting client is a proxy server (send from SMP v12).
    -- This property, if True, disables additional transport encrytion inside TLS.
    -- (Proxy server connection already has additional encryption, so this layer is not needed there).
    proxyServer :: Bool
  }
```

`ServerHandshake` already contains `authPubKey` with the server certificate chain and the signed key for connection encryption and creating a shared secret for denable authorization (with client entity key) and session encryption layer.

`ClientHandshake` contains only ephemeral `authPubKey` to compute a shared secret for session encryption layer, so we need an additional field for client certificate:

```haskell
clientPubKey :: Maybe X.CertificateChain
```

For operators' clients we may optionally include operators' certificate in the chain, and that would allow servers to identify operators if either wants to. This would improve end-user security, as not only the server would validate that its certificate matches the address, but it would also validate that it is operated by SimpleX Chat or by Flux, preventing any server impersonation (e.g., via DNS manipulations) - the client could then report that the files are hosted on SimpleX Chat servers, but then can stop and show additional warning in case certificate does not match the domain - same as the browsers do with CA stores in the client.

## Protocol transmissions

Each transport block can contain one or several protocol transmissions.

Each transmission has this structure:

```abnf
transmission = authenticator authorized
; authenticator - Ed25519 signature for recipients or X25519 authenticator for senders, to provide repudiation.
; authenticator authorizes the rest of the transmission.
authorized = sessId corrId entityId command.
; sessId is tls-unique channel binding, its presense in the transmission prevents replay attacks.
```

The proposed change would replace authenticator eith with an array of authenticators or with exactly one or two authenticators, where the first one will remain resource-level authorization (queue key), and the second - optional one - would be client authorization with client key.

```abnf
authenticator = queue_authenticator ("0" / "1" client_authenticator)
; "0" and "1" characters (digit characters, not x00 or x01) are conventionally used for Maybe types in the protocol.
```

All queues created with client key will have to be double-authorized with both the queue key and the client key - both the client and the server would have to maintain this knowledge, whether the queue is associated with the client or not.

Asymmetric retries have to be considered - the first request creating this association may succeed on the server and timeout on the client.

## Subscription

There are two options:

- automatically subscribe client on connection in case certificate is introduced. This avoids additional command for the client, but it may work for considered ephemeral session associations with the usual clients (see below) for iOS NSE clients.
- send a separate command authorized with the client key passed in handshake.

Command response pattern seems better for ephemeral session associations, and more consistent with the protocol design.

The command and response:

```haskell
CSUB :: Command Recipient -- to enable all client subscriptions, empty entity ID in the transmission, signed by client key - it must be the same as was used in handover subscription signature.
CSQS :: Word32 -> BrokerMsg -- response from the server, includes the number of subscribed queues
```

## Ephemeral client-session association

This was considered to reduce costs for the usual clients to re-subscribe. Currently it's a big problem, because of groups, and with transition to chat relays it won't be.

For some very busy end-user clients it may help.

Given that server has access to an ephemeral association between recipient client session and queues anyway (even with clients connecting via Tor, unless per-connection transport isolation is used), introducing `sessionPubKey` to allow resubscription to the previously subscribed queues may reduce the traffic. This won't change threat model as the server would only keep this association in memory, and not persist it. Clients on another hand may safely persist this association for fast resubscription on client restarts.

This is not planned for the forseable future, as migrating to chat relays would solve most of the problem.

Assuming an average active user has 20 contacts and 20 groups, and they would need ~3 subscriptions for each (for redundancy), so about 120 subscription to reconnect. The single 16kb transport block allows to send ~136 subscriptions. Which means that ephemeral sessions would create no value for clients at all, unless they are super active.

Further, improving transport efficiency for super-active non-identified clients may help network abuse, so ephemeral sessions may have negative value.
