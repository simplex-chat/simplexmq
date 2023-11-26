# 5.4.0

Migrate to GHC 9.6.3

Agent:
- database improvements:
  - track slow queries.
  - better performance.
  - "busy" error handling.
  - create parent folder when needed.
  - support closing and re-opening database.
- SMP agent improvements
  - streaming for batched SMP commands.
  - fix asynchronous JOINing connection.
  - handle repeating JOINs without failure.
  - api to get subscribed connections.
  - return simplex:/ links as invitations.
  - fix memory leak.
- XFTP improvements:
  - suspend when agent is suspended.
  - support locally encrypted files.
  - fixes - create empty file, prevent permanent error treated as temporary.
  - upgrade HTTP2 library (fixes error handling and flow control).
- Remote control protocol (XRCP)

SMP server:
- control port commands for GHC threads introspection.
- allow creating new queues without subscriptions (required for iOS).

XFTP server:
- allow 64kb file chunks.

NTF server:
- faster startup.

# 5.3.0

Agent:
- improve performance, track slow database queries.
- support delivery receipts.

SMP server:
- control port

# 5.2.0 (NTF server 1.5.0)

Agent:
- treat agent INACTIVE error as temporary - fixes failed message delivery in some race conditions.
- restore connection confirmations after client restart - fixes failed connections.
- ratchet resynchronization protocol and API.
- increase connection version to mutually supported by both peers on each received message.

Client:
- make timeout for batched functions dependent on the number of batches - fixes expiry on large batches.

Servers:
- add timeout in case of sending TCP traffic and in case of partial delivery of requested blocks to avoid resource leaks.

# 5.1.2, 5.1.3 (NTF server 1.4.1, 1.4.2)

Agent:
- ACK message on decryption error (fixes stuck message delivery bug)
- more robust connection switching logic, API to abort switching the address

Notification server:
- batch subscriptions to SMP servers

# 5.1.1 (NTF server 1.4.0)

Agent:
- store and check hashes of previous encrypted messages to differentiate between duplicates and decryption errors

Server:
- larger processing queues
- expire messages when restoring them

# 5.1.0

XFTP client:
- check encrypted file exists when uploading
- remove user ID from deletion API

Agent:
- vacuum database on migrations

SMP server:
- configure message expiration time in INI file

# 5.0.0

SimpleX File Transfer Protocol (XFTP):
- XFTP server
- XFTP CLI
- support XFTP in the agent

Other changes:
- preserve retry interval for sending messages on agent restarts
- support IPv6 in the servers and in the agent
- support for 32-bit platforms

Read more about XFTP in this post: https://simplex.chat/blog/20230301-simplex-file-transfer-protocol.html

# 4.4.1

SMP agent:

- fix handling of server addresses.
- prevent message delivery getting stuck on IO error in SMP client.

# 4.4.0

SMP agent:

- support multiple user profiles with transport session isolation.
- support optional transport isolation per connection.
- batch connection deletion
- improve asynchronous connection deletion – it may now be completed after the client is restarted as well.
- improve subscription logic to retry if initial attempt fails.
- end SMP client connection after a number of failed PINGs (default is 3).

# 4.3.0

SMP server:

- additional server usage statistics.

SMP agent:

- increase retry interval when sending messages after ERR QUOTA.

# 4.2.0

SMP agent and server:

- reduce sender traffic in cases when queue quota is exceeded:
  - server sends quota exceeded message to the recipient when sender receives ERR QUOTA.
  - recipient sends QCONT message to the send once the queue is drained (via reply queue).
  - sender retry delays are increased, reducing traffic, but sender instantly resumes delivery where QCONT is received.

SMP server:

- increase internal queue sizes.

SMP agent:

- deduplicate connection IDs in connect/disconnect responses.
- unit tests for Crypto.hs.
- fix connection switch to another queue: correctly set primary send queue.

Notification server (v1.3.0):

- check token status when sending verification notification.

# 4.1.0

SMP agent and server:

- option to toggle TLS handshake error logs (disabled by default).

SMP agent:

