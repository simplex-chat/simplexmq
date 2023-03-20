# SimpleX File Transfer protocol

## Problem

Sending files as currently implemented in SimpleX Chat is inefficient for these reasons:

1. Slow: message delivery requires acknowledgement for each message before the server sends the next message.
2. Not fully asynchronous:
   a. SMP queue size is limited, so the whole file cannot be sent/stored in server memory.
   b. Recipient needs to accept the file before it is sent.
3. No broadcast: sending the same file to multiple recipients requires sending it multiple times.

## Possible solutions

These problems could be solved within SMP protocol:

- streaming messages without waiting for acknowledgements.
- bigger queue sizes stored on hard drive and accepting large files without waiting for the recipient confirmation.
- adding broadcast to SMP servers.

These solution are complex and they do not scale well.

Another approach would be adopting some open-source file storage, possibly S3-compatible, to host files while "in transit". The downsides are:

1. Missing features. S3-compatible file servers require a service layer that we would need to develop to manage user accounts and permissions. There are solutions that allow self-registering users and uploading files without service layer, but they are not flexible enough in managing policies for these files.
2. Limited meta-data protection, both on the application and on transport layer: same address for sending and receiving a file, file size is known to the server, etc.
3. More difficult to self-host for the users when the server has 2 components (a 3rd party solution with our service component).

We are not considering P2P solutions because of their bad meta-data privacy and requirement of having a single network - the same reason why P2P design is not used for SimpleX messaging network.

A proposed solution is to develop a file hosting service (SimpleX File Transfer service) that would have better meta-data protection and functionality than the alternatives, using the ideas from SMP protocol design.

The parameters of the solution would be:

1. The server does not have knowledge of the users and actual files – only anonymously uploaded fixed-size chunks (considered 8Mb, maybe we should allow 2 sizes, e.g. 1Mb and 8Mb).
2. The server should allow broadcast, so that a chunk can be downloaded by multiple recipients.
3. There should be no identifiers and ciphertext in common inside TLS between sender and recipient traffic, and between the traffic of different recipients of the same file. This approach can be extended to support public chunks that have persistent identifiers.
4. The server should prevent multiple uploads of the same chunk. This can be extended to allow multiple downloads from the same persistent address.
5. Clients can send the chunks from the same file via multiple servers, both by splitting chunks between them and for redundancy.

## Design approach

File transfer servers will be chosen by file senders. The servers will allow senders to anonymously upload fixed-size file chunks.

### Transport protocol

- binary-encoded commands sent as fixed-size padded block in the body of HTTP2 POST request, similar to SMP and notifications server protocol transmission encodings.
- HTTP2 POST with a fixed size padded block body for file upload and download.

Block size - 4096 bytes (it would fit ~120 Ed25519 recipient keys).

The reasons to use HTTP2:

- avoid the need to have two hostnames (or two different ports) for commands and file uploads.
- compatibility with the existing HTTP2 client libraries.

The reason not to use JSON bodies:

- bigger request size, so fewer recipient keys would fit in a single request
- signature over command has to be outside of JSON anyway.

The reason not to use URI segments / HTTP verbs / REST semantics is to have consistent request size.

### Required server commands:

- File sender:
  - create file chunk record.
    - Parameters:
      - Ed25519 key for subsequent sender commands and Ed25519 keys for commands of each recipient.
      - chunk size.
    - Response:
      - chunk ID for the sender and different IDs for all recipients.
  - add recipients to file chunk
    - Parameters:
      - sender's chunk ID
      - Ed25519 keys for commands of each recipient.
    - Response:
      - chunk IDs for new recipients.
  - upload file chunk.
  - delete file chunk (invalidates all recipient IDs).
- File recipient:
  - download file chunk:
    - chunk ID
    - DH key for additional encryption of the chunk.
    - command should be signed with the key passed by the sender when creating chunk record.
  - delete file chunk ID (only for one recipient): signed with the same key.

### Storage model

Same as for SMP and notifications server - in-memory storage of the records, with adding to append-only log, restored and compacted on server restart.

### Sending file

To send the file, the sender will:

- compute SHA512 digest
- pad the file to match the whole number of chunks in size,
- encrypt it with a randomly chosen symmetric key and IV (e.g., using NaCL crypto_secretbox),
- split into fixed size chunks
- upload each chunk to a randomly chosen server.

The sending client should generate more per-recipient keys than the actual number of recipients, possibly rounding up to a power of 2, to conceal the actual number of intended recipients.

Then the sending client will combine addresses of all chunks and other information into "file description", different for each file recipient, that will include:

- an encryption key that was used to encrypt the file (the same for all recipients).
- file SHA512 digest
- list of chunk descriptions; information for each chunk:
  - private Ed25519 key to sign commands for file transfer server.
  - chunk address (server host and chunk ID).
  - chunk sha512 digest

To reduce the size, chunk descriptions will be grouped by the server host.

This "file description" itself will be sent as a small file over an authenticated channel, to prevent file description modification. To estimate its size:

- each chunk \* redundancy per chunk, assuming chunks are grouped per server:
  - 1-based chunk number in the file - 8 bytes (including any overhead)
  - Ed25519 key (different for each recipient / chunk combination) - 32 bytes \* 4/3 (base64, assuming text encoding)
  - chunk ID (different for each recipient) - 64 bytes \* 4/3
  - optional (only in the first chunk occurence) chunk sha512 digests - 64 bytes \* 4/3
- server addresses - say, 128 bytes per server
- sha512 digest - 64 bytes \* 4/3
- encryption key - 32 bytes \* 4/3
- IV - 32 bytes \* 4/3
- encoding overhead - say, 256 bytes

For 1gb file, sent via 4 different servers, in 8Mb chunks, with redundancy 2, the size of "file description", assuming text encoding, will be ~45kb (`128 * (8 + 32 + 64) * 2 * 4/3 + 128 * 64 * 4/3 + 128 * 4 + (64 + 32 + 32) * 4/3 + 256`).

File description format (yml):

```
name: file.ext
size: 33200000
chunk: 8mb
hash: abc=
key: abc=
iv: abc=
parts:
  - server: xftp://abc=@example1.com
    chunks: [1:abc=:def=:ghi=, 3:abc=:def=:ghi=]
  - server: xftp://abc=@example2.com
    chunks: [2:abc=:def=:ghi=, 4:abc=:def=:ghi=:2mb]
  - server: xftp://abc=@example3.com
    chunks: [1:abc=:def=, 4:abc=:def=]
  - server: xftp://abc=@example4.com
    chunks: [2:abc=:def=, 3:abc=:def=]
```

This file description is sent to all recipients via normal messages, split to 15780 byte chunks if needed.

### Receiving file

Having received the description, the recipient will:

- download all chunks falling back to secondary servers, if needed
- combine the chunks into a file
- decrypt the file
- un-pad it
- validate file digest
