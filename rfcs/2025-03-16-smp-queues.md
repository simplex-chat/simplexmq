# Protocol changes for creating and connecting to SMP queues

## Problems

This change is related to these problems:
- differentiating queue retention time,
- supporting MITM-resistant short connection links,

This RFC is based on the previous discussions about short links, blob storage and notifications ([1](./2024-06-21-short-links.md), [2](./2024-09-09-smp-blobs.md), [3](./2024-11-25-queue-blobs-2.md), [4](./2024-09-25-ios-notifications-2.md)).

SMP protocol supports two types of queues - queues to send messages (messaging queues) and queues to send invitations to connect (contact queues). While SMP protocol was originally "unaware" of these queue types, it could differentiate it by message flow, and with the recent addition of SKEY command to allow securing the queue by the sender this difference became persistent.

Simply designating queue types would allow to use this information to decide for how long to retain queues, and potentially extending it:
- unsecured 1-time invitation queues with sndSecure (support of securing by sender) - e.g., 3 months.
- contact address queues without sndSecure - e.g., 3 years without activity.
- Possibly, "queues" that prohibit messages and used only as blob storage - they would be used to store group profiles and super-peer addresses for the group.

## Design objectives

We want to achieve these objectives for short links and associated queue data:
1. no possibility to provide incorrect SenderId inside link data (e.g. from another queue).
2. link data cannot be accessed by the server unless it has the link.
3. prevent MITM attack by the server, including the server that obtained the link.
4. prevent changing of connection request by the user (to prevent MITM via break-in attack in the originating client).
5. for one-time links, prevent accessing link data by link observers who did not compromise the server.
6. allow changing the user-defined part of link data.
7. avoid changing the link when user-defined part of link data changes, while preventing MITM attack by the server on user-defined part, even if it has the link.
8. retain the quality that it is impossible to check the existence of secured queue from having any of its temporary visible IDs (sender ID and link ID in 1-time invitations) - it requires that these IDs remain server-generated (contrary to the previous RFCs).

To achieve these objectives the queue data will include fixed (immutable) and user-defined (mutable) parts.

Fixed part would include:
- full connection request (the current long link with all keys, including PQ keys). This includes SenderId that must match server response.
- public signature key to verify mutable part of link data.

Signed mutable part would include:
- any links to chat relays that should be contacted instead of this queue (not in this RFC), to allow delegating group connections and contact request connections to prevent spam, hiding online presence, etc.
- and user-defined data - user profile or group profile, chat preferences, welcome message, etc.

The link itself should include both the key and auth tag from the encryption of immutable part. Accessing one-time link data should require providing sender key and signing the command (`LKEY`).

## Solution

Current NEW and NKEY commands:

```haskell
NEW :: RcvPublicAuthKey -> RcvPublicDhKey -> Maybe BasicAuth -> SubscriptionMode -> SenderCanSecure -> Command Recipient

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
    queueReqData :: Maybe QueueReqData,
  }

-- QRMessaging implies that sender can secure the queue.
-- LinkId is not used with QRMessaging, to prevent the possibility of checking when connection is established by re-using the same link ID when creating another queue – the creating would have to fail if it is used.
-- LinkId is required with QRContact, to have shorter link - it will be derived from the link_uri. And in this case we do not need to prevent checks that this queue exists.
data QueueReqData
  = QRMessaging (Maybe (SenderId, QueueLinkData))
  | QRContact (Maybe (LinkId, (SenderId, QueueLinkData)))

-- SenderId should be computed client-side as the first 24 bytes of sha3-384(correlation_id),
-- The server must verify it and reject if it is not.
-- It allows to include sender ID inside encrypted associated link data as part of full connection URI without requesting it from the server, but prevents checking if a given sender ID exists (queue creation would fail for a duplicate sender ID), as sha3-384 derivation is not reversible.
type QueueLinkData = (EncFixedLinkData, EncUserDataBytes)

type EncFixedLinkData = ByteString

type EncUserDataBytes = ByteString

-- We need to use binary encoding for ConnectionRequestUri to reduce its size
-- The clients would reject changed immutable data and
-- ConnectionRequestUri where server or SenderId of the queue do not match.
data FixedLinkData c = FixedLinkData
  { agentVRange :: VersionRangeSMPA,
    rootKey :: C.PublicKeyEd25519,
    connReq :: ConnectionRequestUri c
  }

data ConnLinkData c where
  InvitationLinkData :: VersionRangeSMPA -> UserLinkData -> ConnLinkData 'CMInvitation
  ContactLinkData ::
    { agentVRange :: VersionRangeSMPA,
      -- direct connection via connReq in fixed data is allowed.
      direct :: Bool,
      -- additional owner keys to sign changes of mutable data.
      owners :: [OwnerAuth],
      -- alternative addresses of chat relays that receive requests for this contact address.
      relays :: [ConnShortLink 'CMContact],
      userData :: UserLinkData
    } -> ConnLinkData 'CMContact

newtype UserLinkData = UserLinkData ByteString

-- | Updated queue IDs and keys, returned in IDS response
data QueueIdsKeys = QIK
  { rcvId :: RecipientId, -- server-generated
    sndId :: SenderId, -- server-generated
    rcvPublicDhKey :: RcvPublicDhKey,
    sndSecure :: SenderCanSecure, -- possibly, can be removed? or implied?
    linkId :: Maybe LinkId -- server-generated
  }
```

