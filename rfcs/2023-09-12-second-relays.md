# Protecting IP addresses of the users

# Problem

SMP protocol relays are chosen and can be controlled by the message recipients. It means that the recipients can observe IP addresses of message senders, unless they use VPN or some overlay network. Tor is an audequate solution in most cases to mitigate it, but it requires additional technical knowledge to install and configure (even installing Orbot on Android is seen as "complex" by many users) and reduces usability because of higher latency.

The lack of in-built IP address protection is #1 concerns for many users, particularly given that most people do not realise it is lacking by default and it comes as unexpected that transport protection is not included - without transport protection SimpleX is not a "full product" yet.

Similarly, XFTP protocol relays are chosen by senders, and they can observe file recipients' IP addresses.

# Possible solutions

1. Embed Tor in the client.

Pros:
- no changes in the protocols/servers
- acceptable threat model for most users
- removes complexity of installing and configuring Tor
- probably the most attractive option for Tor users

Cons:
- higher latency
- higher resource usage
- requires updating Tor client regularly
- restriction on Tor usage in some networks, so it would require supporting bridges

2. Thin clients with hosted accounts.

Host the current client on the server and have a thin client running on the devices

Pros:
- substantially reduces the traffic for mobile clients
- probably the most attractive option for mass market users who expect to have an account on the server and be able to access it from multiple devices and via web.

Cons:
- a lot of design and development
- makes accounts visible to the server
- additional protocol design to protect connections graph

Overall, this is not a viable option for the current stage.

3. First step SMP and XFTP relays.

Introduce SMP and XFTP protocol extenstions to allow message senders and file recipients to delegate the tasks of sending messages and receiving files to the relays, so that peer-chosen relays can only observe IP addresses of other relays and not of the users.

Pros:
- no dependency on Tor
- lower latency
- reduces client traffic, both due to retries handled by these additional relays and due to the smaller number of connections to the peer-chosen relays.
- higher transport privacy: protects IP addresses from peers and makes transport correlation harder.
- additional functions (sending pending and scheduled messages).
- prevents session-based correlation of the traffic by the destination relay (assuming no collusion with the first-step relay), as there will be one session between first-step relay and destination relay mixing traffic from multiple users.

Cons:
- substantial design and development
- can undermine delivery stability

This seems an attractive option, both from technical (reasonable complexity) and positioning (moving it closer to nix networks, while still avoiding server list visibility), and it is the middle between using Tor, which would make the product more niche and has downsides and development cost too, and thin clients, which is much more work and creates a different threat model, that is not very attractive for the current stage.

Below considers this design.

# First step user-chosen relays

## Design requirements

1. To avoid increasing the complexity of self-hosting, we should not create additional server types, and existing SMP and XFTP servers should be extended to provide the 1st step relay functions.

2. SMP sending relay should not be able to observe queue addresses and their count on the destination relays.

3. There must be no identifiers and cyphertext in common in outgoing and incoming traffic in 1st step relays.

4. Traffic between the client and destination relays must be e2e encrypted, with MITM mitigated using server identity (certificate fingerprint), ideally without adding the additional fingerprint in destination relay address.

5. SMP sending relays should implement retry logic and hold messages while they are delivered. They also should push "sent" confirmation to the client. Question: does it mean the third tick? another kind of the first tick (or some other symbol) in the UX?

6. SMP sending relays may also increase utility and privacy of the platform:

- holding messages and retrying them for the new connections while the receiving queue is not secured yet.
- add delays in message delivery to make traffic correlation harder.

## Implementation considerations

1. Block size. It may be not enough spare capacity in the current 16kb block to fit additional headers, any necessary metadata and encryption authentication tags, in which case we cannot send SMP and SMP-proxy traffic in the same transport connection (in case the same server plays both roles). In which case we will need to negotiate socket role and define a different sub-protocol for SMP-proxy.

2. To be decided if we see it as extension of SMP protocol or as another protocol, irrespective of whether it's provided by the same or another server. Given different roles and block size it may be simpler to see it as a separate protocol, and which protocol is provided in the connection is determined during handshake.

3. We probably should aim to avoid changing agent/client logic and see it instead as transport concern that can be dynamically decided at a point of sending a message or command, based on the current configuration.

## SMP-proxy protocol

The flow of the messages will be:

1. Client requests proxy to create session with the relay by sending `server` command with the SMP relay address and optional proxy basic AUTH (below).

2. Proxy connects to SMP relay, negotiating a shared secret in the handshake that will be used to encrypt all sender blocks inside TLS. SMP relay also returns in handshake its temporary DH key to agree e2e encryption with the client.

3. Proxy replies with `server_id` command including relay session ID to identify it in further requests, relay DH key for e2e encryption with the client - this key is signed with the TLS online private key associated with the certificate (its fingerprint is included in the relay address), and the TLS session ID between proxy and relay (this session ID must be used in transmissions, to mitigate replay attacks as before).

