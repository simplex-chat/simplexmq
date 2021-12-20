# 0.5.1

- Fix server subscription logic bug that was leading to memory leak / resource exhaustion in some edge cases.

# 0.5.0

- No changes in SMP server implementation - it is backwards compatible with v0.4.1
- SMP agent changes:
  - URI syntax for SMP queues and connection requests.
  - long-term connections links ("contacts") in SMP agent protocol.
  - agent command changes:
    - `REQ` notification and `ACPT` command are used only with long-term connection links.
    - `CONF` notification and `LET` commands are used for normal duplex connections.

# 0.4.1

- Include migrations in the package

# 0.4.0

- SMP server implementation and [SMP protocol](https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md) changes:
  - support 3072 bit RSA key size
  - add SMP queue quotas
  - set default transport block size to 4096 bits
  - allow SMP client to change transport block size during transport connection handshake
- SMP agent implementation and protocol changes:
  - additional connection confirmation step for initiating party
  - automatically resume subscribed duplex connections once transport connection is resumed
  - passing an arbitrary binary information between parties during the duplex connection handshake - can be used to identify parties
  - asynchronous duplex connection handshake - the parties do not have to be online at the same time
  - asynchronous message delivery - the agent does not need transport connection to accept client messages for delivery
  - additional confirmation of message reception from the client to prevent message loss in case of process termination
  - set transport block size to 8192 bits (in the future the agent protocol can allow to have different block sizes for different duplex connections)
  - added client commands and notifications (see [agent protocol](https://github.com/simplex-chat/simplexmq/blob/master/protocol/agent-protocol.md)):
    - `REQ` - the notification about joining party establishing connection
    - `ACPT` - the command to accept connection with the joining party
    - `INFO` - the notification with the information from the initiating party
    - `DOWN`/`UP` - the notifications about losing/resuming the connection
    - `ACK` - the command to confirm that the message reception/processing is complete
    - `MID` - the response to `SEND` confirming that the message is accepted by the agent
    - `MERR` - the notification about permanent message delivery error (e.g., `ERR AUTH` indicating that the queue was removed)

# 0.3.2

- Support websockets
- SMP server CLI commands

# 0.3.1

- Released to hackage.org
- SMP agent protocol changes:
  - move SMP server from agent commands NEW/JOIN to agent config
  - send CON to user only when the 1st party responds HELLO
- Fix REPLY vulnerability
- Fix transaction busy error

# 0.3.0

- SMP encrypted transport over TCP
- Standard X509/PKCS8 encoding for RSA keys
- Sign and verify agent messages
- Verify message integrity based on previous message hash and ID
- Prevent timing attack allowing to determine if queue exists
- Only allow correct RSA keys and signature sizes

# 0.2.0

- SMP client library
- SMP agent with E2E encryption

# 0.1.0

- SMP protocol server implementation without encryption
