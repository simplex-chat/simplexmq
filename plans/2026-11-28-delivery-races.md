# Races in message delivery left by the plan of #2095

Master problems in message delivery that the plan of plans/2026-11-21-agent-no-blocking did not fix, found on 2026-11-28, with the decisions taken (D38, D39 in that plan's 2-decisions.md).

References: A, AC, AS, ST are simplexmq 3f57fcdc src/Simplex/Messaging/Agent.hs, Agent/Client.hs, Agent/Store/AgentStore.hs, Agent/Store.hs; Srv is src/Simplex/Messaging/Server.hs; CMD, INT, SUB are simplex-chat 3fc82ff6 src/Simplex/Chat/Library/Commands.hs, Internal.hs, Subscriber.hs.

## Causes and decisions

| Cause | What users see | Change | Where |
|---|---|---|---|
| C1. Chat commands hold a group lock across synchronous agent network calls (CMD:2822-2839, 2852-2873, 2887-2911, 3359-3368, 2791-2805); the single event thread waits for that lock (SUB:146-147, CMD:6049-6063) | Messages of all contacts stop while a server is slow, when the user adds a member, joins a group, creates a group link or adds relays | Validate under the lock, call the agent without it, check again and commit under it | chat pull request of #2095 (D38) |
| C2. Stored deliveries and commands are resumed only after every server's subscriptions (A:2006-2014) | After a restart, messages queued before it and stored commands wait for the slowest server | Resume deliveries before subscribing; resume each server's commands when its subscription loop ends | #2095 (D39) |
| C3. With the event queue full, one event is deferred and the next written directly (A:3899-3904, 2480-2483); the chat sets connection status from every event (SUB:165-178) | A new contact stays not fully ready when CON arrives before INFO or JOINED | Chat: an event never lowers a ready connection; agent: after one deferred event, the handler's later events are deferred too, and written also after an error | chat pull request of #2095, agent part in #2095 (D39) |
| C4. The agent emits a message again after a reconnect or restart before the chat acknowledged it (A:3785-3805); the chat does not use the redelivered flag | A direct message fails with a database error on the unique shared message id of its chat item; a group message fails as a duplicate | The chat skips a message it already handled | https://github.com/simplex-chat/simplex-chat/pull/8212 (D39) |
| C6. A queue created while its connection is deleted is not recorded (AS:551-559, 646-651) | Server operators keep the queue; the app gets an error for a connection it deleted | When recording fails because the connection is gone, one DEL with the in-memory id and key | #2095 (D39) |
| C7. Connection deletion: an already deleted connection loses its pending queue deletions (A:3049-3058); a connection without receive queues deleted with waitDelivery stays (AS:614-638); commands and deliveries of deleted connections keep running (AS:1733-1743, 1116-1132) | Queues stay on servers after deletions; deleted connections keep sending | Delete rows only of connections read live; mark such connections waiting for delivery; skip commands and deliveries of deleted connections except queue deletions | #2095 (D39) |
| C8. No acknowledgement is stored when reading the connection or storing the ACK fails (A:3646-3653, 3871-3876); the server sends the next message only after an ACK (Srv:2122) | Messages from a contact stop until a reconnect or restart, after a store error | Set the queue's subscription pending, so the resubscription sends SUB again | #2095 (D39) |
| C10. Commands run in created_at order (AS:1718, 1728) | Setting the device clock back reorders stored commands | Order by command_id | #2095 (D39) |

## Open principle

C5. Agent events (contact request, confirmation, CON, JOINED, INV, ERR) exist only in memory (AC:351). After a process end, a request may never appear and a connection may never complete. The transport specification (https://github.com/simplex-chat/simplexmq/pull/2105) states in item 4.5 that unread events are lost when the process ends, and in item 13.2 that every started operation completes, is retried, or ends with an error event. Options:
1. The app acknowledges events of connection setup, and the agent emits them again at start (recommended).
2. Only contact requests and confirmations are acknowledged, as messages are.
3. Item 4.5 stays: such events are lost.

## Covered by named separate work

- Queue rotation rethink (D36): QUSE not sent after ratchet synchronization or a crash; the abort, the deletion of a drained queue and the rotation handlers write in several transactions; AUTH leaves a rotation in progress; a redelivered message is dropped once another queue has a later one.
- Bounds in time (D37): the GET lock waits without a bound and stays after a permanent ACK error; temporary errors of several commands are retried without a bound.
- Reject rework (D32): reject with notify sends its request under the address lock.
- Event queue rework (D2): user deletion and event handlers write to a full event queue.
- Ratchet synchronization rework (D23): QCONT is not sent during ratchet synchronization, so the sender waits for the slow QUOTA retry.
