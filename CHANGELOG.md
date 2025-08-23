# 6.4.4

Servers:
- fix server pages when source code is not specified.
- include commit SHA in printed version and in web page (#1608).

SMP server:
- support short SimpleX addresses in server information page (#1600).
- wrap all queries in transactions (#1603).

SMP agent:
- chat relay address type for short links (#1602).
- extend xrcp certificate validity 1 hour in the past, to allow out of sync clocks (#1601).

# 6.4.3

SMP agent:
- fix some connection errors by updating contact request server hosts to match server in short link (#1597).

SMP server:
- support short link URI as queue identifier in control port commands (#1596).

# 6.4.2

SMP server:
- fix memory leak when connection interrupts straight after client connects.
- do not include repeated queue blocking into stats/quota.

XFTP server:
- prometheus metrics

# 6.4.1

SMP protocol:
- create notification credentials via NEW command that creates the queue (#1586)

SMP server:
- control port session improvements (#1591)
- additional stat counter for ntf credentials created together with the queue (#1589)

# 6.4.0

SMP protocol (server/client):
- support associated queue data and short connection links (see [RFC](./rfcs/2025-03-16-smp-queues.md)).
- service certificates to optimize subscriptions.

SMP agent:
- support retries for interactive connection handshakes.
- use web port 443 by default for preset servers.
- use static RNG function to avoid creating dynamic C stubs when generating sntrup keys (it was detected as Dynamic Code Loading in GrapheneOS).
- different timeouts for interactive and background operations.

Ntf server:
- PostgreSQL storage.
- Prometheus metrics.
- use service certificates.
- fix repeat token registration.

# 6.3.2

Servers:
- enable store log by default (#1501).

SMP server:
- reduce memory usage (#1498)

SMP agent:
- handle client/agent version downgrades after connection was established (#1508).

# 6.3.1

Servers:
- handle ECONNABORTED error on client connections.
- reproducible builds.
- blocking records for content moderation.
- update script (simplex-servers-update) downloads scripts from the specified or the latest stable tag.

SMP server:
- support for PostgreSQL database for queue records for higher traffic servers.
- fix old clients sending messages to new servers (#1443)
- remove empty journals when opening message queues and expiring idle queues (#1456, #1458).
- additional start options (#1465):
  - `maintenance` to run all start/stop operations without starting server.
  - `skip-warnings` to ignore the last corrupted line in store log (can happen on abnormal termination).

Ntf server:
- record date of last token activity, to allow expiring inactive tokens.
- additional token invalidation reasons in logs.

SMP agent:
- store message sent to multiple connections only once, to reduce storage when sending to groups (#1453).
- encrypt messages on delivery, to reduce database writes (#1446).
- don't block method calls on congested sockets for better concurrency (#1454).
- check notification token status on client connection.
- option to skip SQLite vacuum on migrations.

# 6.3.0

SMP agent: fix joining connection after failure by using the same ratchet.

# 6.2.2

SMP server:
- add optional Prometheus metrics (#1411).

Build:
- remove three modules from client library.

# 6.2.0

Version 6.2.0.7

Build:
- client_library flag to build only used modules in the clients, remove package yaml

SMP server:
- journal storage for messages (BETA).
- prevent race condition when deleting queue and to avoid "orphan" messages (#1395).

SMP agent:
- support SMP and XFTP server roles (storage/proxy) and operators (#1343).
- treat blocked STM and other critical errors that offer restart as temporary for message delivery (#1405).
- fix inconsistent state after app restart while accepting contact request (#1412).

# 6.1.3

SMP server: fix restoring notification credentials.

# 6.1.2

Servers: more reliable restoring of state.

SMP server: reduced memory usage and faster start.

Notifications: compensate for iOS notifications being dropped by Apple while device is offline (#1378):
- Ntf server: send multiple SMP notifications in one iOS notification.
- Agent: get multiple messages for one iOS notification.

# 6.1.1

SMP:
- stop server faster (#1371)
- add STORE error (#1372)

# 6.1.0

Version 6.1.0.7

SMP server and client:
- transport block encryption (#1317).

Agent:
- batch and optimize iOS notifications processing (#1308, #1311, #1313, #1316, #1330, #1331, #1333, #1337, #1346).
- allow receiving multiple messages from single iOS notification (#1355, #1362).
- prepare connection to accept to avoid race condition with events (#1365).
- transport isolation mode "Session" (default) to use new SOCKS credentials when client restarts or SOCKS proxy configuration changes (#1321).

Ntf server:
- control port (#1354).
- enable pings on ntf subscriptions, to resubscribe on reconnection (#1353).

SMP server:
- support multiple server ports (#1319).
- support serving HTTPS and SMP transport on the same port (#1326, #1327).
- persist iOS notifications to avoid losing them when Ntf server is offline (#1336, #1339, #1350).
- fix lost notification subscriptions (#1347).
- reject SKEY with different key earlier, at verification step (#1366).
- pass server information via CLI during server initialization (#1356).
- show version on server page (#1341).
- explicit graceful shutdown on SIGINT (#1360).

XRCP (remote access protocol):
- use SHA3-256 in hybrid key agreement (#1302).
- session encryption with forward secrecy (#1328).

# 6.0.5

SMP agent:
- support generic SOCKS proxy (without isolate-by-auth).
- reduce max message sizes

# 6.0.4

SMP server:
- better performance/memory: fewer map updates on re-subscriptions (#1297), split and reduce STM transactions (#1294)
- send DELD when subscribed queue is deleted (#1312)
- add created/updated/used date to queues to manage expiration (#1306)

XFTP server: truncate file creation time to 1 hour (#1310)

Servers:
- bind control port only to 127.0.0.1 for better security in case of firewall misconfiguration (#1280)
- reduce memory used for period stats (#1298)

Agent: process last notification from list (#1307)
- report receive file error with redirected file ID, when redirect is present (#1304)
- special error when deleted user record is not in database (#1303)
- fix race when sending a message to the deleted connection (#1296)
- support for multiple messages in a single notification

Ntf server:
- only use SOCKS proxy for servers without public address (#1314)

# 6.0.3

Agent:
- fix possible stuck queue rotation (#1290).

SMP server:
- batch END responses when subscribed client switches to reduce server and client traffic.
- reduce STM transactions for better performance.
- add stats for END events and for SUB/DEL event batches.
- remove "expensive" stats to save memory.

# 6.0.2

SMP agent:
- fix stuck connection commands when a server is not responding.
- store query errors, reduce slow query threshold to 1ms.

Notification server:
- reduce PING interval to 1 minute.
- fix subscriptions disabled on race condition (only mark subscriptions with END status when received via the active connection).

# 6.0.1

SMP agent:
- support changing user of the new connection.
- do not start delivery workers when there are no messages to deliver.
- enable notifications for all connections.
- combine database transactions when subscribing.

SMP server:
- safe compacting of store log.
- fix possible race when creating client that might lead to memory leak.

Dependencies: upgrade tls to 1.9

# 6.0.0

Version 6.0.0.8

Agent:
- enabled fast handshake support.
- batch-send multiple messages in each connection.
- resume subscriptions as soon as agent moves to foreground or as network connection resumes.
- "known" servers to determine whether to use SMP proxy.
- retry on SMP proxy NO_SESSION error.
- fixes to notification subscriptions.
- persistent server statistics.
- better concurrency.

SMP server:
- reduce threads usage.
- additional statistics.
- improve disabling inactive clients.
- additional control port commands for monitoring.

Notification server:
- support onion-only SMP servers.

# 5.8.2

Agent:
- fast handshake support (disabled).
- new statistics api.

SMP server:
- fast handshake support (SKEY command).
- minor changes to reduce memory usage.

# 5.8.1

Agent:
- API to reconnect one server.
- Better error handling of file errors and remote control connection errors.
- Only start uploading file once all chunks were registered on the servers.

SMP server:
- additional stats for sent message notifications.
- fix server page layout.

# 5.8.0

Version 5.8.0.10

SMP server and client:
- protocol extension to forward messages to the destination servers, to protect sending client IP address and transport session.

Agent:
- process timed out subscription responses to reduce the number of resubscriptions.
- avoid sending messages and commands when waiting for response timed out (except batched SUB and DEL commands).
- fix issue with stuck message reception on slow connection (when response to ACK timed out, and the new message was not processed until resubscribed).
- fix issue when temporary file sending or receiving error was treated as permanent.

SMP server:
- include OK responses to all batched SUB requests to reduce subscription timeouts.

XFTP server:
- report file upload timeout as TIMEOUT, to avoid delivery failure.

# 5.7.6

XFTP agent:
- treat XFTP handshake timeouts and network errors as temporary, to retry file operations.

# 5.7.5

SMP agent:
- fail if non-unique connection IDs are passed to sendMessages (to prevent client errors and deadlocks).

# 5.7.4

SMP agent:
- remove re-subscription timeouts (as they are tracked per operation, and could cause failed subscriptions).
- reconnect XFTP clients when network settings changes.
- fix lock contention resulting in stuck subscriptions on network change.

# 5.7.3

SMP/NTF protocol:
- add ALPN for handshake version negotiation, similar to XFTP (to preserve backwards compatibility with the old clients).
- upgrade clients to versions v7/v2 of the protocols.

SMP server:
- faster responses to subscription requests.

XFTP client:
- fix network exception during file download treated as permanent file error.

SMP agent:
- do not report subscription timeouts while client is offline.

# 5.7.2

SMP agent:
- fix connections failing when connecting via link due to race condition on slow network.
- remove concurrency limit when waiting for connection subscription.
- remove TLS timeout.

# 5.7.1

SMP agent:
- increase timeout for TLS connection via SOCKS

# 5.7.0

Version 5.7.0.4

_Please note_: the earliest SimpleX Chat clients supported by this version of the servers is 5.5.3 (released on February 11, 2024).

SMP server:
- increase max SMP protocol version to 7 (support for deniable authenticators).

NTF server:
- increase max NTF protocol version to 2 (support for deniable authenticators).

XFTP server:
- version handshake using ALPN.

SMP agent:
- increase timeouts for XFTP files.
- don't send commands after timeout.
- PQ encryption support.

# 5.6.2

Version 5.6.2.2.

SMP agent:
- Lower memory consumption (~20-25%).
- More stable XFTP file uploads and downloads.
- API to receive network connectivity changes from the apps.
- to reduce battery consumption: connection attempts interval growing to every 2 hours when app reports as offline.
- to reduce retries and traffic: 50% increased timeouts when on mobile network.

XFTP server:
- expire files on start.
- version negotiation based on TLS ALPN and handshake.

NTF server:
- reduced downtime by ~100x faster start time.
- exclude test tokens from statistics.

# 5.6.1

Version 5.6.1.0.

- Much faster iOS notification server start time (fewer skipped notifications).
- Fix SMP server stored message stats.
- Prevent overwriting uploaded XFTP files with subsequent upload attempts.
- Faster base64 encoding/parsing.
- Control port audit log and authentication.

# 5.6.0

Version 5.6.0.4.

SMP protocol/client/server:
- support deniable sender command authorization (to be enabled in the next version).
- remove support for SMP protocol versions (prior to v4, 07/2022).

Agent:
- optional post-quantum key agreement using sntrup761 in double ratchet protocol.
- improve performance of deleting multiple connections and files by batching database operations.
- delay connection deletion to deliver pending messages.
- API to test for notifications server.
- remove support for client protocols versions (prior to 10/2022).

XFTP server:
- restore storage quota in case of failed uploads.

Performance and stability improvements.

# 5.5.3

Agent:
- notification token API also returns active notifications server.
- support file descriptions with redirection and file URIs.

Servers:
- CLI commands for online key and certificate rotation.
- Configure config and log paths via environment variables.

# 5.5.2

Extensible handshake for clients and SMP/NTF servers (ignore extra data).

# 5.5.1

SMP servers:
- do not keep stats file open
- additional stats about currently stored messages

Agent:
- support multiple notification servers (only one can be used at a time).
- expire messages after "quota exceeded" error after 7 days (instead of 21 days previously).
- stabilize message delivery, remove unnecessary subscription retries and traffic.
- improve database performance for message delivery.
- fix sockets/memory leak - a very old bug "activated" by improvements in v5.5.0.

# 5.5.0

Code:
- compatible with GHC 8.10.7 to support compilation for armv7a.
- migrate to `crypton` from deprecated `cryptonite` (the seed for DRG is now sha512-hashed).
- use ChaChaDRG for all random IDs, keys and nonces, only using hashed entropy as seed.
- more efficient transaction batching in SMP protocol client and server.

Agent:
- stabilize message reception and delivery, migrate message delivery to database queue.
- additional event MSGNTF confirming that message received via notification is processed.
- efficient processing of messages sent to multiple recipients with batched database transactions.
- new worker abstraction for all queued tasks resilient to race conditions and some database errors.
- many fixed race conditions.
- background mode for iOS NSE.
- additional error reporting to client on critical errors (to be show as alert in the clients).
- functional api to get worker statistics.

SMP/XFTP servers:
- fix socket and memory leak on servers with high load (inactive clients without subscriptions are disconnected after set time of inactivity).
- control port improvements.
- fix statistics for stored queues, messages and files.
- make writing to store log atomic (fixes a rare bug in XFTP server).

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
