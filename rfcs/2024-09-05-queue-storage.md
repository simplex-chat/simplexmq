# Storage considerations for SMP queues

See [Short invitation links](./2024-06-21-short-links.md).

## Problem

1) queue records are created permanently, until the clients delete them.

2) clients only delete queue records based on some user action, pending connections do not expire.

While part 2 should be improved in the client, indefinite storage of queue records becomes a much bigger issue if each of them would result in a permanent storage of 4-16kb blob in server memory, without server-side expiration for short invitation links.

## Possible solutions

1) Add some queue timestamp, e.g. queue creation date, to expire unsecured queues after say 3 weeks.

The problem with this approach is that contact addresses are also unsecured queues, and they should not be expired.

We could set really large expiration time, and require that clients "update" the unsecured queues they need at least every 1-2 years, but it would not solve the problem of storing a large number of blobs in the server memory for unused/abandoned 1-time invitations.

2) Do not store blobs in memory / append-only log, and instead use something like RocksDB. While it may be a correct long term solution, it may be not expedient enough at the current POC stage for this feature. Also, the lack of expiration is wrong in any case and would indefinitely grow server storage.

3) Add flag allowing the server to differentiate permanent queues used as contact addresses, also using different blob sizes for them. In this case, messaging queues will be expired if not secured after 3 weeks, and contact address queues would be expired if not "updated" by the owner within 2 years.

Probably all three solutions need to be used, to avoid creating a non-expiring blob storage in memory, as in case too many of such blobs are created it would not be possible to differentiate between real users and resource exhaustion attacks, and unlike with messages, they won't be expiring too.

Servers already can differentiate messaging queues and contact address queues, if they want to:
- with the old 4-message handshake, the confirmation message on a normal queue was different, and also KEY command was eventually used.
- with the fast 2-message handshake, while the confirmation message has the same syntax, and the differences are inside encrypted envelope, the client still uses SKEY command.
- in both cases, the usual messaging queues are secured, and contact addresses are not, so this difference is visible in the storage as well (although it is not easy to differentiate between abandoned 1-time invitations and contact addresses).

Differentiating these queues can also allow different message retention times - e.g., the queues for contact addresses could have bigger size, but have lower message retention time.

## Proposed solution

1. Add queue updated_at date into queue records. While it adds some metadata, it seems necessary to manage retention and quality of service. It will not include exact time, only date, and the time of creation will be replaced by the time of any update - queue secured, a message is sent, or queue owner subscribes to the queue. To avoid the need to update store log on every message this information can be appended to store log on server termination. Or given that only one update per day is needed it may be ok to make these updates as they happen (temporarily making the sequence and time of these events available in storage).

2. Add flag to indicate the queue usage - messaging queue or queue for contact address connection requests. This would result in different queue size and different retention policy for queue and its messages. We already have "sender can secure flag" which is, effectively, this flag - contact address queues are never secured. So this does not increase stored metadata in any way.

## Possible changes to short links

This is a design considerations and a concept, not a design yet.

Instead of implementing a generic blob storage that can be used as an attack vector, and adds additional failure point (another server storing blob that is necessary to connect to the queue on the current server), but instead adds an extended queue information blobs, most of which could be dropped without the loss of connectivity, so that the attack can be mitigated by deleting these blobs without users losing the ability to connect, as long as the queue and minimal extended information is retained.

So, to make the connection there need to be these elements:

- queue server and queue ID - mandatory part, that can be included in short link
- SMP key - mandatory part for all queues. We are considering initializing ratchets earlier for contact addresses, and include ratchet keys and pre-keys into queue data as well, but it is out of scope here.
- Ratchet keys - mandatory part for 1-time invitation that won't fit in short link.
- PQ key - optional part that can be stored with addresses if ratchet keys are added and with 1-time invitations.
- App blobs - chat preferences for 1-time invitation links and profile information for contact addresses.

So rather that storing one blob with a large address inside it, not associated with the queue, increasing probability of failure and reducing our ability to mitigate resource exhaustion, we could store extended blobs associated with the queues.

Also, we need the address shared with the sender (party accepting the connection) to be short. We could use a similar approach that was proposed for data blobs, using a single random seed per queues to derive multiple keys and IDs from it. For example:

1. The queue owner:
  - generates Ed25529 key pair `(sk, spk)` and X25519 key pair `(dhk, dhpk)` to use with the server, same as now sent in NEW command.
  - generates queue recipient ID (this ID can still be server-generated).
  - generates X25519 key pair `(k, pk)` to use with the accepting party.
  - derives from `k`:
    - sender ID.
    - symmetric key for authenticated encryption of blobs.
  - `k` will be used as short link.
2. All other data from the invitation can be included in queue creation request and be associated with the queue as 1-3 blobs with different priority:
  - ratchet keys - it will have a small size, so only this blob cannot be removed, while other blobs can be removed in case of resource exhaustion.
  - PQ keys - optional blob.
  - conversation preferences and profile - can be removed depending on creation time, e.g. all new blobs can be removed.

The algorithm used to derive key and ID from `k` needs to be cryptographically secure, e.g. it could be some KDF or ChaCha DRG initialized with `k` as seed, TBC.

So, coupling blob storage with messaging queues has these pros/cons:

Cons:
- no additional layer of privacy - the server used for connection is visible in the link, even after the blobs are removed from the server.

Pros:
- no additional point of failure in the connection process - the same server will be used to retrieve necessary blobs as for connection.
- queue blobs of messaging blobs will be automatically removed once the queue is secured or expired, without additional request from the recipient - reducing the storage and the time these blobs are available.
- queue blobs for contact addresses will be structured and some of the large blobs can be removed in case of resource exhaustion attack (and recreated by the client if needed), with the only downside that PQ handshake will be postponed (which is the case now) and profile will not be available at a point of connection.
