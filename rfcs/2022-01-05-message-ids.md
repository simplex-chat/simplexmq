# Internal message IDs, control messages and message integrity changes

## Background and motivation

We have three kinds of message IDs on the agent level (irrespective of message numbering for double ratchet encryption).

- internal message ID - it is sequential ID number both received and send messages, starting from 1. This is convenient for message sorting, as timestamps are unreliable. It is also convenient for tracking, on the application level, that no messages are missing in the connection. It is also needed to acknowledge messages (ACK mid), report delivery (SENT mid) and any message associated errors (MERR mid err).
- external message ID assigned by sending errors - this is never seen by the users, but it is used to track that messages are not lost in transit, and can be used to detect duplicates and re-arrange as needed (e.g. when we have multiple queues some messages can be lost but still appear later) - this is only assigned to sent messages, and is unique per connection.
- ID received from another agent - this is only assigned to received messages, and is not guaranteed to be unique, as there may be errors or duplicate deliveries on the sending side/in transit.

We have three types of agent "envelopes":

1. SMP confirmations. Currently not saved, I am considering if we should, but no instant changes proposed - if we save, they will become control messages. BUT It's important though that SMP confirmations are different per queue, so it is difficult to save them (and, probably, difficult to encrypt with double ratchet for the same reason).
2. SMP invitations. They are ephemeral and not saved, not numbered. No changes proposed.
3. Agent message envelope, with header and body, it has two main types:
  - normal messages sent by the user.
  - control messages (HELLO, REPLY, more to be added).

We only report message integrity violation for user messages (as part of MSG), but now we validate it for all messages - so we could report it for control messages too.

## Proposal

1. User messages would have internal internal sequential IDs, control messages won't.
2. Message integrity will be reported for all messages, as a separate agent message to user, not as part of MSG. Given that now we have MERR that is used to report sending errors, it can be also used for reporting delivery errors, using either `MERR <mid or control message> <err>` where `<mid or control message>` would be either internal message ID or control message tag (not the whole message) and `err` would be `AGENT A_INTEGRITY <MsgIntegrityError>` or `MESSAGE <MsgIntegrityError>` (in which case the current `AGENT A_MESSAGE` can be split into multiple `MESSAGE` errors too - TBC during implementation).
3. Control messages should not be saved on reception, as they are instantly processed before they are ACKed to the server, and users do not ACK them.

## Schema change

This schema change is not a migration. See relevant tables with high-lighted changes in [2022-01-05-message-ids.sql](./2022-01-05-message-ids)

## Implementation plan

Split agent message envelope constructor (AgentMsgEnvelope) to two constructors:

- AgentUserMsgEnvelope
- AgentControlMsgEnvelope

Both message types will have an external message ID (the one that is included in sent APrivHeader) and hash, and will be validated in the same way. Both types will be sent via the database queue. Only AgentUserMsgEnvelope will use (and increment) internal message ID.
