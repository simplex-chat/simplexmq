# Protocol changes for creating and connecting to SMP queues

## Problems

This change is related to these problems:
- differentiating queue retention time,
- supporting MITM-resistant short connection links,
- improving notifications.

This RFC is based on the previous discussions about short links and blob storage ([1](./2024-06-21-short-links.md), [2](./2024-09-09-smp-blobs.md), [3](./2024-11-25-queue-blobs-2.md)).

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
8. retain the quality that it is impossible to check the existense of secured queue from having any of its IDs - this requires that IDs remain server-generated (contrary to the previous RFCs).

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

Proposed NEW command replaces SenderCanSecure with QueueType, adds LinkId and SenderId, and combines NKEY command:

```haskell
NEW :: NewQueueRequest -> Command Recipient

data NewQueueRequest = NewQueueRequest
  { rcvAuthKey :: RcvPublicAuthKey,
    rcvDhKey :: RcvPublicDhKey,
    basicAuth :: Maybe BasicAuth,
    subMode :: SubscriptionMode,
    queueMode :: QueueMode,
    ntfRequest :: Maybe NtfRequest,
    linkData :: QueueLinkData
  }

-- To allow updating the existing contact addresses without changing them.
-- With RecipientId as entity ID.
-- The response to this command is `LID` that includes LinkId
LNEW :: Maybe LinkId -> QueueLinkData -> Command Recipient

LID :: LinkId -> BrokerMsg

-- QMInvitation implies that sender can secure the queue.
-- LinkId is not used with QMInvitation, to prevent the possibility of checking when connection is established by re-using the same ID (the command should fail if it is used).
-- LinkId is used with QMInvitation, to have shorter link - it will be derived from the link_uri
data QueueMode = QMInvitation | QMContact LinkId

-- replaces NKEY command, includes NotifierId, it will be DRG-generated client-side.
data NtfRequest = NtfRequest NtfPublicAuthKey RcvNtfPublicDhKey

data QueueLinkData = QueueLinkData (Encrypted ImmutableLinkData) (Encrypted UserLinkData)

newtype Encrypted a = Encrypted a -- encrypted data

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

In addition to that we would add the command allowing to update and also to retrieve and, optionally, secure the queue sender ID and data in one request, to reduce rountrips:

```haskell
-- with RecipientId as entity ID, the command to update mutable part of link data
LSET :: Encrypted UserLinkData -> Command Recipient

-- To be used with 1-time links.
-- Sender's key provided on the first request prevents observers from undetectably accessing 1-time link data.
-- If queue mode is QMContact (and queue does NOT allow sndSecure) the command will fail, same as SKEY.
-- Once queue is secured, the key must be the same - to allow retries in case of network failures, and to prevent passive attacks.
-- The difference with securing queues, is that queues allow sending unsecured messages to queues that allow sndSecure (for backwards compatibility), and 1-time links will not allow retrieving link data without securing the queue at the same time.
-- Entity ID is LinkId here
LKEY :: SndPublicAuthKey -> Command Sender

-- If queue mode is QMInvitation the command will fail.
-- Entity ID is LinkId here
LGET :: Command Sender

-- Response to LKEY and LGET
-- Entity ID is LinkId here
LINK :: SenderId -> QueueLinkData -> BrokerMsg
```

## Algorithm to prepare and to interpret queue link data.

This follows the design proposed in [Short links](./2024-06-21-short-links.md) RFC.

**Prepare queue link data**

- the queue owner generates a random 256 bit `link_key` that will be used in the link URI.
- for 1-time links: key and 2 nonces to encrypt link data are derived from link_uri using HKDF: `key <> nonce1 <> nonce2 = HKDF(link_key, 80 bytes)` (nonce1 is used for immutable and nonce2 for user parts).
- for contact address links: key and 2 nonces and linkId will be derived: `key <> nonce1 <> nonce2 <> link_id = HKDF(link_key, 104 bytes)`
- both parts of link data are encrypted with crypto_box, and included into `NEW` or `LNEW` commands.

**Retrieving queue link data**

- the sender uses `LinkId` from URI as entity ID to retrieve link data.
- for one time links the sender authorizes the request to retrieve the data.
- having received the link data, the client can now decrypt it using secret_box with `HKDF(link_key)`.

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
- undetectably access observed link data, accessing the link would make the link inaccessible to the sender (objective 5).
- undetectbly check the existense of queue or link.
- replace or delete the link data.

**Queue owner who did not comprmise the server**:

cannot:
- redirect connecting user to another queue, on the same or on another server (objective 1).
- replace connection request in the link (objective 4).

## Syntax for short links

The proposed syntax:

```abnf
shortConnectionLink = %s"https://" smpServerHost "/" linkUri [ "?" param *( "&" param ) ]
smpServerHost = <hostname> ; RFC1123, RFC5891
linkUri = %s"i#" oneTimeLinkBytes / %s"c#" contactLinkBytes
oneTimeLinkBytes = <base64url(linkId | linkKey | linkAuthTag)> ; 80 base64 encoded characters
contactLinkBytes = <base64url(linkKey | linkAuthTag)> ; 64 base64 encoded characters
; linkId - 96 bits/24 bytes
; linkKey - 256 bits/32 bytes
; linkAuthTag - 128 bits/16 bytes auth tag from encryption of immutable link data>

param = fingerprintParam / hostsParam
fingerprintParam = "f=" fingerprint ; server fingerprint
hostsParam = "h=" <hostname> *( "," <hostname> ) ; additional hostnames, e.g. onion
```

To have shorter links fingerpring and additional server hostnames do not need to be specified for preconfigured servers, even if they are disabled - they can be used from the client code. Any user defined servers will require including additional hosts and server fingerprint.

Example one-time link (108 characters):

```
https://smp12.simplex.im/i#abcdefghij0123456789abcdefghij0123456789abcdefghij0123456789abcdefghij0123456789
```

Example contact link (92 characters):

```
https://smp12.simplex.im/c#abcdefghij0123456789abcdefghij0123456789abcdefghij0123456789abcd
```

For the above to work in the browser the servers should serve server pages.
