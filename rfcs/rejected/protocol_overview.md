# Overview of SMP agent protocol commands

## Connections

### Commands and messages

A initiates connection, B accepts

- command `C:idB? NEW` - create connection
- message `C:idB INV cInv`
- command `C:idA? JOIN cInv replyMode` - join connection (response `OK`, followed by `CON`)
- *message* `C:idB REQ prv:invId infoB` - request from B joining sent to A (not implemented)
- *command* `C:idB ACPT prv:invId` - A confirms B joining (not implemented)
- message `C:id CON` - connection is established
- command `C:id SUB` - subscribe to connection
- message `C:id END` - unsubscribed from connection
- command `C:idB SEND msg` - send message
- message `C:idA SENT msgId` - confirmation that the message is sent
- message `C:id MSG msgId msgMeta msgIntegrity msgBody` - received message
- *command* `C:idB ACK msgId` - acknowledge message reception (not implemented)
- *message* `C:idA RCVD msgId msgIntegrity` - confirmation of message reception and integrity (not implemented)
- command `C:id OFF` - suspend connection
- command `C:id DEL` - delete connection
- message `C:id? OK` - command confirmation
- message `C:id? ERR e` - error

### Envelopes

- `MSG `
- `HELLO verificationKey ackMode`
- `REPLY replyInv`

## Broadcasts

### Commands & messages

- command `B:id? NEW` - create broadcast (response is `B:id OK`)
- command `B:id SEND msg` - broadcast message (response is multiple `C:id SENT msgId` or ERR, separately for each connection, followed by `B:id SENT msgId` once sent to all)
- message `B:id SENT msgId` - notification that the message is sent and its internal ID, same as SENT
- command `B:id ADD cId` - add existing connection to a broadcast (response is `B:id OK` or `ERR`, e.g. if bId is used)
- command `B:id REM cId` - remove connection from the broadcast (response is `REMD`)
- message `B:id REMD cId` - connection removed from the broadcast
- message `B:id EMPTY` - all connections were removed from the broadcast
- command `B:id DEL` - delete broadcast (response is `B:id OK`)
- command `B:id LS` - list connections in broadcast, response is `B:id MEM space_separated_connections`
- message `B:id MEM space_separated_connections`

## Open/public connection

### Commands

- command `O:id? NEW` - create open connection
- message `O:id INV oInv` - open invitation
- command `C:id? JOIN oInv replyMode` - join connection (response `OK`, followed by `CON`)
- message `O:id REQ open:invId infoB` - confirmation from B joining sent to A
- command `C:idC? ACPT open:invId` - note, that it creates new connection, keeping OPEN connection
- command `O:id SUB` - subscribe to open connection
- message `O:id END` - unsubscribed from open connection
- command `O:id OFF` - suspend open connection
- command `O:id DEL` - delete open connection
- message `O:id? OK` - command confirmation
- message `O:id? ERR e` - error

## Introductions

### Commands

- command `C:idAB INTRO C:idAM infoM` - introduce connection cIdB to connection cIdM (response is `OK`)
- message `C:idBA REQ C:invId infoM` - notification to confirm introduction
- command `C:idBM? ACPT C:invId` - accept offer to be introduced (response is `cIdBM OK`, followed by `ICON`)
- message `C:idBM CON` - confirmation that connection is established to both introduced parties
- message `C:idAB CON C:idAM` - confirmation that connection is established to the introducer

### Envelopes

- `INTRO C:extIntroIdM infoM` - new introduction offered by introducer
- `INV C:extIntroIdB prv:invBM infoB` - invitation to join connection from B to M sent via A (can be pub:)
- `REQ C:extIntroIdB prv:invBM infoB` - new introduction forwarded by introducer
- `CON C:extIntroIdM` - confirmation that the connection is established sent by both introduced parties to the introducer

## Groups

## Agent commands and messages syntax

