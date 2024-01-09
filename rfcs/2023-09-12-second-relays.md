# Protecting IP addresses of the users from their contacts

## Problem

SMP protocol relays are chosen and can be controlled by the message recipients. It means that the recipients can find out IP addresses of message senders by modifying SMP relay code (or by using proxies and timing correlation), unless the senders use VPN or some overlay network. Tor is an audequate solution in most cases to mitigate it, but it requires additional technical knowledge to install and configure (even installing Orbot on Android is seen as "complex" by many users), and reduces usability because of higher latency.

The lack of in-built IP address protection is the main concern of many users, particularly given that most people do not realise that it is lacking by default - without transport protection SimpleX is not perceived as a "whole product".

Similarly, XFTP protocol relays are chosen by senders, and they can be used to detect file recipients' IP addresses.

## Possible solutions

1. Embed Tor in the client.

Pros:
- no changes in the protocols/servers
- acceptable threat model for most users
- removes complexity of installing and configuring Tor
- probably, the most attractive option for Tor users

Cons:
- higher latency and error rate
- higher resource usage
- requires us updating Tor client regularly
- restriction on Tor usage in some networks, so it would require supporting bridges in the app UI
- legislative restrictions on Tor usage, so it may require supporting multiple app versions, and won't solve the problem where Tor is not embedded

2. Thin clients with hosted accounts.

Host some part of the current client on the server and have another part running on the devices.

Pros:
- substantially reduces the traffic for mobile clients
- probably the most attractive option for mass market users who expect to have an account on the server and be able to access it from multiple devices and via web.

Cons:
- a lot of design and development
- makes accounts visible to the server
- the new protocol design to protect connections graph and message content from the hosting server.
- quite different threat model

Overall, this is not a viable or even appropriate option for the current stage.

3. SMP / XFTP proxy.

Introduce SMP and XFTP protocol extenstions to allow message senders and file recipients to delegate the tasks of sending messages and receiving files to the proxies, so that peer-chosen relays can only observe IP addresses of the proxies and not of the users.

Pros:
- no dependency on and lower latency than via Tor
- reduces client traffic, both due to retries handled by these proxies and due to the smaller number of connections to the peer-chosen relays. The flip side is that additional commands (and traffic) are needed to create the sessions with relays.
- higher transport privacy: protects IP addresses from peers and makes transport correlation harder.
- additional function: retrying pending messages, while the queue is not secured yet, without extra traffic for the clients.
- improves current threat model by preventing session-based correlation of the traffic by the destination relay (assuming no information sharing with the proxies), as there will be one session between proxy and destination relay, mixing traffic from multiple users.

Cons:
- design and development cost
- can undermine delivery stability

This seems an attractive option, both from technical (reasonable complexity) and positioning (moving SimpleX closer to mix networks, while still avoiding server list visibility) points of view, and it is in the middle between embedding Tor, which would make the product more niche and has downsides and development costs too, and thin clients, which is 10x+ more work, and also creates a different threat model, that is not very attractive for the current stage and users.

Below considers this design.

## SMP/XFTP proxy design

### Design requirements

1. To avoid increasing the complexity of self-hosting, we should not create additional server types, and existing SMP and XFTP servers should be extended to provide proxy functions.

2. SMP proxy should not be able to observe queue addresses and their count on the destination relays. This requirement is not needed for XFTP proxies, as each file chunk is downloaded only once, so there is no need to hide its address.

3. There must be no identifiers and cyphertext in common in outgoing and incoming traffic inside TLS (the current designs have this quality).

4. Traffic between the client and destination relays must be e2e encrypted, with MITM-by-proxy mitigated, relying on the relay identity (certificate fingerprint), ideally without any additional fingerprint in relay address.

5. SMP proxy should implement retry logic and hold messages while they are delivered. They also should return relay replies to the client. To avoid any additional traffic the client should just add "sent to proxy" status and only show "sent" once proxy returns the response from the destination relay - there should be no additional response from the proxy confirming acceptance to delivery.

This would also reduce the difference in how the traffic looks to the observer - sending via proxy may look similar to sending to the usual server (which can be further supported by friendly destination relays that could add latency for direct requests and reply quickly when response came via proxy and be undermined by hostile relays that would introduce some latency pattern to help traffic correlation. The latter problem can be mitigated by having a fixed response latency from proxy that may be "come back later for destination response").

6. Sending messages to groups have to be batched in the client to avoid multiple requests for destination relay sessions - such requests can be batched to proxy, even though it leaks _some_ metadata - which destination relays are used by a given sender's IP address, it also reduces the overhead from proxies – it could be an option based on the privacy slider.

6. SMP proxy may also increase utility and privacy of the platform:

- holding messages and retrying them for the new connections while the receiving queue is not secured yet.
- add delays in message delivery to make traffic correlation harder (same can be done in SMP relays).

### Implementation considerations

