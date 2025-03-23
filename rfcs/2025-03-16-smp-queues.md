# Protocol changes for creating and connecting to SMP queues

## Problems

This change is related to these problems:
- differentiating queue retention time,
- supporting MITM-resistant short connection links,
- improving notifications.

This RFC is based on the previous discussions about short links, blob storage and notifications ([1](./2024-06-21-short-links.md), [2](./2024-09-09-smp-blobs.md), [3](./2024-11-25-queue-blobs-2.md), [4](./2024-09-25-ios-notifications-2.md)).

SMP protocol supports two types of queues - queues to communicate over and queues to send invitations. While SMP protocol was originally "unaware" of these queue types, it could differentiate it by message flow, and with the recent addition of SKEY command to allow securing the queue by the sender this difference became persistent.

Simply designating queue types would allow to use this information to decide for how long to retain queues, and potentially extending it:
- unsecured 1-time invitation queues with sndSecure (support of securing by sender) - e.g., 3 months.
- contact address queues without sndSecure - e.g., 3 years without activity.
- Possibly, "queues" that prohibit messages and used only as blob storage - they would be used to store group profiles and superpeer addresses for the group.

This proposal also combines NEW and NKEY command to streamline notifications in preparation to reworking of the notifications protocol.

## Design objectives

We want to achieve these objectives:
1. no possibility to provide incorrect SenderId inside link data (e.g. from another queue).
2. link data cannot be accessed by the server unless it has the link.
3. prevent MITM attack by the server, including the server that obtained the link.
4. prevent changing of connection request by the user (to prevent MITM via break-in attack in the originating client).
5. for one-time links, prevent accessing link data by link observers who did not compromise the server.
6. allow changing the user-defined part of link data.
7. avoid changing the link when user-defined part of link data changes, while preventing MITM attack by the server on user-defined part, even if it has the link.
8. retain the quality that it is impossible to check the existense of secured queue from having any of its temporary visible IDs (sender ID and link ID in 1-time invitations) - it requires that these IDs remain server-generated (contrary to the previous RFCs).

To achieve these objectives the queue data must have immutable part and mutable part.

Immutable part would include:
- full conection request (the current long link with all keys, including PQ keys). This includes SenderId that must match server response.
- public signature key to verify mutable part of link data.

Signed mutable part would inlcude:
- any links to chat relays that should be contacted instead of this queue (not in this RFC), but would allow delegating group connections and contact request connections to prevent spam, hiding online presense, etc.
- and user-defined data - user profile or group profile.

The link itself should include both the key and auth tag from the encryption of immutable part. Accessing one-time link data should require providing sender key and signing the command (`LKEY`).

## Solution

Current NEW and NKEY commands:

```haskell
NEW :: RcvPublicAuthKey -> RcvPublicDhKey -> Maybe BasicAuth -> SubscriptionMode -> SenderCanSecure -> Command Recipient

NKEY :: NtfPublicAuthKey -> RcvNtfPublicDhKey -> Command Recipient

-- | Queue IDs and keys, returned in IDS response
data QueueIdsKeys = QIK
  { rcvId :: RecipientId,
    sndId :: SenderId,
    rcvPublicDhKey :: RcvPublicDhKey,
    sndSecure :: SenderCanSecure
  }
```

Proposed NEW command replaces SenderCanSecure with QueueMode, adds link data, and combines NKEY command:

