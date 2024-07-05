# Server configuration

## Problem

Currently SimpleX Chat allows maintaining the list of servers, some of which can be disabled. Only enabled servers are passed to the agent configuration.

With the recent evolution of SMP protocol and XFTP implementation to protect transport information, additional server taxonomy is required in the agent:

- Known servers: SMP proxy configuration allows to proxy messages only to unknown servers, and it treats enabled servers as known. It would be better to pass all known servers and use them as known, with the disabled servers not used for any new message queues.
- Server usage: with the different level of trust to SMP servers it may be helpful to differentiate the server roles - to use some only as proxies and some others only to receive messages (with the option proxy to all).
- Server operators: some threat model qualities are based on the assumption that servers do not collude. This would be a stronger guarantee if the servers used together in some communication scope were belonging to different operators (e.g. forward message to destinnation server, we could choose proxy belonging to a different operator from a destination server, also when creating reply queue it could be chosen from a different operator).

## Solution

Create KnownServer type in the agent and use it to pass the servers. Server choice will use this process:
- filter the servers with the allowed usage - if no server has allowed usage, operation would fail. It means that the list of servers has to be validated (both in the UI and during the agent initialization), or, possibly it can be enforced on type level with NonEmpty lists - we can pass a separate list for each operation. The types in code have separate lists.
- remove servers of the same operator, then if the list is not empty, randomly pick the server.
- if the list was empty, randomly pick different server. It means that when iterating servers in async commands we should separate the initial server and tried servers.

All servers operated by SimpleX Chat would be marked as known with some of them randomly chosen to be used during the first start.