1. Block size. Possibly, there is not enough spare capacity in the current 16kb block to fit additional headers, any necessary metadata and encryption authentication tags, in which case we cannot send SMP and SMP-proxy traffic in the same transport connection (in case the same server plays both roles). In which case we will need to negotiate role during connection handshake and define a different (sub-)protocol for SMP-proxy.

2. To be decided if we see it as extension of SMP protocol or as another protocol, irrespective of whether it's provided by the same or another server. Given different roles and block size it may be simpler to see it as a separate protocol, and which protocol is provided in the connection is determined during handshake.

3. We probably should aim to avoid changing agent/client logic and see it instead as transport concern that can be dynamically decided at a point of sending a message, based on the current configuration.

4. Configuration should probably allow to choose between not using proxies (particularly, during testing, when it would be the default), using proxies only for unknown relays, and using proxies for all relays (extra traffic, but more complex transport correlation - although randomizing this choice can be more beneficial to the transport privacy). The clients can aim to use proxy from another provider, to reduce the risks of sharing the information.

### SMP-proxy protocol

The flow of the messages will be:

1. Client requests proxy to create session with the relay by sending `proxy` command with the SMP relay address and optional proxy basic AUTH (below). It should be possible to batch multiple session requests into one block, to reduce traffic.

2. Proxy connects to SMP relay, and uses `p_handshake` command to negotiate a shared secret in the handshake that will be used to encrypt all sender blocks inside TLS (proxy-relay encryption). SMP relay also returns in handshake its temporary DH key to agree e2e encryption with the client (sender-relay encryption, to hide metadata sent to the destination relay from proxy).

3. Proxy replies to sender with `r_key` message using "entityId" transmission field to indicate session ID for using in further requests, relay DH key for _s2r_ encryption with the client - this key is signed with the TLS online private key associated with the certificate (its fingerprint is included in the relay address), and the TLS session ID between proxy and relay (this session ID must be used in transmissions, to mitigate replay attacks as before).

A possible attack here is that proxy can use this TLS session to replay commands received from the client. Possibly, it could be mitigated with a bloom filter per proxy/SMP relay connection that would reject the repeated DH keys (that need to be used for replay), and also with DH key expiration (this mitigation should allow some acceptable rate of false positives from the bloom filter).

