# Message log rotation

## Problem

Currently messages are only stored in the server memory, so if we restart the serve users will lose messages - this is a bad user experience.

Servers need to be restarted or can fail.

Also, we currently do not have any simple solution for message expiration - they are inside in-memory queues. Messages need to be expired both for users privacy and to reduce server memory utilization.

This PR adds message logging - each time the message is sent and delivered two log lines are added to append-only log - the same that we use to log changes in message queues - and when the server restarts the log is compacted and the undelivered unexpired messages are restored.

It is not sustainable though to restart frequently enough to avoid consuming large disk space - 1000 messages a second would consume 1.4 Tb a day.

As only a limited number of messages is stored in memory, we should be compacting the log every hour, while the server is running.

## Proposed solution

There can be several log files of three types:

1. "stable", compacted memory dump - it only active (or suspended) queues and undelivered unexpired messages. Dump file names have this format: `smp-server-store-(N).dump` where N is the sequential number of a dump file since SMP server initialization, starting from 0.

2. "in-progress" memory dump - `smp-server-store-(N).dump.saving`.

3. server append-only log - it has all changes in queues and messages. Log file name format is `smp-server-store-(N).log`/

Both files have records in the same format - queue and message operations, as defined in StoreLog.hs

There are three modes of server operation - logging, dumping, restoring.

### Logging

The server has the currently active log file (smp-server-store-(N).log) that the server appends the records to. Each appended line should be flushed (or, potentially we could just use line buffering, but currently it's flush).

### Dumping

It should be triggered on schedule, say every hour.

1. Logging is suspended - that would prevent any commands from being executed - one command would wait on log availability, other in command queues.

2. The snapshot of server memory is made (by reference, so it "should not" take double memory, and it should be fast). We need to test that snapshot of 80% of 16Gb memory takes under 2 seconds - this is 50% of clients timeout.

3. Once snapshot is complete, server log file is changed to N+1 (`smp-server-store-(N+1).log`).

4. Logging is resumed.

5. Dumping of memory snapshot is started to file `smp-server-store-(N).dump.saving` (please note that it is numbered N, so it precedes the currently active log file). All queues are saved to the log (deleted queues would not be in memory), and all un-expired messages are saved - acknowledged messages would not be in memory, so there is no compacting - the whole snapshot is saved.

6. Once dumping is complete (the file closed, the buffer flushed), the file is renamed to `smp-server-store-(N).dump` - it should wait until renaming is complete.

7. If there are previous dumps present on the disk (`smp-server-store-(N-m).dump)`, they should also be removed.

8. if there are previous logs present on the disk (`smp-server-store-(N-m).log`), they should be removed. `m` is any positive integer here.


### Restoring from log

When the server starts it should check for the presense of logs and dumps.

To restore its memory the server should use the latest "stable" dump (`smp-server-store-(N).dump`), if any (there may be no dump files), and all the log files after this stable dump (`smp-server-store-(N+m).dump`, where `m` is any positive integer). Normally there would be only 1 dump file and 1 log file, but in case "dumping" phase fails while in progress there can be other files in the following scenarios:

- dumping fails before step 5 - there would be 2 log files after the last stable dump file - both have to be loaded on restart.
- dumping fails before step 6 - there would be 2 log files (that will be loaded) and one "in-progress" dump file that will be ignored.
- dumping fails before steps 7/8 - there could be previous dump and/or log files that would be ignored.

If the server encounters any log or dump files that are ignored, it should log a warning.
On every successful dump it should log an info line with the information about performed operation.
