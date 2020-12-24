# SMP agent commands (Duplex protocol commands) 

This document describes Duplex commands flow through SMP agent components (see *design/agent.gv*), as well as some interactions between [recipient and sender](#Recipient-and-sender-terminology) clients, clients' SMP agents and SMP servers, and sequencing of Duplex and SMP commands.

Legend:

- > Command flow through SMP agent in blockquotes

- **Design and other questions in bold**

## Table of contents

- [Recipient and sender terminology](#Recipient-and-sender-terminology)
- [Communication between user client and client-side SMP agent](#Communication-between-user-client-and-client-side-SMP-agent)
  - [User client commands](#User-client-commands)
    - [`create`](#create)
    - [`join`](#join)
    - [`accept`](#accept)
    - [`subscribe`](#subscribe)
    - [`list`](#list)
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

## Communication between user client and client-side SMP agent

### User client commands

#### `create`

Requests recipient SMP server to create a new SMP queue. 

Is made by the [recipient](#Recipient-and-sender-terminology).

> recipient user client -> user agent TCP socket (main socket) -> runUser thread -> create user connection group (socket and threads) -> user connection group "user" thread -> agent server commands queue -> runServer thread -> SMP `create` command sent to server connection group "send" queue -> server connection group "send" thread -> SMP server connection TCP socket -> recipient's SMP server

- SMP Server then responds with SMP `queueIds` command to SMP server connection TCP socket
- Recipient agent gets automatically subscribed to receive the messages from the queue
- Agent replies to user client with Duplex [`connectionInvitation`](#connectionInvitation) command
- User sends connection invitation out-of-band to sender
- **Shouldn't user connection group be created after server responds, or even after sender joins and invites back?**
- **How does flow go from runUser thread to user connection group "user" thread? Does runUser pass the the initial `create` command further to "user" thread through socket?**
- **Does sender agent persist partial info about connection record at this point, or only when receives an opposing queue from the sender?**
- **Shouldn't agent at this point answer with Duplex [`connection`](#connection) command? SMP agent commands have conflicting comments in the Duplex protocol. What is that command used for at all at this point?**

#### `join`

Replies via out-of-band invitation with sender's key and profile.

Is made by the [sender](#Recipient-and-sender-terminology).

> sender user client -> user agent TCP socket (main socket) -> runUser thread -> create user connection group (socket and threads) -> user connection group "user" thread -> agent server commands queue -> runServer thread -> SMP `send` command sent to server connection group "send" queue, it contains sender's key and profile wrapped in Duplex [`clientMsg`](#clientMsg) command -> server connection group "send" thread -> SMP server connection TCP socket -> recipient's SMP server

- SMP server then delivers sender's message containing key and profile to recipient SMP agent with SMP `message` command
- Recipient agent secures previously created queue with Duplex [`accept`](#accept) command

#### `accept`

Secures SMP queue with sender's key.

Is made by the [recipient](#Recipient-and-sender-terminology).

> recipient user client -> user connection TCP socket -> user connection group "user" thread -> agent server commands queue -> runServer thread -> SMP `secure` command sent to server connection group "send" queue -> server connection group "send" thread -> SMP server connection TCP socket -> recipient's SMP server

- Sender's agent at this point repeatedly sends Duplex [`helloMsg`](#helloMsg) command to the recipient SMP server, which should be succeful once sender queue is secured by the recipient agent with key provided by the sender in the Duplex [`join`](#join) command
- **Does this command go through user agent TCP socket (main socket)? This relates to the question whether user connection groups for the recipient agent should be created during Duplex [`create`](#create) command**

#### `subscribe`

#### `list`

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

- **When does agent set up server connection groups?**
- **Replace command keywords with command names in the Duplex protocol sequence diagram?**
