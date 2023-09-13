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

6. SMP sending relays may also increase utility of the platform by allowing:

- schedule sending messages.
- holding messages and retrying them for the new connections while the receiving queue is not secured yet.

## Implementation considerations

1. Block size. It may be not enough spare capacity in the current 16kb block to fit additional headers, any necessary metadata and encryption authentication tags, in which case we cannot send SMP and SMP-proxy traffic in the same transport connection (in case the same server plays both roles). In which case we will need to negotiate socket role and define a different sub-protocol for SMP-proxy.

2. To be decided if we see it as extension of SMP protocol or as another protocol, irrespective of whether it's provided by the same or another server. Given different roles and block size it may be simpler to see it as a separate protocol, and which protocol is provided in the connection is determined during handshake.

3. We probably should aim to avoid changing agent/client logic and see it instead as transport concern that can be dynamically decided at a point of sending a message or command, based on the current configuration.

## SMP-proxy protocol: forward block to the destination relay

The below assumes that some public key of the destination relay is included in its address.

Alternatively, `server` command may trigger connection to the relay and request it's public DH key that would be signed with the certificate which fingerprint is already included in the address, and server_id response would contain this key. This would allow relays rotating the keys used to encrypt traffic, providing the forward secrecy.

When proxy connects to SMP relay it would indicate that in the handshake and the SMP relay would expect the same `forward` command and reply with `response`.

Below syntax aims to fit in 16kb block as we do have spare capacity in SMP encoding, but we separate destination relay "registration" to achieve it.

```abnf
proxy_block = padded(proxy_transmission, 16384)
proxy_transmission = corr_id relay_id proxy_command
corr_id = length *8 OCTET
proxy_command = server / server_id / forward / response / error
server = "S" address [basic_auth] ; register relay, allows to optionally prevent unauthorised usage
server_id = "I" relay_id [relay_key] [expiration] ; server IDs can expire
forward = %s"F" [acknowledge_corr_id] random_dh_pub_key encrypted_block
response = %s"R" destination_id random_dh_pub_key encrypted_block; response received from the destination SMP relay
check = %s"C"
    ; check the status of sending to some relay in case there were no response – the response would be either `response` or `error`
acknowledge_corr_id = length *8 OCTET ; the last correlation ID the client received response to
relay_id = 4*4 OCTET
destination_id = length *32 OCTET
length = OCTET
error = %s"E" error
```

The overhead is: 1+8 (corrId) + 1 (command) + 1+8 (acknowledge_corr_id) 4 (relayId) + 1+32 (destinationId) + 2 (original length) + 16 (auth tag) = 74 bytes. The reserve for sent messages in SMP is ~84 bytes, so it should fit, barely.

The above assumes that the client can send multiple messages to the same queue without waiting for confirmations they were sent. That requires some capacity/limits management. It also requires holding unconfirmed responses (they will be confirmed via acknowledge_corr_id, assuming they are increasing, so one forward can confirm multiple responses). 

A possible alternative is to reject additional forwards until the first is sent and process forward as a confirmation of receiving `response` by the client, so it will be removed from the proxy.

Unsolved problems:

1. How to prevent correlation of destination IDs, so that proxy cannot observe how many queues the client has on a destination relay. E.g. some way to generate different destination IDs for the same queue that would be recognised by the destination relay but not by the proxy. Possibly, relay would have to include a public key in its address so that the client can encrypt destination ID and include a random public key used to compute DH secret in each block.
