# iOS notifications stability

## Problem

iOS notifications may fail to deliver for several reasons, but there are two important reasons that we could address:
- when notification server is not subscribed to SMP server(s), the notifications can be dropped - it can happen because either notification server restarts or becuase SMP server restarted and some messages are received before notification server resubscribed. We lose approximately 3% of notifications because of this reason.
- when user device is offline or has low power condition, Apple does not deliver notification, but puts them to storage. If while the notification is in storage a new one arrives it would overwrite the previous notification. If it was the message to the same message queue, the client will download messages anyway, up to a limit, but if the message was to another queue, it will not be delivered until the app is opened. Apple delivers about 88% of notifications that should be delivered (not accounting for uninstalled apps), the rest is replaced with the newer notifications.

## Solution

The first problem can be solved by preserving notifications for a limited time (say 1 hour) in case there is no subscription to notification from notification server. At the very least, they can be preserved in SMP server memory but can also be stored to a file on restart, similar to messages, and be delivered when notification server resubscribes. It is sufficient to store one notification per messaging queue.

The second problem is both more damaging and more complex to solve. The solution could be to always deliver several last notifications to different queues in one packet (Apple allows up to ~4-5kb notification size, and we are sending packets of fixed size 512 bytes, so we could fit up to 8-10 of them in each notification).

Every time a client receives such batch of notifications if can:
- check if that notification was already received in the previous batch.
- if it was received, it would be ignored, otherwise it would be processed.
- process them one by one, started from the most recent one while the time allows.
