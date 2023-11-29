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

6. Sending messages to groups have to be batched in the client to avoid multiple requests for destination relay sessions - such requests can be batched to proxy, even though it leaks _some_ metadata - which destination relays are used by a given sender's IP address, it also reduces the overhead from proxies – it could be an option based on the privacy slider.

6. SMP proxy may also increase utility and privacy of the platform:

- holding messages and retrying them for the new connections while the receiving queue is not secured yet.
- add delays in message delivery to make traffic correlation harder (same can be done in SMP relays).

### Implementation considerations

1. Block size. Possibly, there is not enough spare capacity in the current 16kb block to fit additional headers, any necessary metadata and encryption authentication tags, in which case we cannot send SMP and SMP-proxy traffic in the same transport connection (in case the same server plays both roles). In which case we will need to negotiate role during connection handshake and define a different (sub-)protocol for SMP-proxy.

2. To be decided if we see it as extension of SMP protocol or as another protocol, irrespective of whether it's provided by the same or another server. Given different roles and block size it may be simpler to see it as a separate protocol, and which protocol is provided in the connection is determined during handshake.

3. We probably should aim to avoid changing agent/client logic and see it instead as transport concern that can be dynamically decided at a point of sending a message, based on the current configuration.

4. Configuration should probably allow to choose between not using proxies (particularly, during testing, when it would be the default), using proxies only for unknown relays, and using proxies for all relays (extra traffic, but more complex transport correlation). The clients can aim to use proxy from another provider, to reduce the risks of sharing the information.

### SMP-proxy protocol

The flow of the messages will be:

1. Client requests proxy to create session with the relay by sending `server` command with the SMP relay address and optional proxy basic AUTH (below). It should be possible to batch multiple session requests into one block, to reduce traffic.

2. Proxy connects to SMP relay, negotiating a shared secret in the handshake that will be used to encrypt all sender blocks inside TLS (proxy-relay encryption). SMP relay also returns in handshake its temporary DH key to agree e2e encryption with the client (sender-relay encryption, to protect metadata from proxy).

3. Proxy replies with `server_id` command including relay session ID to identify it in further requests, relay DH key for e2e encryption with the client - this key is signed with the TLS online private key associated with the certificate (its fingerprint is included in the relay address), and the TLS session ID between proxy and relay (this session ID must be used in transmissions, to mitigate replay attacks as before).

A possible attack here is that proxy can use this TLS session to replay commands received from the client. Possibly, it could be mitigated with a bloom filter per proxy/SMP relay connection that would reject the repeated DH keys (that need to be used for replay), and also with DH key expiration (this mitigation should allow some acceptable rate of false positives from the bloom filter).

With 32 bits per key there will be ~1/1,000,000 false positives (see https://en.wikipedia.org/wiki/Bloom_filter), and the filter would use ~32mb per each proxy connection if we reset relay key every 1000000 messages or more frequently. Given that the only commands accepted via relay would be SEND, replaying it would be interpreted by the receiving client as duplicate message delivery, so a small number of replayed messages won't cause any problems. But without mitigation it could be used to flood the receiving SMP relay queues with repeated messages, effectively causing DoS on these queues, even in case when SMP relays require basic auth to create queues.

Given that the client chooses proxy it has some trust to, maybe this replay attack risk can be accepted.

4. Now the client sends `forward` to proxy, which it then forwards to SMP relay, applying additional encryption layer.

5. SMP relay sends `response` to proxy applying additional encryption layer, which it then forwards to the client removing the additional encryption layer.

Effectively it works as a simplified two-hop onion routing with the first relay (proxy) chosen by the sending client and the second relay chosen by the recipient, not only protecting senders' IP addresses from the recipients' relays, but also preventing recipients relays from correlating senders' traffic to different queues, as TLS session is owned by the proxy now and it mixes the traffic from multiple senders. To correlate traffic to users, proxy and relay would have to combine their information. SMP relays are still able to correlate traffic to receiving users via transport session.

Sequence diagram for sending the message via SMP proxy:

```
-------------               -------------                     -------------              -------------
|  sending  |               |    SMP    |                     |    SMP    |              | receiving |
|  client   |               |   proxy   |                     |   relay   |              |  client   |
-------------               -------------                     -------------              -------------
     |       `server`             |                                 |                          |
     | -------------------------> |   create TLS session, get keys  |                          |
     |                            | ------------------------------> |                          |
     |        `server_id`         |       (if doesn't exist)        |                          |
     | <------------------------- |                                 |                          |
     |                            |                                 |                          |
     | TLS(F:s2r(SEND(e2e(msg)))) |                                 |                          |
     | -------------------------> | TLS(F:p2r(s2r(SEND(e2e(msg))))) |                          |
     |                            | ------------------------------> |                          |
     |                            |                                 |                          |
     |                            |     TLS(R:p2r(s2r(OK/ERR)))     |                          |
     |     TLS(R:s2r(OK/ERR))     | <------------------------------ |                          |
     | <------------------------- |                                 | TLS(MSG(r2c(e2e(msg))))  |
     |                            |                                 | -----------------------> |
     |                            |                                 |                          |
     |                            |                                 |        TLS(ACK)          |
     |                            |                                 | <----------------------- |
     |                            |                                 |                          |
     |                            |                                 |                          |

```

Below diagram shows the encrypttion layers for `forward` and `response` commands:

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

When proxy connects to SMP relay it would indicate in the handshake that it will use proxy protocol and the SMP relay would expect the same `forward` commands and reply with `response`s.

Below syntax aims to fit in 16kb block using spare capacity in SMP protocol.

```abnf
proxy_block = padded(proxy_transmission, 16384)
proxy_transmission = corr_id relay_session_id proxy_command
corr_id = length *8 OCTET
proxy_command = server / server_id / forward / response / error
server = "S" address [relay_basic_auth] ; creates transport session between proxy and relay
server_id = "I" relay_session_id tls_session_id signed_relay_key ;
    ; session_id is the TLS session ID between proxy and relay, it has to be included inside encrypted block to prevent replay attacks
forward = %s"F" random_dh_pub_key encrypted_block
response = %s"R" encrypted_block; response received from the destination SMP relay
relay_session_id = length *8 OCTET
error = %s"E" error
```

The overhead is: 1+8 (corrId) + 1+8 (relay_session_id) + 1 (command) + 1+32 (random_dh_pub_key) + 2 (original length) + 16 (auth tag for e2e encryption) + 16 (auth tag for proxy to relay encryption) = 86 bytes. The reserve for sent messages in SMP is ~84 bytes, so it should about fit with some reduced bytes somewhere.

Another possible design is to allow mixing sent messages and normal SMP commands in the same transport connection, but it can make fitting in the block a bit harder, additional overhead would be: 1 (transmission count) + 2 (transmission size) + 1 (empty signature) = 4 bytes.

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
