# SMP protocol changes to support push notifications on iOS

## Problem

There are already commands/responses to allow subscriptions to message notifications - NKEY/NID, NSUB/NMSG. These commands will be used by SMP agent (NKEY/NID) and by notification server (NSUB/NMSG) to have message notifications delivered to notification server, so it can forward them to APNS server using device token.

There are two remaining problems that these commands do not solve.

1. Receiving the message when notification arrives.

iOS requires creating a bundled notification service extension (NSE) that runs in isolated container and, if we were to use the existing commands, would have SMP subscription to the same SMP servers as the main app, triggering resubscriptions every time the message reception switches between the app and NSE. That would cause a substantial increase in traffic and battery consumption to the users.

2. Showing notifications for service messages.

Users do not expect to see notifications for every single SMP messages - e.g., we currently do not show notifications when messages are edited and deleted, and users do not expect them. NSE requires that for every received push notification there should be some notification shown to the users. So only we would have to show a notification for message deletes and updates, we would have to show it for all service messages - e.g. user accepted file invitation, or file transmission has started, contact profile updates and so on.

We considered differentiating whether notifications are sent per queue, from the recipient side, so we do not send notifications for file queues. But it seems insufficient, particularly if we add such features as message receipts, status updates, etc.

## Proposal

1. To retrieve messages when push notifications arrive, we will add 2 SMP commands:

- GET: retrieve one message from the connection. Resonse could be either MSG (the same as when MSG is delivered, but with the correlation id) or GMSG (to simplify processing) – TBC during implementation. If message is not available, the response could be ERR NO_MSG
- ACK or GACK: acknowledge that the message was processed by the client and can be removed - TBC which one is better. The response is OK or ERR NO_MSG if there was nothing to acknowledge (same as with ACK now)

This would allow receiving a single message from the queue without subscription, this way avoiding that the main app is unsubscribed from the queue.

2. The only way to avoid showing unnecessary notifications (status updates, service messages, etc.) is to avoid sending them. That requires instructing SMP server whether notification should be sent both per queue, from the recipient side, and per message - from the sender side. So the notification would only be sent if the queue has them enabled (via NKEY command) and the sender includes an additional flag in SEND command. The same flag should be included into MSG, so when the message is retrieved with GET command, the client knows, on the agent or chat level (or both), whether this message should have notification shown to the user, and if not - retrieve the next one(s) as well.

This is a substantial change to SMP protocol, that would require client and server upgrade for notifications to be supported.

We should consider whether to increase the SMP protocol version number to 2, so that the new clients can connect to the old clients but without notifications, or we could keep the old commands in the protocol and instead of adding flags to the existing commands, create new commands.

We can also consider making commands extensible so that the new flags can be added (and ignored by parsers if not supported) to at least some existing commands.