In addition to that we add the command allowing to update and also to retrieve and secure the queue and get link data in one request, to have only one request:

```haskell
-- This command allows to set all data or to update mutable part of contact address queue.
-- This command should fail on queues that support sndSecure and also on new queues created with QRMessaging.
-- This should fail if LinkId or immutable part of data is changed with the update, but will succeed if only mutable part is updated, so it can be retried.
-- Entity ID is RecipientId.
-- The response to this command is `OK`.
LSET :: LinkId -> QueueLinkData -> Command Recipient

-- Delete should link and associated data
-- Entity ID is RecipientId
LDEL :: Command Recipient

-- To be used with 1-time links.
-- Sender's key provided on the first request prevents observers from undetectably accessing 1-time link data.
-- If queue mode is QRContact (and queue does NOT allow sndSecure) the command will fail, same as SKEY.
-- Once queue is secured, the key must be the same in subsequent requests - to allow retries in case of network failures, and to prevent passive attacks.
-- The difference with securing queues is that queues allow sending unsecured messages to queues that allow sndSecure (for backwards compatibility), and 1-time links will NOT allow retrieving link data without securing the queue at the same time, preventing undetected access by observers.
-- Entity ID is LinkId
LKEY :: SndPublicAuthKey -> Command Sender

-- If queue mode is QRMessaging the command will fail.
-- Entity ID is LinkId
LGET :: Command Sender

-- Response to LGET and LSET
-- Entity ID is the same as in the command
LNK :: SenderId -> QueueLinkData -> BrokerMsg
```

To both include sender_id into the full link before the server response, and to prevent "oracle attack" when a failure to create the queue with the supplied `sender_id` can be used as a proof of queue existence, it is proposed that `sender_id` is computed client-side as the first 24 bytes of 48 in `sha3-384(correlation_id)` and validated server-side, where `corelation_id` is the transmission correlation ID.

To allow retries, every time the command is sent a new random `correlation_id` and new `sender_id` (and for contact queue, also `link_id`, which would be random as it is derived from hash of fixed link data that includes a random signature key) should be used on each attempt, because other IDs would be generated randomly on the server, and in case the previous command succeeded on the server but failed to be communicated to the client, the retry will fail if the same ID is used.

Alternative solutions that would allow retries that were considered and rejected:
- additional request to save queue data, after `sender_id` is returned by the server. The scenarios that require short links are interactive - creating user addresses and 1-time invitations - so making two requests instead of one would make the UX worse.
- include empty sender_id in the immutable data and have it replaced by the accepting party with `sender_id` received in `LINK` response - both a weird design, and might create possibility for some attacks via server, especially for contact addresses.
- making NEW commands idempotent. Doing it would require generating all IDs client-side, not only `sender_id`. It increases complexity, and it is not really necessary as the only scenarios when retries are needed are async NEW commands, that do not require short links. For future short links of chat relays the retries are much less likely, as chat relays will have good network connections.

## Algorithm to prepare and to interpret queue link data.

For contact addresses this approach follows the design proposed in [Short links](./2024-06-21-short-links.md) RFC - when link id is derived from the same random binary as key. For 1-time invitations link ID is independent and server-generated, to prevent existence checks (oracle attack).

This scheme results in 32 byte binary size for contact addresses and 56 bytes for 1-time invitation links.

For fixed link data.

1. Generate random `nonce` (also used as a correlation ID for server command) and signature key (public `rootKey` included in fixed data).
2. Compute sender ID from `nonce` as the first 24 bytes of sha3-384 of `nonce`.
3. Generate other keys for queue address, including queue e2e encryption keys and double ratchet connection e2e encryption keys.
4. Construct the full connection address to be included in fixed data.
5. `link_key = SHA3-256(fixed_data)` - used as part of the link, and to derive the key to encrypt content.
6. HKDF:
  1) contact address: `(link_id, key) = HKDF(link_key, 56 bytes)`.
  2) 1-time invitation: `key = HKDF(link_key, 32 bytes)`, `link-id` - server-generated.
7. Encrypt: `(ct1, tag1) = secret_box(fixed_data, key, nonce1)`, where `nonce1` is a random nonce
5. Store: `(nonce1, ct1, tag1)` stored as fixed link data.

For mutable user data:

1. Random `nonce2` and the same key are used.
2. Sign `user_data` with key included in `fixed_data`.
3. Encrypt: `(ct2, tag2) = secret_box(signed_used_data, key, nonce2)`.
4. Store: `(nonce2, ct2, tag2)`

Link recipient:

1. Receives `link_key` in the link, for 1-time invitations also `link_id`.
2. HKDF:
  1) contact address: `(link_id, key) = HKDF(link_key, 56 bytes)`.
  2) 1-time invitation: `key = HKDF(link_key, 32 bytes)`.