```haskell
NEW :: NewQueueRequest -> Command Recipient

data NewQueueReq = NewQueueReq
  { rcvAuthKey :: RcvPublicAuthKey,
    rcvDhKey :: RcvPublicDhKey,
    auth_ :: Maybe BasicAuth,
    subMode :: SubscriptionMode,
    queueData :: Maybe QueueModeData,
    ntfCreds :: Maybe NewNtfCreds
  }

-- Replaces NKEY command
-- This avoids additional command required from the client to enable notifications.
-- Further changes would move NotifierId generation to the client, and including a signed and encrypted command to be forwarded by SMP server to notification server.
data NtfRequest = NtfRequest NtfPublicAuthKey RcvNtfPublicDhKey

-- QRMessaging implies that sender can secure the queue.
-- LinkId is not used with QRMessaging, to prevent the possibility of checking when connection is established by re-using the same link ID when creating another queue – the creating would have to fail if it is used.
-- LinkId is required with QRContact, to have shorter link - it will be derived from the link_uri. And in this case we do not need to prevent checks that this queue exists.
data QueueModeData = QRMessaging (Maybe QueueLinkData) | QRContact (Maybe (LinkId, QueueLinkData))

-- SenderId should be computed client-side as sha3-256(correlation_id),
-- The server must verify it and reject if it is not.
type QueueLinkData = (SenderId, EncImmutableDataBytes, EncUserDataBytes)

type EncImmutableDataBytes = ByteString

type EncUserDataBytes = ByteString

-- We need to use binary encoding for AConnectionRequestUri to reduce its size
-- connReq including the full link allows connection redundancy.
-- The clients would reject changed immutable data (based on auth tag in the link) and
-- AConnectionRequestUri where SenderId of the queue does not match.
data ImmutableLinkData = ImmutableLinkData
  { signature :: SignatureEd25519, -- signature of the remaining part of immutable data
    connReq :: AConnectionRequestUri,
    sigKey :: PublicKeyEd25519
  }

-- This part of link data can also include any relays, but possibly we need a separate blob for it
data UserLinkData = UserLinkData
  { signature :: SignatureEd25519, -- signs the remaining part of the data
    userData :: ByteString -- the max size needs to be estimated, but it is likely to be ~ 14kb
  }

-- | Updated queue IDs and keys, returned in IDS response
data QueueIdsKeys = QIK
  { rcvId :: RecipientId, -- server-generated
    sndId :: SenderId, -- server-generated
    rcvPublicDhKey :: RcvPublicDhKey,
    sndSecure :: SenderCanSecure, -- possibly, can be removed? or implied?
    linkId :: Maybe LinkId, -- server-generated
    serverNtfCreds :: Maybe ServerNtfCreds -- currently returned in NID response
  }

data ServerNtfCreds = ServerNtfCreds NotifierId RcvNtfPublicDhKey -- NotifierId is server-generated.
```

In addition to that we add the command allowing to update and also to retrieve and, optionally, secure the queue and get link data in one request, to have only one request:

```haskell
-- This command allows to set all data or to update mutlable part of contact address queue.
-- This command should fail on queues that support sndSecure and also on new queues created with QRMessaging.
-- This should fail if LinkId or immutable part of data is changed with the update, but will succeed if only mutable part is updated, so it can be retried.
-- Entity ID is RecipientId.
-- The response to this command is `OK`.
LSET :: LinkId -> QueueLinkData -> Command Recipient


-- Entity ID is RecipientId
LGET :: Command Recipient

-- To be used with 1-time links.
-- Sender's key provided on the first request prevents observers from undetectably accessing 1-time link data.
-- If queue mode is QRContact (and queue does NOT allow sndSecure) the command will fail, same as SKEY.
-- Once queue is secured, the key must be the same in subsequent requests - to allow retries in case of network failures, and to prevent passive attacks.
-- The difference with securing queues is that queues allow sending unsecured messages to queues that allow sndSecure (for backwards compatibility), and 1-time links will NOT allow retrieving link data without securing the queue at the same time, preventing undetected access by observers.
-- Entity ID is LinkId
LKEY :: SndPublicAuthKey -> Command Sender

-- If queue mode is QRMessaging the command will fail.
-- Entity ID is LinkId
LCON :: Command Sender

-- Response to LGET, LSKEY and LSGET
-- Entity ID is the same as in the command
LINK :: SenderId -> QueueLinkData -> BrokerMsg
```

To both include sender_id into the full link before the server response, and to prevent "oracle attack" when a failure to create the queue with the supplied `sender_id` can be used as a proof of queue existense, it is proposed that `sender_id` is computed client-side as `sha3-256(correlation_id)` and validated server-side, where `corelation_id` is the transmission correlation ID.

