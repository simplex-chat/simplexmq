# SMP server message storage

## Problem

Currently SMP servers store all queues in server memory. As the traffic grows, so does the number of undelivered messages. What is worse, Haskell is not avoiding heap fragmentation when messages are allocated and them deallocated - undelivered messages use ByteString and GC cannot move them around, as they use pinned memory.

## Possible solutions

### Solution 1: solve only GC fragmentation problem

Move from ByteString to some other primitive to store messages in memory long term, e.g. ShortByteString, or manage allocation/deallocation of stored messages manually in some other way.

Pros: the simplest solution that avoids substantial re-engineering of the server.

Cons: not a long term solution, as memory growth still has limits.

### Solution 2: move message storage to hard drive

Use files or RocksDB to store messages.

Pros:
- much lower memory usage.
- no message loss in case of abnormal server termination (important until clients have delivery redundancy).
- this is a long term solution, and at some point it might need to be done anyway.

Cons:
- substantial re-engineering costs and risks.
- metadata privacy. Currently we only save undelivered messasages when server is restarted, with this approach all messages will be stored for some time. this argument is limited, as hosting providers of VMs can make memory snapshots too, on the other hand they are harder to analyse than files. On another hand, with this approach messages will be stored for a shorter time.

#### RocksDB and other key-value stores

The downside of any key-value stores is that they don't seem to have efficient primitives for sequential delivery. While sequential delivery can be modelled with linked lists, they would require 1 key insert (on send), 3 key updates (1 update to update queue data on send, 1 update of the last message to point to the next, 1 update on delivery or message expiration) and 1 key deletion (on delivery or message expiration) for each delivered message.

This might result in substantial write aplification and compacting costs.

In general, tree structures that are efficient for quick lookups and updates, given approximately fixed value size, are inefficient for modelling queues.

#### Files

The upside of files is that they are well suited for sequential delivery and don't result in the same churn, with careful design, as trees do.

The downside of filesystem is that it does not scale well with the large number of files in a folder, so queues will have to be spread across multiple folders, following tree-like structure.

I could not find an available library that efficiently models sequential delivery in highly concurrent environment.

A possible design could be the following.

##### Queue folder and files

Each message queue is stored in its own folder (see below on folder locations). Folder would contain these files:

- `messages.abcd.log` - the file that is used to read messages from, sequentially
- `messages.efgh.log` - the optional file that is used to write messages, in case it is different from read file.
- `queue.log` - append-only file where the last line represents the current queue state
- `queue.timestamp.log` - previous states of queue.log file

Each line in "queue.log" file has this syntax

```abnf
queueLogLine =
    %s"read_file=" base64
    %s"read_msg=" digits
    %s"read_byte=" digits
    %s"write_file=" base64
    %s"write_msg=" digits
```

When queue is first requested by the server:

```c
if queue folder exists:
    read queue state from last line of queue.log
    if queue.log contained more than one line: // compaction
        copy queue.log to queue.timestamp.log
        write one line queue state to queue.log
else:
    create queue folder
    create messages.abcd.log (abcd is some random string)
    read_msg = 0
    read_byte = 0
    create queue.log with one line: "read_file=abcd read_msg=0 read_byte=0 write_files=abcd write_msg=0"
open read_file in ReadMode and seek to read_byte position
nextReadByte = read_byte
nextReadMsg = read_msg
open write_file in AppendMode
```

When message is added to the queue (assumes that queue state is loaded to server memory, if not the previous section will be done first):

```c
if write_msg > max_queue_messages:
    return quota error
else if write_msg = max_queue_messages:
    add quota_exceeded message to write_file
    update queue state: write_msg += 1
    append updated queue state to queue.log
else ]
    // It is required that `max_queue_messages < max_file_messages`,
    // so that we never need more than one additional write file.
    if write_msg >= max_file_messages: // queue file rotation
        create messages.efgh.log // efgh is some random string
        update queue state: write_file=efgh write_msg=0 // read file remains the same as it was
        append updated queue state to queue.log
        copy queue.log to queue.timestamp.log
        // `old` needs to be defined to limit the number and storage duration,
        // preserving not more than N files, and not more than M days files, "and then some"
        // (that is if the queue has high churn, we have file from M days before in any case, for any debugging).
        delete `old` `queue.timestamp.log` files
        write one line queue state to queue.log // compaction

    add message to write_file
    update queue state: write_msg += 1
    append updated queue state to queue.log
```

The above algorithm assumes `max_queue_messages < than max_file_messages`, so that we never need more than one write file.

When message is delivered, it is simply read from the read queue, queue state does not change yet:

```c
if nextReadMsg > read_msg:
    deliver cached message, no need to read it again
else
    read message from read_file handle
    nextReadMsg = read_msg + 1
    nextReadByte = current position in file
```

When message delivery is acknowledged, the read queue needs to be advanced, and possibly switched to read from the current write_queue:

```c
if nextReadByte == read_byte:
    return error // nothing was delivered
else if nextReadByte = EOF:
    // end of file is reached, possibly some other condition,
    // but it should allow changing max_file_messages on server restart
    currReadFile = read_file
    read_file = write_file
    read_msg = 0
    read_byte = 0
    append updated queue state to queue.log
    delete currReadFile
else
    read_msg += 1
    read_byte = nextReadByte
    // `seek` should not be necessary, as the handle is already at nextReadByte position here
    // seek to read_byte
    append updated queue state to queue.log
```

The above algorithm delegates the problem of compaction and fragmentation management to file system, that is very optimized for such scenarios.

##### Queue folders structure

Most Linux systems use EXT4 filesystem where the file lookup time scales linearly to the number of files. While alternatives with logarithmic lookup time exist (XFS), they may be very complex to configure on the existing systems.

So storing all queue folders in one folder won't scale.

To solve this problem we could use recipient queue ID in base64url format not as a folder name, but as a folder path, splitting it to path fragments of some length. The number of fragments can be configurable and migration to a different fragment size can be supported as the number of queues on a given server grows.

Currently, queue ID is 24 bytes random number, thus allowing 2^192 possible queue IDs. If we assume that a server must hold 1b queues, it means that we have ~2^162 possible addressese for each existing queue. 24 bytes in base64 is 32 characters that can be split into say 8 fragments with 4 characters each, so that queue folder path for queue with ID `abcdefghijklmnopqrstuvwxyz012345` would be:

`/var/opt/simplex/messages/abcd/efgh/ijkl/mnop/qrst/uvwx/yz01/2345`

The maximum theoretic number of the folders on the 1st level is 64^4, or 2^24 ~ 16m - this is probably still a large number of subfolders for EXT4. Given that addresses are random, all the possible combinations in the first folder can be used with a large number of queues.

So we could use an unequal split of path, two letters each and the last being long:

`/var/opt/simplex/messages/ab/cd/ef/ghijklmnopqrstuvwxyz012345`

The first three levels in this case can have 4096 subfolders each, and it gives 68b possible subfolders (64^2^3), so the last level will be sparse in case of 1b queues on the server. So we could make it 4 levels with 2 letters to never think about it, accounting for a large variance of the random numbers distribution:

`/var/opt/simplex/messages/ab/cd/ef/gh/ijklmnopqrstuvwxyz012345`