3. Retrieves via `link_id`: `(nonce1, ct1, tag1)` and `(nonce2, ct2, tag2)`:
  1) contact address: `LGET` command, that allows retrieving link data multiple times.
  2) 1-time invitation: `LKEY` command, that non-optionally secures the queue, and only allows repeated link data retrievals if the same sender's key is provided and signs the transmission. This prevents link data retrieval by link observers.
4. Decrypt: `(signature1, fixed_data) = decrypt (nonce1, ct1, tag1)`.
5. Verify: `SHA3-256(fixed_data) == link_key`, abort if not.
6. Decrypt: `(signature2, used_data) = decrypt(nonce2, ct2, tag2)`.
7. Verify signatures using key in the fixed data, abort if they don't match.

While using content hash as encryption key is unconventional, it is not completely unusual - e.g., it is used in convergent encryption (although in our case using random nonce makes it not convergent, but other use cases suggest that this approach preserves encryption security). It is particularly acceptable for our use case, as `fixed_data` contains mostly random keys.

## Threat model

**Compromised SMP server**

can:
- delete link data.
- hide link data selectively for some or for all requests.

cannot:
- undetectably replace link data, even if it has the link (objective 3).
- access unencrypted link data, whether it was or was not accessed by the accepting party, provided it has no link (objective 2).
- observe IP addresses of the users accessing link data, if private routing is used.

**Passive observer who observed short link**:

can:
- access original unencrypted link data for contact address links.

cannot:
- undetectably access observed 1-time link data, accessing the link would make the link inaccessible to the sender (objective 5).
- undetectably check the existence of messaging queue or 1-time link (objective 8).
- replace or delete the link data.

**Queue owner who did not compromise the server**:

cannot:
- redirect connecting user to another queue, on the same or on another server (objective 1).
- replace connection request in the link (objective 4).

## Correlation of design objectives with design elements

1. The presence of `SenderId` in `LNK` response from the server.
2. Encryption of link data with crypto_box.
3. Deriving encryption key from the hash of fixed data prevents it being modified by the server - any change would be detected and rejected by the client, as the hash of fixed data won't match the link. Signature verification with the key from fixed data, and signing of mutable data prevents server modification of mutable data.
4. No server command to change fixed data once it's set. Also, changing fixed data would require changing the link.
5. 1-time link data can only be accessed with `LKEY` command, that while allows retries to mitigate network failures, will require the same key for retries.
6. `LSET` command.
7. The link is derived from fixed data only, so it does not change when mutable link data changes. Mutable part is signed preventing server MITM attacks.
8. SenderId is derived from request correlation ID, so it cannot be arbitrary defined to check existence of some known queue. LinkId for 1-time invitation is generated server-side, so it cannot be provided by the client when creating the queues to check if these IDs are used.

## Syntax for short links

The syntax:

```abnf
shortConnectionLink = uriAuthority "/" linkUri [ "?" param *( "&" param ) ]
uriAuthority = %s"https://" smpServerHost / "simplex:" ; using simplex: scheme requires including host in the parameter hostParam
smpServerHost = <hostname> ; RFC1123, RFC5891
linkUri = %s"i#" oneTimeLink / contactType "#" contactLink
contactType = %s"a" / %s"g" / %s"c" ; contact / group / channel address, respectively
oneTimeLink = <base64url(linkId)> "/" <base64url(linkKey)> ; 56 bytes / 75 base64 encoded characters
contactLink = <base64url(linkKey)> ; 32 bytes / 43 base64 encoded characters
; linkId - 192 bits/24 bytes
; linkKey - 256 bits/32 bytes

param = hostsParam / portParam / certHashParam
hostsParam = %s"h=" host *("," host) ; additional hostnames, e.g. onion
portParam = %s"p=" 1*DIGIT ; server port
certHashParam = %s"c=" <base64url(server offline certificate fingerprint)>
```

To have shorter links fingerprint and additional server hostnames do not need to be specified for pre-configured servers, even if they are disabled - they can be used from the client code. Any user defined servers will require including additional hosts and server fingerprint.

Example one-time link for preset server (104 characters):

```
https://smp12.simplex.im/i#abcdefghij0123456789abcdefghij01/23456789abcdefghij0123456789abcdefghij01234
```

Example contact link for preset server (71 characters):

```
https://smp12.simplex.im/c#abcdefghij0123456789abcdefghij0123456789abc
```

Example contact link for user-defined server (with fingerprint, but without onion hostname - 117 characters):

```
https://smp1.example.com/c#abcdefghij0123456789abcdefghij0123456789abc?c=0YuTwO05YJWS8rkjn9eLJDjQhFKvIYd8d4xG8X1blIU
```

Example contact link for user-defined server (with fingerprint ant onion hostname - 182 characters):

```
https://smp1.example.com/c#abcdefghij0123456789abcdefghij0123456789abc?c=0YuTwO05YJWS8rkjn9eLJDjQhFKvIYd8d4xG8X1blIU&h=beccx4yfxxbvyhqypaavemqurytl6hozr47wfc7uuecacjqdvwpw2xid.onion
```

For the links to work in the browser the servers must provide server pages.
