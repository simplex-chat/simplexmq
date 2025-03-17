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
    connMode :: ConnectionMode,
    ntfRequest :: Maybe NtfRequest,
    queueLink :: Maybe QueueLink
  }

-- An existing type.
-- CMInvitation implies that sender can secure the queue.
data ConnectionMode = CMInvitation | CMContact

-- replaces NKEY command, includes NotifierId, it will be DRG-generated client-side.
data NtfRequest = NtfRequest NotifierId NtfPublicAuthKey RcvNtfPublicDhKey

-- LinkId is derived from private key passed to accepting party (sender) in the link, see below.
-- SenderId is DRG-generated.
data QueueLink = QueueLink LinkId SenderId EncLinkData

newtype EncLinkData = EncLinkData ByteString -- encrypted link data

data LinkData = LinkData
  { connReq :: AConnectionRequestUri,
    -- We need to use binary encoding for AConnectionRequestUri to reduce its size
    -- connReq including the full link allows connection redundancy.
    -- Technically, it would allow clients to point to queue on another server.
    -- But clients should reject addresses when the primary queue is on a different server.
    -- Clients could also warn when any of the queues is on unknown operator.
    userData :: ByteString -- the max size needs to be estimated, but it is likely to be ~ 14kb
  }

-- | Updated queue IDs and keys, returned in IDS response
data QueueIdsKeys = QIK
  { rcvId :: RecipientId,
    linkId :: Maybe LinkId, -- same as in ShortLink
    sndId :: SenderId, -- same as in ShortLink or random
    rcvPublicDhKey :: RcvPublicDhKey,
    sndSecure :: SenderCanSecure, -- possibly, can be removed? or implied?
    serverNtfCreds :: Maybe ServerNtfCreds -- currently returned in NID response
  }

data ServerNtfCreds = ServerNtfCreds NotifierId RcvNtfPublicDhKey -- same NotifierId as in NtfRequest
```

There was a consideration that the full invitation link can be hosted on a different server, but this is not proposed, as while it can potentially improve transport anonymity, it reduces reliability and also may reduce transport privacy of accepting party.

In addition to that we would add the command allowing to update and also to retrieve and, optionally, secure the queue sender ID and data in one request, to reduce rountrips:

```haskell
LSET :: EncLinkData -> Command Recipient

-- with LinkId as entity ID, if queue does not allow sndSecure the command will fail, same as SKEY
LGET :: Maybe SndPublicAuthKey -> Command Sender

LINK :: QueueLink -> BrokerMsg
```

## Algorithm to prepare and to interpret queue link data.

This follows the design proposed in [Short links](./2024-06-21-short-links.md) RFC.

**Prepare queue link data**

- the data blob owner generates X25519 key pair: `(k, pk)`.
- private key `pk` will be included in the short link shared with the other party (only base64url encoded key bytes, not X509 encoding).
- `HKDF(pk)` will be used to encrypt the link data with secret_box before storing it on the server.
- the hash of public key `sha256(k)` will be used as ID by the owner to update the link data and by the accepting party to get link (`LSET` and `LGET` commands).

**Retrieving queue link data**

- the sender uses the public key `k` derived from the private key `pk` included in the link as entity ID to retrieve link data (the server will compute the ID used by the owner as `sha256(k)` and will be able to look it up). This provides the quality that the traffic of the parties has no shared IDs inside TLS. It also means that unlike message queue creation, the ID to retrieve the link data was never sent to the creator, and also is not known to the server in advance (the second part is only an observation, in itself it does not increase security, as server has access to an encrypted blob anyway).
- note that the sender does not authorize the request to retrieve the blob, as it would not increase security unless a different key is used to authorize, and adding a key would increase link size.
- server session keys with the sender will be `(sk, spk)`, where `sk` is public key shared with the sender during session handshake, and `spk` is the private key known only to the server.
- this public key `k` will also be combined with server session key `spk` using `dh(k, spk)` to encrypt the response, so that there is no ciphertext in common in sent and received traffic for these blobs. Correlation ID will be used as a nonce for this encryption.
- having received the blob, the client can now decrypt it using secret_box with `HKDF(pk)`.

Using the same key as ID for the request, and also to additionally encrypt the response allows to use a single key in the link, without increasing the link size.

## Threat model

See [Short links](./2024-06-21-short-links.md) RFC.

## Syntax for short links

The proposed syntax:

```abnf
shortConnectionRequest = %s"https://" smpServerHost "/" connReqType "#/" linkKey [ "?" param *( "&" param ) ]
smpServerHost = <hostname> ; RFC1123, RFC5891
connReqType = %s"i" / %s"invitation" / %s"c" / %s"contact"
linkKey = <base64url encoded private key data>

param = fingerprintParam / hostsParam
fingerprintParam = "f=" fingerprint ; server fingerprint
hostsParam = "h=" <hostname> *( "," <hostname> ) ; additional hostnames, e.g. onion
```

To have shorter links fingerpring and additional server hostnames do not need to be specified for preconfigured servers, even if they are disabled - they can be used from the client code.

Example link:

```
https://smp8.simplex.im/c/#abcdefghij0123456789abcdefghij0123456789abc
```

For the above to work in the browser the servers should serve server pages.
