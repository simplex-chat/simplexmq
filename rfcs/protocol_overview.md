# Overview of SMP agent protocol commands

## Connections

### Commands and messages

A initiates connection, B accepts

- command `C idB? NEW` - create connection
- message `C idB INV cInv`
- command `C idA? JOIN cInv replyMode infoB` - join connection (response `OK`, followed by `CON`)
- *message* `C idB REQ prv:invId infoB` - request from B joining sent to A (not implemented)
- *command* `C idB LET prv:invId` - A confirms B joining (not implemented)
- message `C id CON` - connection is established
- command `C id SUB` - subscribe to connection
- message `C id END` - unsubscribed from connection
- command `C idB SEND msg` - send message
- message `C idA SENT msgId` - confirmation that the message is sent
- message `C id MSG msgId msgMeta msgIntegrity msgBody` - received message
- *command* `C idB ACK msgId` - acknowledge message reception (not implemented)
- *message* `C idA RCVD msgId msgIntegrity` - confirmation of message reception and integrity (not implemented)
- command `C id OFF` - suspend connection
- command `C id DEL` - delete connection
- message `C id? OK` - command confirmation
- message `C id? ERR e` - error

### Envelopes

- `C MSG `
- `C HELLO verificationKey ackMode`
- `C REPLY replyInv`

## Broadcasts

### Commands & messages

- command `B id? NEW` - create broadcast (response is `B id OK`)
- command `B id SEND msg` - broadcast message (response is multiple `C id SENT msgId` or ERR, separately for each connection, followed by `B id SENT msgId` once sent to all)
- message `B id SENT msgId` - notification that the message is sent and its internal ID, same as SENT
- command `B id ADD cAlias` - add existing connection to a broadcast (response is `B id OK` or `ERR`, e.g. if bId is used)
- command `B id REM cAlias` - remove connection from broadcast (response is `B id OK`)
- message `B id EMPTY` - all connections were removed from the broadcast
- command `B id DEL` - delete broadcast (response is `B id OK`)
- command `B id LS` - list connections in broadcast, response is `B id MEM space_separated_connections`
- message `B id MEM space_separated_connections`

## Open/public connection

### Commands

- command `O id? NEW` - create open connection
- message `O id INV oInv` - open invitation
- command `C id? JOIN oInv replyMode infoB` - join connection (response `OK`, followed by `CON`)
- message `O id REQ open:invId infoB` - confirmation from B joining sent to A
- command `C idC? LET open:invId` - note, that it creates new connection, keeping OPEN connection
- command `O id SUB` - subscribe to open connection
- message `O id END` - unsubscribed from open connection
- command `O id OFF` - suspend open connection
- command `O id DEL` - delete open connection
- message `O id? OK` - command confirmation
- message `O id? ERR e` - error

## Introductions

### Commands

- command `C idAB INTRO cIdAM infoM` - introduce connection cIdB to connection cIdM (response is `OK`)
- message `C idBA REQ intro:invId infoM` - notification to confirm introduction
- command `C idBM? LET intro:invId` - accept offer to be introduced (response is `cIdBM OK`, followed by `ICON`)
- message `C idBM CON` - confirmation that connection is established to both introduced parties
- message `C idAB CON cIdAM` - confirmation that connection is established to the introducer

### Envelopes

- `I NEW extIntroIdM  infoM` - new introduction offered by introducer
- `I INV extIntroIdB idBMInv infoB` - invitation to join connection from B to M sent via A
- `I NEW extIntroIdB idBMInv infoB` - new introduction forwarded by introducer
- `I CON extIntroIdM` - confirmation that the connection is established sent by both introduced parties to the introducer

## Groups

## Agent commands and messages syntax

