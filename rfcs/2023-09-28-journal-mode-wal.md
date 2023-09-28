# Switching database to WAL mode

## Problem

1. Slow writes when sending messages to large groups.

A possible solution is batching multiple writes into a single transaction, which is attempted for sending messages in #847 / #3067. The problem with that approach is that it substantially complicates the code and has to be done for other scenarios separately (e.g., broadcasting profile updates, which is even more complex as different messages have to be sent to different contacts, to account for preference overrides).

2. Conflicts for the database access from multiple processes (iOS app and NSE).

A possible solution is better coordination of access than currently implemented, but it is substantially more complex, particularly if additional extensions are added.

## Solution

A proposed solution is to increase page_size to 16kb (from 4kb) and switch to WAL mode. This should improve write performance and reduce conflicts.

Problems with this soltion:
- old versions of the app won't be taking into account WAL file when exporting. Possible solutions are:
  - make it non-reversible change (that is, without down migration).
  - checkpoint and switch database to DELETE mode when exporting.
- windows closes the database connection when the app is stopped, so we can no longer do any operations prior to exporting without providing database key. Possible solutions are:
  - always checkpoint and move to DELETE mode when stopping and move back to WAL mode when starting.
  - what else?

Switching to 16kb block also requires a process:
- set it first
- run VACUUM (this will change block size)
- only then the database can be switched to WAL mode

If the database is already in WAL mode it needs to be switched to DELETE mode before block size change will happen on VACUUM.
