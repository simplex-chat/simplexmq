# SMP agent broadcast

## Problem

Support agent message broadcast to multiple connections.

It is done in ad-hoc way as part of the previous [groups proposal](./2021-05-23-groups2.md) - this proposal defines broadcast as a separate agent primitive to simplify group management.

It can also be used for other purposes when the same message needs to be sent to multiple recipients without creating groups.

## Solution

A minimal protocol of additional client commands to create, manage and use broadcasts.

From the point of view of the recipient this will look like a normal message, as if the sending agent executed multiple send commands (in fact, broadcast can be implemented by agent sending itself multiple SEND commands)

### Commands and messages

- command `B:bId? NEW` - create broadcast (response is `B:bId OK`, or `ERR` if broadcast already exists)
- command `B:bId ADD C:cId` - add existing connection to a broadcast (response is `B:bId OK` or `ERR`, e.g. if connection already added or does not exist)
- command `B:bId SEND msg` - broadcast message (response is multiple `B:cId SENT [C:bId] msgId` or ERR, separately for each connection and then for the broadcast)
- message `B:bId SENT [C:bId] msgId` - notification that the message is sent to a specific or all recipients
- command `B:bId REM C:cId` - remove connection from broadcast (response is `B:bId OK` or `ERR`)
- message `B:bId EMPTY` - all connections were removed from the broadcast
- command `B:bId DEL` - delete broadcast (response is `B:bId OK` and when the last connection is removed an additional `B:bId EMPTY` is sent)
- command `B:bId LS` - list connections in broadcast, response is `B:Id MS space_separated_connections`
- message `B:bId MS space_separated_connections`

## Questions

1. Should broadcast IDs use the same namespace as connection IDs (and as group IDs)? Having the same namespace for all abstractions that the agent can operate on can be helpful, as it can also allow implementing some queries to determine which type a given ID has, but it also increases implementation complexity.

2. Given that this abstraction would be used as internal abstraction for groups (same as connections internal to the group), it might be better to implement "agent users", each with its own connection namespace. In this case agent would use itself as one of the users.

3. There is a similarity of commands for connections, groups and broadcasts, they only differ on the single-letter prefix. We could do one of the following:
  - use the same command for different object types. This feels incorrect and error prone on its own.
  - extend transmission structure with the field defining the object type (connection, group, broadcast, etc.).

In this case, the transmission would look like:

```
agentTransmission = [corrId] CRLF objectType:[objectID] CRLF agentCommand
objectType = C | B | G ; this is the additional field
```

This approach would allow reusing the existing command avoiding the unnecessary repetition.

In this case, the command type could be parameterized with the list of supported agent object types, so we can ensure on the type level that only allowed commands can be constructed.

EDIT: This approach is already implemented
