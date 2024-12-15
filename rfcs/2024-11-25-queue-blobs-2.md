# Blob extensions for SMP queues 2 and queue storage

This document evolves the design proposed [here](./2024-09-09-smp-blobs.md).

## Problems

In addition to problems in the first doc, we have these issues with in-memory queue record storage:
- many queues are idle or rarely used, but they are loaded to memory, and currently just loading all queues uses 20gb RAM on each server, and takes 10 min to process, increasing downtimes during restarts.
- adding blobs to memory would make this problem much worse.

## Proposed solution

Move queues to the same journalling approach as [used for messages](./2024-09-01-smp-message-storage.md) now, with independent file names in the same folders.

Each queue change would be logged to its own file, and every time the queue is opened the whole file will be read and compacted to a single line - replacing one store log for all queues, with individual log files for each queue.

Queue deletion would not be making a record in the file, instead it would be deleting the entire folder - it would reduce retention period for any metadata of deleted queues.

We could additionally record deletions to the central log, for debugging, and reset it on every start. But in this case we should not remove folders at the point of deletion, but rather mark them as deleted and delete on restart. TBC

It would also allow simplifying blob storage by having only one blob per queue - for example, limied to 16kb (a bit smaller to fit in block) for contact address queues and 4-8kb for invitations (to fit PQ keys and conversation preferences).

We would also need to be able to lookup recipient ID via sender/notifier/link IDs.

One possible solution is to use and load to memory a central index file. But it is likely to also consume a lot of memory and result in slow starts.

Another solution that is probably better is to use the same folder structure and put notifier/sender/link files with the ID of the recipient queue inside the files. So to locate recipient queue the sender would have to locate folder containing the reference file pointing to the recipient queue and then to locate the actual queue data.

## Implementation details

Each queue folder would these files:

- queue_state.log (and timestamped backups) - to store pointers to message journals (already implemented)
- messages.randomBase64.log - message journals (already implemented)
- queue_rec.log (and timestamped backups) - to log complete queue record every time it is changed (so only the last line needs to be read following the same logic as with queue_state.log, to prevent file corruption).
- blob.data, blob.data.bak, blob.timestamp.data - files for data blobs (to make sure some copy of this file is readable/correct in case of write corruption) - the same two step overwrite process will be used as currently with store log compacting:
  - on write: 1. if file exists, move it to .bak, 2. store new blob to .data, 3. move .bak to .timestamp.data
  - on read: 1. if .bak exists, move it to .data 2. use .data

Additional suggestion to reduce probability of queue_state.log and queue_rec.log file corruption is to do one of the following:
- log end of lines in the beginning of the output, not in the end, to prevent the last line from being corrupted in case the previous line was not fully stored. The downside is that the file will not be EOL terminated, and there will be no confirmation that the output was fully made.
- log EOL both in the beginning and at the end of output, and ignore empty lines in between - this would both confirm that the last line is fully logged and prevent corruption of the next line in case it was not.
- check the last byte of the file and log EOL if it is not EOL. Probably cleanest approach, but with a small performance cost.

If queue folder is a reference to the queue, it may have one of these files:
- notifier.ref
- sender.ref
- link.ref

These files would contain a one line with the recipient ID of the queue. These files would never change, they can only be deleted when queue is deleted or when notifier/link is deleted.

There is logic in code preventing using the same ID in different contexts, and the ID size is large enough to make any collisions unlikely (192 bits), so with correctly working code the queue folder would either have one of reference files, and nothing else, or the queue and message files from the beginning of this section. But even if the same ID is re-used in different context, it should not cause any problems as file names don't overlap.

While we could store different types of references in different types of folders, it would have additional costs of maintaining 4 folder hierarchies. Instead we could use the fact that it is one hierarchy to prevent using the same ID in different contexts.

## Protocol

The only change in protocol is that there will be only one blob per queue, without markers (see the previous doc). Otherwise the protocol and proposed privacy improvement seem reasonable.
