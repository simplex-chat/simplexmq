# simplex-messaging

[![GitHub build](https://github.com/simplex-chat/simplex-messaging/workflows/build/badge.svg)](https://github.com/simplex-chat/simplex-messaging/actions?query=workflow%3Abuild)
[![GitHub release](https://img.shields.io/github/v/release/simplex-chat/simplex-messaging)](https://github.com/simplex-chat/simplex-messaging/releases)

## How to run chat client locally

Install [Haskell platform](https://www.haskell.org/platform/) (ghc, cabal, stack) and build the project:

```shell
$ git clone git@github.com:simplex-chat/simplex-messaging.git
$ cd simplex-messaging
$ stack install
$ dog-food
```

`dog-food` starts chat client with default parameters. By default database file is created in the working directory, and default SMP server is smp.simplex.im.

To specify non default chat database location or server run:

```shell
$ mkdir ~/simplex
$ dog-food -d ~/simplex/smp-chat.db -s localhost:5223
```

Run `dog-food -h` to check available options and their default values.

### Using chat client

Once chat client is started, in chat REPL use `/add <name>` command to create a new connection and an invitation for your contact, and `/accept <name> <invitation>` command to join the connection via provided invitation.

For example, if Alice and Bob were to converse over SMP, with Alice initiating, Alice would run [in her chat client]:

```
/add bob
```

And send the generated invitation to Bob out-of-band, after receiving which Bob would run [in his chat client]:

```
/accept alice <alice's invitation>
```

They would then use `/chat <name>` commands to activate conversation with respective contact and `@<name> <message>` commands to send a message. One may also press Space or just start typing a message to send a message to the contact that was latest in the context.

To see the list of available commands and their explanation run `/help` in chat REPL.

Since SMP doesn't use global identity (so account information is managed by clients), you might want to preconfigure your name to use in invitations for your contacts:

```
/name alice
```

Now Alice's invitations would be generated with her name for Bob's and others' convenience.

## 🚧 [further README not up to date] SMP server demo 🏗

This is a demo implementation of SMP ([simplex messaging protocol](https://github.com/simplex-chat/protocol/blob/master/simplex-messaging.md)) server.

It has a very limited utility (if any) for real applications, as it lacks the following protocol features:

- cryptographic signature verification, instead it simply compares provided "signature" with stored "public key", effectively treating them as plain text passwords.
- there is no transport encryption

Because of these limitations, it is easy to experiment with the protocol logic via telnet.

You can either run it locally or try with the deployed demo server:

```bash
telnet smp.simplex.im 5223
```

## Run locally

[Install stack](https://docs.haskellstack.org/en/stable/install_and_upgrade/) and `stack run`.

## Usage example

Lines you should send are prefixed with `>` character, you should not type them.

Comments are prefixed with `--`, they are not part of transmissions.

`>` on its own means you need to press `return` - telnet should be configured to send it as CRLF.

1. Create simplex message queue:

```telnet
>
> abcd -- correlation ID, any string
>
> NEW 1234 -- 1234 is recipient's key

abcd

IDS QuCLU4YxgS7wcPFA YB4CCATREHkaQcEh -- recipient and sender IDs for the queue
```

2. Sender can send their "key" to the queue:

```telnet
> -- no signature (just press enter)
> bcda -- correlation ID, any string
> YB4CCATREHkaQcEh -- sender ID for the queue
> SEND :key abcd

bcda
YB4CCATREHkaQcEh
OK
```

3. Secure queue with sender's "key"

```telnet
> 1234 -- recipient's "signature" - same as "key" in the demo
> cdab
> QuCLU4YxgS7wcPFA -- recipient ID
> KEY abcd -- "key" provided by sender

cdab
QuCLU4YxgS7wcPFA
OK
```

4. Sender can now send messages to the queue

```telnet
> abcd -- sender's "signature" - same as "key" in the demo
> dabc -- correlation ID
> YB4CCATREHkaQcEh -- sender ID
> SEND :hello

dabc
YB4CCATREHkaQcEh
OK
```

5. Recipient recieves the message and acknowledges it to receive further messages

```telnet

-- no correlation ID for messages delivered without client command
QuCLU4YxgS7wcPFA
MSG ECA3w3ID 2020-10-18T20:19:36.874Z 5
hello
> 1234
> abcd
> QuCLU4YxgS7wcPFA
> ACK

abcd
QuCLU4YxgS7wcPFA
OK
```

## Design

![server design](design/server.svg)
