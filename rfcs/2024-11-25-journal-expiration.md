# Expiring messages in journal storage

## Problem

The journal storage servers recently migrated to do not delete delivered or expired messages, they only update pointers to journal file lines. The messages are actually deleted when the whole journal file is deleted (when fully deleted or fully expired).

The problem is that in case the queue stops receiving the new messages then writing of messages won't switch to the new journal file, and the current journal file containing delivered or expired messages would never be deleted.

## Solution

Remove current journal file and update queue_state.log during message expiration of "idle" queue (that is, without any new messages received or delivered within 3 hours) in case when:
- the queue is "empty" after the expiration
- the queue contains only quota marker(s), in which case move them to a new journal file and update the queue_state accordingly. Quota markers can be kept indefinitely to prevent writing the new messages to the dormant queues that reached capacity, so it's important to handle this case.

Also remove current journal file when the queue is opened in case it is empty (as it would not be ever expired in case it remains empty), and also update queue_state.log