To allow retries and to avoid regenerating all queue data, NEW command must be idempotent, and `correlation_id` must be preserved in command for queue creation, so that the same `correlation_id` and all other data is used in retries. `correlation_id` should be removed after queue creation success.

To allow retries, every time the command is sent a new random `correlation_id` and new `sender_id` / `link_id` should be used on each attempt, because other IDs would be generated randomly on the server, and in case the previous command succeeded on the server but failed to be communicated to the client, the retry will fail if the same ID is used.

Alternative solutions considered and rejected:
- additional request to save queue data, after `sender_id` is returned by the server. The scenarios that require short links are interactive - creating user addresses and 1-time invitations - so making two requests instead of one would make the UX worse.
- include empty sender_id in the immutable data and have it replaced by the accepting party with `sender_id` received in `LINK` response - both a weird design, and might create possibility for some attacks via server, especially for contact addresses.
- making NEW commands idempotent. Doing it would require generating all IDs client-side, not only `sender_id`. It increases complexity, and it is not really necessary as the only scenarios when retries are needed are async NEW commands, that do not require short links. For future short links of chat relays the retries are much less likely, as chat relays will have good network connections.

## Algorithm to prepare and to interpret queue link data.

For contact addresses this approach follows the design proposed in [Short links](./2024-06-21-short-links.md) RFC - when link id is derived from the same random binary as key. For 1-time invitations link ID is independent and server-generated, to prevent existense checks.

**Prepare queue link data**

- the queue owner generates a random 256 bit `link_key` that will be used in the link URI.
- for 1-time links: crypto_box key and 2 nonces to encrypt link data are derived from link_uri using HKDF: `cb_key <> nonce1 <> nonce2 = HKDF(link_key, 80 bytes)` (nonce1 is used for immutable and nonce2 for user-defined parts).
- for contact address links: key and 2 nonces and linkId will be derived: `link_id <> cb_key <> nonce1 <> nonce2 = HKDF(link_key, 104 bytes)`
- both parts of link data are encrypted with crypto_box, and included into `NEW` or `LNEW` commands.

**Retrieving queue link data**

- the sender uses `LinkId` from URI (or derived from URI) as entity ID to retrieve link data.
- for one time links the sender must authorize the request to retrieve the data, the key is provided with the first request, preventing undetected access by link observers.
- having received the link data, the client can now decrypt it using secret_box.

## Improved algorithm to prepare and to interpret queue link data.

This scheme reduces the size of the binary in the link from 48 bytes (72 in case of 1-time links) to 32 bytes (56 bytes for 1-time links).

For immutable data.

1. `link_key = SHA3-256(immutable_data)` - used as part of link, and to encrypt content.
2. HKDF:
  1) contact address: `(link_id, key) = HKDF(link_key, 56 bytes)`.
  2) 1-time invitation: `key = HKDF(link_key, 32 bytes)`, `link-id` - server-generated. 
3. 
3. Random `nonce1` (for immutable data), to be stored with the link data.
4. Encrypt: `(ct1, tag1) = secret_box(immutable_data, key, nonce1)`.
5. Store: `(nonce1, ct1, tag1)` stored as immutable link data.

For mutable user data:

1. Random `nonce2` and the same key are used.
2. Sign `user_data` with key included in `immutable_data`.
3. Encrypt: `(ct2, tag2) = secret_box(signed_used_data, key, nonce2)`.
4. Store: `(nonce2, ct2, tag2)`

Link recipient:

1. Receives `link_key` in the link, for 1-time invitations also `link_id`.
2. HKDF:
  1) contact address: `(link_id, key) = HKDF(link_key, 56 bytes)`.
  2) 1-time invitation: `key = HKDF(link_key, 32 bytes)`.
3. Retrieves via `link_id`: `(nonce1, ct1, tag1)` and `(nonce2, ct2, tag2)`.
4. Decrypt: `immutable_data = decrypt (nonce1, ct1, tag1)`.
5. Verify: `SHA3-256(immutable_data) == link_key`, abort if not.
6. Decrypt: `signed_used_data = decrypt(nonce2, ct2, tag2)`
7. Verify signature with key in immutable data.

