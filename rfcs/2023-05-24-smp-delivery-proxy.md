# SMP and XFTP delivery relays

## Problem

SimpleX network relies on SMP relays to hold sent messages while the recipient is offline. This design provides many advantages over pure p2p designs [1]. The threat model for relays is covered in [2].

The problem with this design is that the relays are chosen by the recipients, and they as a result can be used to record transport addresses of the senders.

Similar problem, but reversed, exists with XFTP design - XFTP relays are chosen by the senders and also can be modified to record transport addresses of the recipients.

The current solution to this problem is to use onion routing to access relays, and many users do it already. The downside is that it requires additional configuration and can be complex to some users.

## Solution approach

Add a second type of relays to the network design.

For SMP protocol, these relays would accept messages from the senders and deliver them to the recipients. If the recipient were to modify the relay used to receive the messages to also records senders' IP addresses, then they would only succeed in recording the IP address of the relay, not the sender.

Similar relay can be introduced for XFTP protocol.

The additional advantage of using the relays is the reduced number of network connections that need to be used, and reduced traffic.

Compared with Tor this approach has:
- lower latency
- no centralized components or the registry of the servers
- still no visibility of the whole network to the relays, as sending relays do not need to randomly choose the next relay, but would forward the messages directly to the destination relay.

The downside of this approach is that relays will have more visibility of the network than in the current design.

## Implementation considerations

1. Should this new relays be included in the existing SMP and XFTP protocols and servers, or should they be designed as separate protocols and servers?

2. Should the client aim to choose the same host for delivery relay as the destination server (to reduce the traffic), if possible, or should it aim to choose a different host (to reduce metadata available to single host)? The answer to this would affect the answer to the first question.
