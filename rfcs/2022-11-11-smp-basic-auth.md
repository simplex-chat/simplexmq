# SMP Basic Auth

## Problem

Users who host their own servers do not want unknown people to be able to create messaging queues on their servers after discovering server address in groups or after making a connection. As the number of self-hosted servers is growing it became more important than it was when we excluded it from the original design.

## Solution

Single access password that can be optionally included in server address that is passed to app configuration. It will not be allowed in the existing contexts (and parsing will fail), to avoid accidentally leaking it. Server address with password will look this way: `smp://fingerprint:password@hosts`

## Implementation plan

1. A separate type to include server and password, so it can only be used where allowed.

2. Server password to create queues will be configured in TRANSPORT section of INI file, as `create_password` parameter.

3. The password will only be required in server configuration/address to create queues only, it won't be required for other receiving queue operations on already existing queues.

4. If new command is attempted in the session that does not allow creating queues, the server will send `ERR AUTH` response

5. Passing password to the server can be done in one of the several ways, we need to decide:

  - as a parameter of NEW command. Pros: a local change, that only needs checking when queue is created. Cons: protocol version change.
  - as a separate command AUTH. Pros: allows to include additional parameters and potentially be extended beyond basic auth. Cons: more complex to manage server state, can be more difficult syntax in the future, if extended.
  - as part of handshake (we currently ignore the unparsed part of handshake block, so it can be extended). Pros: probably, the simplest, and independent of the commands protocol – establishes create permission for the current session. Cons: the client won't know about whether it is able to create the queue until it tries (same as in case 1).

  My preference is the last option. As a variant of the last option, we can add a server response/message that includes permission to create queues - it will only be sent to the clients who pass credential in handshake - that might simplify testing server connection (we currently do not do it). It might be unnecessary, as we could simply create and delete queue in case credential is passed as part of testing connection (and even sending a message to it).