With 32 bits per key there will be ~1/1,000,000 false positives (see https://en.wikipedia.org/wiki/Bloom_filter), and the filter would use ~32mb per each proxy connection if we reset relay key every 1000000 messages or more frequently. Given that the only commands accepted via relay would be SEND, replaying it would be interpreted by the receiving client as duplicate message delivery, so a small number of replayed messages won't cause any problems. But without mitigation it could be used to flood the receiving SMP relay queues with repeated messages, effectively causing DoS on these queues, even in case when SMP relays require basic auth to create queues.

Given that the client chooses proxy it has some trust to, maybe this replay attack risk can be accepted.

It is important that the same public key from destination relay is returned to all clients, so proxy does not need to repeat this request to know relays while the key did not expire, as using different keys for different clients would allow destination relays to correlate requests to the clients. A proxy that colludes with the destination relay can pass different public keys to the same client, but it is not changing threat model as colluding proxy can share information as well. It is also important that the client uses a new random key for each command, as using the same key would allow the destination relay to identify these commands as comming from the same user, and using a different key for each queue while would protect privacy of the user from the destination relay, would make it visible to the proxy how many different queues the client has on destination relay.

*Unrelated cosideration for SMP protocol privacy improvement*: instead of signing commands to the destination relay, the sender could have a ratchet per queue agreed with the destination relay that would simply use authenticated encryption with per-message symmetric key to encrypt the message on the way to relay, and this encryption would be used as a proof of sender.

4. Now the client sends `forward` to proxy, which it then forwards to SMP relay, applying _p2r_ encryption layer.

5. SMP relay sends `r_response` to proxy applying _p2r_ encryption layer, which it then forwards to the client removing the _p2r_ encryption layer.

Effectively it works as a simplified two-hop onion routing with the first relay (proxy) chosen by the sending client and the second relay chosen by the recipient, not only protecting senders' IP addresses from the recipients' relays, but also preventing recipients relays from correlating senders' traffic to different queues, as TLS session is owned by the proxy now and it mixes the traffic from multiple senders. To correlate traffic to users, proxy and relay would have to combine their information. SMP relays are still able to correlate traffic to receiving users via transport session.

Sequence diagram for sending the message via SMP proxy:

```
-------------               -------------                     -------------              -------------
|  sending  |               |    SMP    |                     |    SMP    |              | receiving |
|  client   |               |   proxy   |                     |   relay   |              |  client   |
-------------               -------------                     -------------              -------------
     |          `proxy`           |                                 |                          |
     | -------------------------> |  `p_handshake` (if !connected)  |                          |
     |                            | ------------------------------> |                          |
     |                            |              `r_key`            |                          |
     |                            | <------------------------------ |                          |
     |          `r_key`           |                                 |                          |
     | <------------------------- |                                 |                          |
     |                            |                                 |                          |
     |       `forward` (s2r)      |                                 |                          |
     | -------------------------> |                                 |                          |
     |                            |          `forward` (p2r)        |                          |
     |                            | ------------------------------> |                          |
     |                            |         `r_response` (p2r)      |                          |
     |                            | <------------------------------ |                          |
     |       `r_response`         |                                 |           `MSG`          |
     | <------------------------- |                                 | -----------------------> |
     |                            |                                 |           `ACK`          |
     |                            |                                 | <----------------------- |
     |                            |                                 |                          |
     |                            |                                 |                          |
```

Below diagram shows the encrypttion layers for `forward` command and its response:

- s2r (added) - encryption between client and SMP relay, with relay key returned in server_id command, with MITM by proxy mitigated by verifying the certificate fingerprint included in the relay address.
- e2e (exists now) - end-to-end encryption per SMP queue, with double ratchet e2e encryption inside it.
- p2r (added) - additional encryption between proxy and SMP relay with key agreed in the handshake, to mitigate traffic correlation inside TLS. This key could also be signed by the same certificate, if we don't want to rely on TLS security.
- r2c (exists now) additional encryption between SMP relay and client to prevent traffic correlation inside TLS.

```
-----------------             -----------------  -- TLS --  -----------------             -----------------
|               |  -- TLS --  |               |  -- p2r --  |               |  -- TLS --  |               |
|               |  -- s2r --  |               |  -- s2r --  |               |  -- r2c --  |               |
|    sending    |  -- e2e --  |               |  -- e2e --  |               |  -- e2e --  |   receiving   |
|    client     |     MSG     |   SMP proxy   |     MSG     |   SMP relay   |     MSG     |    client     |
|               |  -- e2e --  |               |  -- e2e --  |               |  -- e2e --  |               |
|               |  -- s2r --  |               |  -- s2r --  |               |  -- r2c --  |               |
|               |  -- TLS --  |               |  -- p2r --  |               |  -- TLS --  |               |
-----------------             -----------------  -- TLS --  -----------------             -----------------
```

When proxy connects to SMP relay it would indicate in the handshake that it will act as a proxy and the SMP relay would expect the same `forward` commands and reply with `response`s.

Common SMP transmission format (v4), for reference:

```abnf
paddedTransmission = <padded(transmission), 16384>
transmission = signature signed
signature = 0 ; empty signatures here
signed = sessionIdentifier corrId entityId (smpCommand / brokerMsg)
```

- `corrId` is fully random each time and used as a nonce for encrypted blocks.
- `entityId` carries tlsUniq from the current proxy-to-relay connection.
- `smpCommand` gets extended with `s2p_command / p2r_command`.
- `brokerMsg` gets extended with `r_key / r_response`.

```abnf
s2p_command = proxy / forward
p2r_command = p_handshake ; forward is
proxy = %s"PROXY" length relayUri [basicAuth]
relayUri = length %s"smp://" serverIdentity "@" srvHost [":" port]
p_handshake = %"PHS"
forward = %s"FWD" dhPublic encryptedBlock
r_key = %s"RKEY" dhPublic
r_response = %s"RRES" encryptedBlock
dhPublic = length x509encoded
```

The above assumes that the client can only send one message to an SMP relay and then has to wait for response before sending the next message. Missing the response would cause re-delivery (further improvement is possible when proxy detects these redelieveries and not send them to relays but simply reply with the same response).

### Threat model for SMP proxy and changes to threat model for SMP

#### SMP proxy

*can:*

- learn a user's IP address, as long as Tor is not used.

- learn when a user with a given IP address is online.

- know how many messages are sent from a given IP address and to a given destination SMP relay.

- drop all messages from a given IP address or to a given destination relay.

- unless SMP relay detects repeated public DH keys of senders, replay messages to a destination relay within a single session, causing either duplicate message delivery (which will be detected and ignored by the receiving clients), or, when receiving client is not connected to SMP relay, exhausting capacity of destination queues used within the session.

*cannot:*

- perform queue correlation (matching multiple queues to a single user), unless it has additional information from SMP relay.

- undetectably add, duplicate, or corrupt individual messages.

- undetectably drop individual messages, so long as a subsequent message is delivered.

- learn the contents of messages.

- learn the destination queues of messages.

- distinguish noise messages from regular messages except via timing regularities.

- compromise the user's end-to-end encryption with another user via an active attack.

- compromise the user's end-to-end encryption with destination relay via an active attack.

#### SMP relay accessed via SMP proxy

*still can:*

- perform recipients' queue correlation (matching multiple queues to a single recipient) via either a re-used transport connection, user's IP Address, or connection timing regularities

*no longer can:*

- perform senders' queue correlation (matching multiple queues to a single sender) via either a re-used transport connection, user's IP Address, or connection timing regularities, unless it has additional information from SMP proxy.

- learn a sender's IP address, track them through other IP addresses they use to access the same queue, and infer information (e.g. employer) based on the IP addresses, even if Tor is not used.

The rest of the threat model for SMP relays remains the same as in [overview](../protocol/overview-tjr.md#simplex-messaging-protocol-server).