- command `G:gId? NEW` - create group (response is `G:gId OK`)
- command `C:cId INTRO G:gId gInfo` - add existing connection to a group
- message `C:cId REQ g:invID gInfo` - invitation to join the group
- command `G:gId? ACPT g:invId` - accept invitation (response is `G gId OK`)
- message `G:gId CON C:cId` - 2 connections created with some group member (both for group and direct messages)
- message `G:gId MEM [C:cId]` - connection created with all group members for a given member or current client
- command `G:gId SEND msg` - send message to group
- message `G:gId SENT msgId` - notification that the message is sent and its internal ID, same as SENT
- message `G:gId MSG C:cId msgId msgdata` - received group message from cId, msgdata is the same set of parameters as in `MSG`
- command `G:gId ACK msgId` - acknowledge message reception by the client
- message `G:gId RCVD t:cId msgId status` - message delivery notification
- command `G:gId LEAVE` - leave the group
- message `G:gId LEFT [C:cId]` - connection cId left the group
- command `G:gId REM C:cId` - remove group member (response is `gId OK`, followed by `GREMD` notification)
- message `G:gId REMD C:cId [C:cId]` - member removed
- message `G:gId OUT C:cId` - you are removed (see question below - should it be just a sequence of GLEFT?)
- message `G:gId EMPTY` - all members left the group and it is now empty
- command `G:gId DEL` - delete the group (response is `gId OK`)
- message `G:gId DELD [C:cId]` - group deleted

## Agent message envelopes syntax

- `GROUP C:mid G:inv gInfo` - invitation to join the group
- `MEM C:mid` - confirmation that member connected to all members
- `LEFT` - notification that member left the group
- `OUT` - you are removed from the group
- `REM C:mid` - remove member mid from the group
- `REMD C:mid` - confirmation that member is removed
- `DEL` - group is deleted
- `DELD` - confirmation that group is deleted

## Commands and objects

| Dir     | Command / message    | (C)onnection | (O)pen connection | (B)roadcast | (G)roup |
|:---------:|:--------------------:|:------------:|:-----------------:|:-----------:|:-------:|
| command | `t:id? NEW`           | ✓ | ✓ | ✓ | ✓ |
| command | `C:id INTRO t:id info` | ✓ | - | - | ✓ |
| message | `t:id INV inv`        | ✓ | ✓ | - | - |
| command | `C:id? JOIN inv replyMode info` | ✓ | - | - | - |
| message | `t:id REQ invId info` | ✓ | ✓ | - | ✓ |
| command | `t:id? ACPT invId`    | ✓ | - | - | ✓ |
| message | `t:id CON [C:id]`     | ✓ | - | - | ✓ |
| message | `t:id MEM [C:id]`     | - | - | - | ✓ |
| command | `t:id SUB`            | ✓ | ✓ | - | ✓ |
| message | `t:id END`            | ✓ | ✓ | - | ✓ |
| command | `t:id OFF`            | ✓ | ✓ | - | - |
| command | `t:id DEL`            | ✓ | ✓ | ✓ | ✓ |
| message | `t:id DELD [C:Id]`    | ✓ | ✓ | ✓ | ✓ |
| command | `t:id SEND msg`       | ✓ | - | ✓ | ✓ |
| message | `t:id SENT [t':id] msgId` | ✓ | - | ✓ | ✓ |
| message | `t:id MSG [C:id] msgId msgdata` | ✓ | - | - | ✓ |
| command | `t:id ACK msgId`      | ✓ | - | - | ✓ |
| message | `t:id RCVD [t':id] msgId status` | ✓ | - | - | ✓ |
| command | `t:id ADD C:id`       | - | - | - | ✓ |
| command | `t:id REM C:id`       | - | - | ✓ | ✓ |
| command | `t:id REMD C:id`      | - | - | ✓ | ✓ |
| message | `t:id EMPTY`          | - | - | ✓ | ✓ |
| message | `G:id OUT C:id`       | - | - | - | ✓ |
| command | `t:id LS`             | - | - | ✓ | ✓ |
| message | `t:id MS cIds`        | - | - | ✓ | ✓ |
| command | `G:id LEAVE`          | - | - | - | ✓ |
| message | `G:id LEFT [C:id]`    | - | - | - | ✓ |