A possible attack here is that proxy can use this TLS session to replay commands received from the client. Possibly, it could be mitigated with a bloom filter per proxy/SMP relay connection that would reject the repeated DH keys (that need to be used for replay), and also with DH key expiration (this mitigation should allow some acceptable rate of false positives from the bloom filter).

With 32 bits per key there will be ~1/1,000,000 false positives (see https://en.wikipedia.org/wiki/Bloom_filter), and the filter will use 32mb per each proxy connection if we reset relay key every 1000000 messages or more frequently. Given that the only commands accepted via relay would be SEND, replaying it would be interpreted by the receiving client as duplicate message delivery, so a small number of replayed messages won't cause any problems. But without mitigation it could be used to flood the receiving SMP relay queues with repeated messages, effectively causing DoS on these queues, even in case when SMP relays require basic auth to create queues.

Given that the client chooses proxy it has some trust to, maybe this replay attack risk can be accepted.

4. Now the client sends "forward" to proxy, which it then forwards to SMP relay, applying additional encryption layer, to mitigate traffic correlation inside TLS.

5. SMP replay sends "response" to proxy applying additional encryption layer, which it then forwards to the client removing this additional layer.

Effectively it works as a simplified two hop onion routing with the first relay chosen by the sending client and the second relay chosen by the recipient, not only protecting senders' IP addresses from the recipients' relays, but also preventing recipients relays from correlating senders traffic to different queues, as session is owned by the proxy now. To correlate traffic to sending users, proxy and relay will have to combine their information now. SMP relays are still able to correlate traffic to receiving users via transport session (mitigated by transport isolation).

Sequence diagram for sending the message via SMP proxy:

```
-------------               -------------                     -------------              -------------
|  sending  |               |    SMP    |                     |    SMP    |              | receiving |
|  client   |               |   proxy   |                     |   relay   |              |  client   |
-------------               -------------                     -------------              -------------
     |       `server`             |                                 |                          |
     | -------------------------> |    create session, get keys     |                          |
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
     | <------------------------- |                                 | TLS(r2c(MSG(e2e(msg))))  |
     |                            |                                 | -----------------------> |
     |                            |                                 |                          |
     |                            |                                 |        TLS(ACK)          |
     |                            |                                 | <----------------------- |
     |                            |                                 |                          |
     |                            |                                 |                          |

```

Below diagram shows the encrypttion layers for `forward` and `response` commands:

s2r (added) - encryption between client and SMP relay, with relay key returned in server_id command, with MITM by proxy mitigated by verifying the certificate fingerprint included in the relay address.
e2e (exists now) - end-to-end encryption per SMP queue, with double ratchet e2e encryption inside it.
p2r (added) - additional encryption between proxy and SMP relay with key agreed in the handshake, to mitigate traffic correlation inside TLS. This key could also be signed by the same certificate, if we don't want to rely on TLS security.
r2c (exists now) additional encryption between SMP relay and client to prevent traffic correlation inside TLS.

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

Alternatively, `server` command may trigger connection to the relay and request it's public DH key that would be signed with the certificate which fingerprint is already included in the address, and server_id response would contain this key. This would allow relays rotating the keys used to encrypt traffic, providing the forward secrecy.

When proxy connects to SMP relay it would indicate that in the handshake and the SMP relay would expect the same `forward` command and reply with `response`.

Below syntax aims to fit in 16kb block using spare capacity in SMP protocol.

```abnf
proxy_block = padded(proxy_transmission, 16384)
proxy_transmission = corr_id relay_session_id proxy_command
corr_id = length *8 OCTET
proxy_command = server / server_id / forward / response / error
server = "s" address [relay_basic_auth] ; creates transport session between proxy and relay
server_id = "i" relay_session_id tls_session_id signed_relay_key ;
    ; session_id is the TLS session ID between proxy and relay, it has to be included inside encrypted block to prevent replay attacks
forward_client = %s"F" random_dh_pub_key encrypted_block
forward_proxy = %s"F" random_dh_pub_key proxy_encrypted_block
response_to_proxy = %s"R" relay_encrypted_block; response received from the destination SMP relay
response_to_client = %s"R" encrypted_block; response received from the destination SMP relay
relay_session_id = length *8 OCTET
error = %s"E" error
```

The overhead is: 1+8 (corrId) + 1+8 (relay_session_id) + 1 (command) + 1+32 (random_dh_pub_key) + 2 (original length) + 16 (auth tag for e2e encryption) + 16 (auth tag for proxy to relay encryption) = 86 bytes. The reserve for sent messages in SMP is ~84 bytes, so it might fit if we find missing 2 bytes somewhere.

Another possible design is to allow mixing sent messages and normal SMP commands in the same transport connection, but it can make fitting in the block harder though.

Additional overhead would be: 1 (transmission count) + 2 (transmission size) + 1 (empty signature)

The above assumes that the client can only send one message to an SMP relay and then has to wait for response before sending the next message. Missing the response would cause re-delivery (further improvement is possible when proxy detects these redelieveries and does not send them to relays).