While using content hash as encryption key is unconventional, it is not completely unheard of - e.g., it is used in convergent encryption (although in our case using random nonce makes it not convergent, but other use cases suggest that this approach preserves encryption security). It is particularly acceptable for our use case, as `immutable_data` contains mostly random keys.

## Threat model

**Compromised SMP server**

can:
- delete link data.
- hide link selectively from some requests.

cannot:
- undetectably replace link data, even if they have the link (objective 3).
- access unencrypted link data, whether it was or was not accessed by the accepting party, provided it has no link (objective 2).
- observe IP addresses of the users accessing link data, if private routing is used.

**Passive observer who observed short link**:

can:
- access original unencrypted link data for contact address links.

cannot:
- undetectably access observed 1-time link data, accessing the link would make the link inaccessible to the sender (objective 5).
- undetectbly check the existense of messaging queue or 1-time link (objective 8).
- replace or delete the link data.

**Queue owner who did not comprmise the server**:

cannot:
- redirect connecting user to another queue, on the same or on another server (objective 1).
- replace connection request in the link (objective 4).

## Correlation of design objectives with design elements

1. The presense of `SenderId` in `LINK` response from the server.
2. Encryption of link data with crypto_box.
3. Auth tag in the link prevents server modification of immutable part of link data. Signature verification key in immutable part, and signing of mutable part prevents server modification of mutable part of link data.
4. No server command to change immutable part of link data once it's set.
5. 1-time link data can only be accessed with `LKEY` command, that while allows retries to mitigate network failures, will require the same key for retries.
6. `LSET` command.
7. The link only includes auth tag for immutable part, mutable part includes signature.
8. Temporarily public IDs (SenderId and LinkId for 1-time invitations) are generated server-side, and cannot be provided by the clients when creating the queues to check if these IDs are free.

## Syntax for short links

The proposed syntax:

```abnf
shortConnectionLink = %s"https://" smpServerHost "/" linkUri [ "?" param *( "&" param ) ]
smpServerHost = <hostname> ; RFC1123, RFC5891
linkUri = %s"i#" serverInfo oneTimeLinkBytes / %s"c#" serverInfo contactLinkBytes
oneTimeLinkBytes = <base64url(linkId | linkKey)> ; 56 bytes / 75 base64 encoded characters
contactLinkBytes = <base64url(linkKey)> ; 32 bytes / 43 base64 encoded characters
; linkId - 96 bits/24 bytes
; linkKey - 256 bits/32 bytes

serverInfo = [fingerprint "@" [hostnames "/"]] ; not needed for preset servers, required otherwise - the clients must refuse to connect if they don't have fingerprint in the code.

fingerprint = <base64url(server offline certificate fingerprint)>
hostnames = "h=" <hostname> *( "," <hostname> ) ; additional hostnames, e.g. onion
```

To have shorter links fingerpring and additional server hostnames do not need to be specified for preconfigured servers, even if they are disabled - they can be used from the client code. Any user defined servers will require including additional hosts and server fingerprint.

Example one-time link for preset server (103 characters):

```
https://smp12.simplex.im/i#abcdefghij0123456789abcdefghij0123456789abcdefghij0123456789abcdefghij01234
```

Example contact link for preset server (71 characters):

```
https://smp12.simplex.im/c#abcdefghij0123456789abcdefghij0123456789abc
```

Example contact link for user-defined server (with fingerprint, but without onion hostname - 115 characters):

```
https://smp1.example.com/c#0YuTwO05YJWS8rkjn9eLJDjQhFKvIYd8d4xG8X1blIU@abcdefghij0123456789abcdefghij0123456789abc
```

Example contact link for user-defined server (with fingerprint ant onion hostname - 178 characters):

```
https://smp1.example.com/c#0YuTwO05YJWS8rkjn9eLJDjQhFKvIYd8d4xG8X1blIU@beccx4yfxxbvyhqypaavemqurytl6hozr47wfc7uuecacjqdvwpw2xid.onion/abcdefghij0123456789abcdefghij0123456789abc
```

For the links to work in the browser the servers must provide server pages.
