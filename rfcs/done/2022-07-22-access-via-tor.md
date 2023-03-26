# Accessing SMP servers via Tor

## Problem

While SMP protocol is focussed on minimizing application-level meta-data by using pair-wise identifiers instead of user profile identifiers, it is important for many users to protect their IP addresses.

Further, even if IP addresses are hidden by onion routing, clients should be able to choose to use a separate TCP connection to subscribe to each queue, even though it increases traffic and battery consumption, as otherwise the servers can observe multiple queues accessed by the same client.

## Solution and requirements

While some users may want to access SMP servers via tor, some other users (even their contacts) may want the opposite - e.g., if they use the network when accessing Tor would be suspicious (or blocked).

Therefore we need to support the connections when one of the user accesses the same server via Tor (and, possibly, via onion address), while another user accesses this server without Tor.

At the same time the user accessing the server via Tor may not want that their contacts access this server without Tor, and it also may be possible that the server is not available under a normal (not .onion) address.

The proposed options for connecting via Tor are:

1. Access servers via Socks proxy: no/yes (specify port?)
2. Use .onion addresses: no/when available/warn/always
3. Require senders to use .onion addresses: yes/no
4. Use separate TCP connection for each queue

While it should be possible for SMP servers to have two addresses (with and without Tor), the queues should only use one server address - if the queue started being accessed via .onion address it should not be possible to access it via a normal address. Queue addresses in connection invitations should support dual server addresses (when senders are not required ot use .onion address).

At the same time, the queue with the normal addresses can be accessed with and without Tor, depending on the current device settings.
