# New notifications protocol

## Problem

iOS notifications have these problems:
- iOS notification service crashes exceeding memory limit. This is being addressed by changes in GHC RTS.
- there is a large number of connections, because each member in a group requires individual connection. This will improve with chat relays when each group would require 2-3 connections.
- some notification may be not shown if notification with reply/mention is skipped, and instead some other message is delivered, which may be muted. This would not improve without some changes, as notifications may be skipped anyway.
- client devices delay communication with ntf server because it is done in background, and by that time the app may be suspended.
- notification server represents a bottleneck, as it has to be owned by the app vendor, and the current design when ntf server subscribes to notifications scales very badly.

This RFC is based on the previous [RFC related to notifications](./2024-09-25-ios-notifications-2.md).

## Solution

As notification server has to know client token and currently it associates subscriptions with this token anyway, we are not gaining any privacy and security by using per-subscription keys - both authorization and encryption keys of notification subscription can be dropped.

We still need to store the list of queue IDs associated with the token on the notification server, but we do not need any per-queue keys on the notification server, and we don't need subscriptions - it's effectively a simple set of IDs, with no other information.

In this case, when queue is created the client would supply notifier ID - it has to be derived from correlation ID, to prevent existense check (see previous RFC). As we also supply sender ID, instead of deriving it as sha3-192 of correlation ID, they both can be derived as sha3-384 and split to two IDs - 24 bytes each.

The notification server will maintain a rotating list of server keys with the latest key communicated to the client every time the token is registered and checked. The keys would expire after, say, 1 week or 1 month, and removed from notification server on expiration.

The packet containing association between notifier queue ID and token will be crypto_box encrypted using key agreement between identified notification server master key and an ephemeral per packet (effectively, per-queue) client-key.

Deleting the queue may also include encrypted packet that would verify that the client deleted the queue.

Instead of notification server subscribing to the notifications creating a lot of traffic for the queues without messages, the SMP server would push notifications via NTF server connection (whether via NTF or via SMP protocol). This could be used as a mechanism to migrate existing queues when with the next subscription the notification server would communicate it's address to SMP server and this association would be stored together with the queue.

## Protocol design

Additional/changed SMP commands:

```haskell
-- register notification server
-- should be signed with server key
NSRV :: NtfServerCreds -> Command NtfServer

-- response
NSID :: NtfServerId -> BrokerMsg

-- to communicate which server is responsible for the queue
-- should be signed with queue key
NSUB :: Maybe NtfServerId -> Command Notifier

-- subscribe to notificaions from all queues associated with the server
-- should be signed with server key
-- entity ID - NtfServerId
NRDY :: Command NtfServer

data NtfServerCreds = NtfServerCreds
  { server :: NtfServer,
    -- NTF server certificate chain that should match fingerpring in address
    cert :: X.CertificateChain,
    -- server autorizatio key to sign server subscription requests
    authKey :: X.SignedExact X.PubKey
  }

-- entity ID is recipient ID
NSKEY :: NtfSubscription -> Command Recipient 

data NtfSubscription = NtfSubscription
  -- key to encrypt notifications e2e with the client
  { ntfPubDbKey :: RcvNtfPublicDhKey,
    ntfServer :: NtfServer,
    -- should be linked to correlation ID to prevent existense check
    -- the ID sent to notification server could be its hash?
    ntfId :: NotifierId,
    encNtfTokenAssoc :: EncDataBytes
  }

-- before the encryption - equivalent to NSUB command, but without key to authorize requests to specific queue
data NtfTokenAssoc = NtfTokenAssoc
  { signature :: SignatureEd25519,
    tknId :: NtfTokenId,
    ntfQueue :: SMPQueueNtf
  }
```

SMP server will need to maintain the list of Ntf servers and their credentials, and when NSSUB arrives to make only one subscription. When message arrives it would deliver notification to the correct connection via queue / ntf server association.

Ntf server needs to maintain three indices to the same data:
- `(smpServer, queueId) -> tokenId` - to deliver notification to the correct token
- `tokenId -> [smpServer -> [queueId]]` - to remove all queues when token is removed, and to store/update these associations effficiently - store log may have one compact line per token (after compacting), or per token/server combination.
- `[smpServer]` - array of SMP servers to subscribe to.

## Mention notifications

Currently we are marking messages with T (true) for messages that require notifications and F (false) for messages that don't require. Sender does not know whether the recipient has notifications disabled, enabled or in mentions-only mode.

The proposal is to:
- add additional values to this metadata, e.g. 2 (priority) and 3 (high priority) (and T/F could be sent as 0/1 respectively) - that is, to deliver notifications even if notifications are generally disabled (they can still be further filtered by the client).
- instead of deleting notification credentials when notifications are disabled - which is costly - communicate to SMP server the change of notificaion priority level, e.g. the client could set minimal notification priority to deliver notifications, where 0 would mean disabling it completely, 1 enable for all, 2 for priority 2+, 3 for priority 3. The downside here is that it could be used for timing correlation of queues in the group, but it already can be used on bulk deletions of ntf credentials for these queues and when sending messages.