- include server address in BROKER error.
- api to get hash of double ratchet associated data (for connection verification).
- api to get agent statistics.

# 4.0.0

SMP server:

- Basic authentication. The server address can now include an optional password that is required to create messaging queues, so the contacts who message you will not be able to receive messages via your server, unless you share with them the address with the password. It is recommended to enable basic authentication on all private servers by adding `create_password` parameter into AUTH section of server INI file (the previously deployed servers do not have this section, you need to add it).
- Disable creating new queues completely with `new_queues: off` parameter in AUTH section of INI file - it can be used to simplify migrating the existing connections to another server.
- Updated server CLI with changed defaults:
  - interactive server initialization, use -y flag to initialize the server non-interactively.
  - store log is now enabled by default, so messaging queues and messages are restored when the server is restarted (to restore undelivered messages the server needs to be stopped with SIGINT signal).
  - a random password is now generated by default during the server initialization.

SMP agent:

- API to test SMP servers. It connects to the server, creates and deletes a messaging queue. The new SimpleX Chat client uses this API to allow you to test that you have the correct server address, with the valid certificate fingerprint and password, before enabling the new server.

# 3.4.0

SMP agent:

- increase concurrency with connection-level locks
- fix issues identified in security assessment (see the announcement: https://github.com/simplex-chat/simplex-chat/blob/stable/blog/20221108-simplex-chat-v4.2-security-audit-new-website.md)
- manual connection queue rotation
- optional client data in connection requests links

SMP server:

- specialize monad stack to improve performance
- log slow commands

# 3.3.0

SMP server:

- allow repeated KEY command with the same key (to avoid failures on retries)

SMP agent:

- enable/disable connection notifications
- asynchronous commands that retry on network error
- use SQLCipher

# 3.2.0

SMP agent:

- Support multiple server hostnames (including onion hostnames) in server addresses.
- Network configuration options.
- Options to define rules to choose server hostname.

# 3.1.0

SMP server and agent:

- SMP protocol v4: batching multiple server commands/responses in a transport block.

# 3.0.0

SMP server:

- restore undelivered messages when the server is restarted.
- SMP protocol v3 to support push notification:
  - updated SEND and MSG to add message flags (for notification flag that confirm whether the notification is sent and for any future extensions) and to move message meta-data sent to the recipient into the encrypted envelope.
  - update NKEY and NID to add e2e encryption keys (for the notification meta-data encryption between SMP server and the client), and update NMSG to include this meta-data.
  - update ACK command to include message ID (to avoid acknowledging unprocessed message).
  - add NDEL commands to remove notification subscription credentials from SMP queue.
  - add GET command to receive messages without subscription - to be used in iOS notification service extension to receive messages without terminating app subscriptions.

SMP agent:

- new protocol for duplex connection handshake reducing traffic and connection time.
- support for SMP notifications server and managing device token.
- remove redundant FQDN validation from TLS handshake to prepare for access via Tor.
- support for fully stopping agent and for temporary suspending agent operations.
- improve management of duplicate message delivery.

SMP notifications server v1.0:

- SMP notifications protocol with version negotiation during handshake.
- device token registration and verification (via background notification).
- SMP notification subscriptions and push notifications via APNS.
- restoring notification subscriptions when the server is restarted.

# 2.3.0

SMP server:

- Save and restore undelivered messages, to avoid losing them. To save messages the server has to be stopped with SIGINT signal, if it is stopped with SIGTERM undelivered messages would not be saved.

# 2.2.0

SMP server:

- Fix sockets/threads/memory leak

SMP agent:

- Support stopping and resuming agent with `disconnectAgentClient` / `resumeAgentClient`

# 2.1.1

SMP server:

- gracefully close sockets on client disconnection
- CLI warning when deleting server configuration

# 2.1.0

SMP server:

- configuration to expire inactive clients in ini file, increased TTL and check interval for client expiration

# 2.0.0

Push notifications server (beta):

- supports APNS
- manage device tokens verification via notification delivery
- sending periodic background notification to check messages (not more frequent than every 20 min)

SMP server:

- disconnect inactive clients after some period
- remove undelivered messages after 30 days
- log aggregate usage daily stats: only the number of queues created/secured/deleted/used and messages sent/delivered is logged, as one line per day, so we can plan server capacity and diagnose any problems.

SMP agent:

- manage device tokens and notification server connection
- DOWN/UP events to the agent user about server disconnections/reconnections are now sent once per server

# 1.1.0

SMP server:

- message TTL and periodic deletion of old messages
- configuration to prevent creation of the new queues

SMP agent:

- asynchronous connection handshake
- configurable SMP servers at run-time
- use TCP keep-alive for connection stability
- improve stability of connection subscriptions
- auto-vacuum DB to remove deleted records

# 1.0.3

SMP server:

- Reduce server message queue quota to 128 messages.

SMP agent:

- Add "yes to migrations" option.
- Make new SMP client attempt to reconnect on network error.
- Reduce connection handshake expiration to 2 days.

JSON encoding of types used in simplex-chat, some other minor adjustments.

# 1.0.2

General:

- Enable TLS 1.3 parameters for TLS handshake (server and client).
- Switch from hs-tls fork to original repo now that it supports getFinished and getPeerFinished APIs for both TLS 1.2 and TLS 1.3.

SMP server:

- Perform TLS handshake in a separate thread per-connection.

SMP agent:

- Cease attempts to send HELLO after one week timeout.
- Coalesce requests to connect to SMP servers, to have 1 connection per server.

# 1.0.1

SMP server:

- Explicitly set line buffering in stdout/stderr to log each line when output is redirected to files.

# 1.0.0

Security and privacy improvements:

- Faster and more secure 2-layer E2E encryption with additional encryption layer between servers and recipients:
  - application messages in each duplex connection (managed by SMP agents - see [overview](https://github.com/simplex-chat/simplexmq/blob/master/protocol/overview-tjr.md)) are encrypted using [double-ratchet algorithm](https://www.signal.org/docs/specifications/doubleratchet/), providing forward secrecy and break-in recovery. This layer uses two Curve448 keys per client for [X3DH key agreement](https://www.signal.org/docs/specifications/x3dh/), SHA512 based HKDFs and AES-GCM AEAD encryption.
  - SMP client messages are additionally E2E encrypted in each SMP queue to avoid cipher-text correlation of messages sent via multiple redundant queues (that will be supported soon). This and the next layer use [NaCl crypto_box algorithm](https://nacl.cr.yp.to/index.html) with XSalsa20Poly1305 cipher and Curve25519 keys for DH key agreement.
  - Messages delivered from the servers to the recipients are additionally encrypted to avoid cipher-text correlation between sent and received messages.
- To prevent any traffic correlation by content size, SimpleX uses fixed transport block size of 16kb (16384 bytes) with padding on all encryption layers:
  - application messages are padded to 15788 bytes before E2E double-ratchet encryption.
  - messages between SMP clients are padded to 16032 bytes before E2E encryption in each SMP queue.
  - messages from the server to the recipient are padded to padded to 16088 bytes before the additional encryption layer (see above).
- TLS 1.2+ with tls-unique channel binding in each command to prevent replay attacks.
- Server identity verification via server offline certificate fingerprints included in SMP server addresses.

New functionality:

- Support for notification servers with new SMP commands: `NKEY`/`NID`, `NSUB`/`NMSG`.

Efficiency improvements:

- Binary protocol encodings to reduce overhead from circa 15% to approximately 3.7% of transmitted application message size, with only 2.2% overhead for SMP protocol messages.
- More performant cryptographic algorithms.

For more information about SimpleX:

- [SimpleX overview](https://github.com/simplex-chat/simplexmq/blob/master/protocol/overview-tjr.md).
- [SimpleX chat v1 announcement](https://github.com/simplex-chat/simplex-chat/blob/master/blog/20220112-simplex-chat-v1-released.md).

# 0.5.2

- Fix message delivery logic that blocked delivery of all server messages when server per-queue quota exceeded, making it concurrent per SMP queue, not per server.

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