- command `G gId? GROUP gInfo` - create group (response is `G gId OK`)
- command `G gId ADD cAlias role` - add existing connection to a group
- message `C cAlias GREQ group:invID role gMeta gInfo` - invitation to join the group
- command `G gId? LET group:invId` - accept invitation (response is `G gId OK`)
- message `G gId CON cAlias` - 2 connections created with some group member (both for group and direct messages)
- message `G gId MEM [cAlias]` - connection created with all group members for a given member or current client
- command `G gId SEND msg` - send message to group
- message `G gId SENT msgId` - notification that the message is sent and its internal ID, same as SENT
- message `G gId MSG cAlias msgId msgdata` - received group message from cAlias, msgdata is the same set of parameters as in `MSG`
- command `G gId ACK msgId` - acknowledge message reception by the client
- message `G gId RCVD cAlias msgId status` - message delivery notification
- command `G gId LEAVE` - leave the group
- message `G gId LEFT [cAlias]` - connection cAlias left the group
- command `G gId REM cAlias` - remove group member (response is `gId OK`, followed by `GREMD` notification)
- message `G gId REMD cAlias [cAlias]` - member removed
- message `G gId OUT cAlias` - you are removed (see question below - should it be just a sequence of GLEFT?)
- message `G gId EMPTY` - all members left the group and it is now empty
- command `G gId DEL` - delete the group (response is `gId OK`)
- message `G gId DELD [cAlias]` - group deleted
- TODO changing member roles

## Agent message envelopes syntax

- `G_INV mid role role gInv gMeta gInfo` - invitation to join the group
- `GM_ADD mid role` - shared member ID and connection level (see sequence diagram)
- `GM_INV mid gInv inv` - queueInfos to be passed to an existing member (previously referred to in G_MEM)
- `GM_NEW mid role gInv inv` - queueInfos from the new member to the existing member (sent by the agent that invited the new member)
- `G_CON mid` - confirmation about connection to a member
- `GM_END` - confirmation that there are no more members (so no more GM_ADD will be sent in this group, the number of GM_ADD can be more than what was sent in gMeta because some new members could have been added between G_INV and GM_ALL that needed to be sent. Managing race conditions needs clarification).
- `G_JOINED mid` - confirmation that member connected to all members
- `G_LEFT` - notification that member left the group
- `G_MSG msgdata` - group message, msgdata is the same as in A_MSG
- `G_RCVD msgID hash sig`
- `G_OUT` - you are removed from the group
- `G_REM mid` - remove member mid from the group
- `G_REMD mid` - confirmation that member is removed
- `G_DEL` - group is deleted
- `G_DELD` - confirmation that group is deleted
- TODO updates to member roles

## Commands and objects

| Dir     | Command / message    | (C)onnection | (O)pen connection | (B)roadcast | (G)roup |
|:---------:|:--------------------:|:------------:|:-----------------:|:-----------:|:-------:|
| command | `t:id? NEW`           | ✓ | ✓ | ✓ | ✓ |
| command | `C:id INTRO t:id info` | ✓ | - | - | ✓ |
| message | `t:id INV inv`        | ✓ | ✓ | - | - |
| command | `C:id? JOIN inv replyMode info` | ✓ | - | - | - |
| message | `t:id REQ invId info` | ✓ | ✓ | - | - |
| message | `t:id GREQ invId ...` | - | - | - | ✓ |
| command | `t:id? LET invId`     | ✓ | - | - | ✓ |
| message | `t:id CON [C:id]`     | ✓ | - | - | ✓ |
| command | `t:id SUB`            | ✓ | ✓ | - | ✓ |
| message | `t:id END`            | ✓ | ✓ | - | ✓ |
| command | `t:id OFF`            | ✓ | ✓ | - | - |
| command | `t:id DEL`            | ✓ | ✓ | ✓ | ✓ |
| message | `t:id DELD [C:Id]`    | ✓ | ✓ | ✓ | ✓ |
| command | `t:id SEND msg`       | ✓ | - | ✓ | ✓ |
| message | `t:id SENT msg`       | ✓ | - | ✓ | ✓ |
| message | `t:id MSG [C:id] msgId msgdata` | ✓ | - | - | ✓ |
| command | `t:id ACK msgId`      | ✓ | - | - | ✓ |
| message | `t:id RCVD [C:id] msgId status` | ✓ | - | - | ✓ |
| command | `t:id ADD C:id`       | - | - | ✓ | ✓ |
| command | `G:id ROLE C:id role` | - | - | - | ✓ |
| command | `t:id REM C:id`       | - | - | ✓ | ✓ |
| command | `t:id REMD C:id`      | - | - | ✓ | ✓ |
| message | `t:id EMPTY`          | - | - | ✓ | ✓ |
| message | `G:id OUT C:id`       | - | - | - | ✓ |
| command | `t:id LS`             | - | - | ✓ | ✓ |
| message | `t:id MEM cIds`       | - | - | ✓ | ✓ |
| command | `G:id LEAVE`          | - | - | - | ✓ |
| message | `G:id LEFT [C:id]`    | - | - | - | ✓ |
