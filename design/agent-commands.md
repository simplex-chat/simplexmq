# SMP agent commands (Duplex protocol commands) 

This document describes Duplex commands flow through SMP agent components (see *design/agent.gv*), as well as some interactions between [recipient and sender](#Recipient-and-sender-terminology) clients, clients' SMP agents and SMP servers, and sequencing of Duplex and SMP commands.

Legend:

- > Command flow through SMP agent in blockquotes

- **Q - Design and other questions in bold**

## Table of contents

- [Recipient and sender terminology](#Recipient-and-sender-terminology)
- [Agent design comparison](#agent-design-comparison)
- [Communication between user client and client-side SMP agent](#Communication-between-user-client-and-client-side-SMP-agent)
  - [User client commands](#User-client-commands)
    - [`create`](#create)
    - [`join`](#join)
    - [`accept`](#accept)
    - [`subscribe`](#subscribe)
    - [`getStatus`](#getStatus)
    - [`send`](#send)
    - [`acknowledge`](#acknowledge)
    - [`suspend`](#suspend)
    - [`delete`](#delete)
  - [Agent messages to user client](#Agent-messages-to-user-client)
    - [`connection`](#connection)
    - [`connectionInvitation`](#connectionInvitation)
    - [`confirmation`](#confirmation)
    - [`message`](#message)
    - [`unsubscribed`](#unsubscribed)
    - [`queueStatus`](#queueStatus)
    - [`ok`](#ok)
    - [`error`](#error)
- [Communication between SMP agents](#Communication-between-SMP-agents)
  - [`helloMsg`](#helloMsg)
  - [`replyQueueMsg`](#replyQueueMsg)
  - [`deleteQueueMsg`](#deleteQueueMsg)
  - [`clientMsg`](#clientMsg)
  - [`acknowledgeMsg`](#acknowledgeMsg)
- [General questions](#General-questions)

## Recipient and sender terminology

Here and further recipient is referred to the side that initiates the connection, i.e. creates the initial SMP queue and sends an out-of-band invitation to the sender. Sender is referred to the side that joins this SMP queue through the out-of-band invitation and then creates another SMP queue in the opposite direction for the recipient. This is to distinguish the sides for commands that imply specific direction, conceptually in Duplex connection once connection is established both sides act both as a recipient and a sender through different SMP queues.

## Agent design comparison

| Option | Pros | Cons |
| ------ | ---- | ---- | 
| agent.gv | one TCP connection to a specific SMP server host is re-used by multiple users. | responses from the same server to multiple users are mixed and have to be correlated not only with commands but with the users as well, this correlation is not present in the design yet |
| agent2.gv | easier correlation of commands with responses, clear separation of internal user agent API (TBQueues) from TCP api (although this can be done with the first design as well) | if there are multiple users, there may be multiple TCP connections to the same SMP host |

## Communication between user client and client-side SMP agent

### User client commands

#### `create`

🚧 **To be fixed according to agent2.gv**

Requests recipient SMP server to create a new SMP queue. 

Is made by the [recipient](#Recipient-and-sender-terminology).

> recipient user client -> user agent TCP socket (main socket) -> runUser thread -> create user connection group (socket and threads) -> user connection group "user" thread -> agent server commands queue -> runServer thread -> SMP `create` command sent to server connection group "send" queue -> server connection group "send" thread -> SMP server connection TCP socket -> recipient's SMP server

- SMP Server then responds with SMP `queueIds` command to SMP server connection TCP socket
- Recipient agent gets automatically subscribed to receive the messages from the queue
- Agent replies to user client with Duplex [`connectionInvitation`](#connectionInvitation) command
- User sends connection invitation out-of-band to sender

- **Q - Shouldn't user connection group be created after server responds, or even after sender joins and invites back?**

  A - Agent has to correlate commands with responses anyway (replying on the fact that responses arrive in the same order that the commands were sent, occasionally interleaved with messages), so all the information needed to create the connection will be available in the command buffer anyway. It is probably better to create connection in the agent after the queue was successfully created in the server, and send an error to the user if SMP server responded with error.

- **Q - How does flow go from runUser thread to user connection group "user" thread? Does runUser pass the the initial `create` command further to "user" thread through socket?**

  A - runUser does not receive any TCP traffic other than initial TCP handshake, when it does it forks all user group threads. It does not participate in commands/messages flow. Commands go from "user" to "runServer" (via TBQueue), responses,messages and acknowledgements (see protocol changes) from "message subscriber" to "send" (via TBQueue)

- **Q - Does sender agent persist partial info about connection record at this point, or only when receives an opposing queue from the sender?**

  A - Yes, it should create connection with one queue (status "PENDING"), the status of the second queue will be "NONE" - see sequence diagram. In types it is `Maybe ConnState` with "NONE" corresponding to `Nothing`, as we don't need to have the second queue record. Also, protocol allows not to have reply queue, so the connection can remain unidirectional.

- **Q - Shouldn't agent at this point answer with Duplex [`connection`](#connection) command? SMP agent commands have conflicting comments in the Duplex protocol. What is that command used for at all at this point?**

  A - There is no need to split creating connection and creating the invitation - it was initially two commands, and now it's merged into one - it creates the queue on SMP server, connection record in the agent and the invitation string to be sent out-of-band to the other party - need to fix any contradictions.

#### `join`

🚧 **To be fixed according to agent2.gv**

Replies via out-of-band invitation with sender's key and profile.

Is made by the [sender](#Recipient-and-sender-terminology).

> sender user client -> user agent TCP socket (main socket) -> runUser thread -> create user connection group (socket and threads) -> user connection group "user" thread -> agent server commands queue -> runServer thread -> SMP `send` command sent to server connection group "send" queue, it contains sender's key and profile wrapped in Duplex [`clientMsg`](#clientMsg) command -> server connection group "send" thread -> SMP server connection TCP socket -> recipient's SMP server

- SMP server then delivers sender's message containing key and profile to recipient SMP agent with SMP `message` command
- Recipient agent secures previously created queue with Duplex [`accept`](#accept) command

#### `accept`

🚧 **To be fixed according to agent2.gv**

Secures SMP queue with sender's key.

Is made by the [recipient](#Recipient-and-sender-terminology).

> recipient user client -> user connection TCP socket -> user connection group "user" thread -> agent server commands queue -> runServer thread -> SMP `secure` command sent to server connection group "send" queue -> server connection group "send" thread -> SMP server connection TCP socket -> recipient's SMP server

- Sender's agent at this point repeatedly sends Duplex [`helloMsg`](#helloMsg) command to the recipient SMP server, which should be successful once sender queue is secured by the recipient agent with key provided by the sender in the Duplex [`join`](#join) command
- **Q - Does this command go through user agent TCP socket (main socket)? This relates to the question whether user connection groups for the recipient agent should be created during Duplex [`create`](#create) command**

  A - User connection group is created during TCP handshake.

#### `subscribe`

Subscribes/unsubscribes user to/from SMP queue.

> agent client -> user connection TCP socket -> "user receive" thread -> user receive TBQueue -> "process commands" thread -> \*
>
> \* -> commands TBQueue -> client thread; client thread is blocked until receives answer from SMP server -> \#
>
> \* -> srv snd TBQueue -> "server send" thread -> `subscribe` SMP command is sent through SMP client connection TCP socket -> SMP server responds with first available message or if there is none with SMP `ok` command back to SMP client connection TCP socket -> "server receive" thread -> srv rcv TBQueue -> client thread; client thread becomes unblocked -> \#
>
> \# -> user SMP TBQueue -> "process responses" thread -> queue is persisted as Disabled -> Duplex [`ok`](#ok) command sent to user send TBQueue -> "user send" thread -> user connection TCP socket -> agent client

- **Q - Which SMP command is sent to the SMP server on Duplex `subscribe Off`?**

  A -

#### `getStatus`

#### `send`

#### `acknowledge`

#### `suspend`

#### `delete`

### Agent messages to user client

TODO

#### `connection`

#### `connectionInvitation`

#### `confirmation`

#### `message`

#### `unsubscribed`

#### `queueStatus`

#### `ok`

#### `error`

## Communication between SMP agents

TODO

#### `helloMsg`

#### `replyQueueMsg`

#### `deleteQueueMsg`

#### `clientMsg`

#### `acknowledgeMsg`

## General questions

- **Q - When does agent set up server connection groups?**

  A - When it sees the new hostname:port combination - see the map of servers inside [AgentClient](https://github.com/simplex-chat/simplex-messaging/blob/client/src/Simplex/Messaging/Agent/Env.hs#L33)

- **Q - Replace command keywords with command names in the Duplex protocol sequence diagram?**

  A - Let's keep keywords, I also use them as constructors in code, they are part of the actual command syntax.
