# Notification server

## Background and motivation

SimpleX Chat clients should receive message notifications when not being online and/or subscribed to SMP servers.

To avoid revealing identities of clients directly to SMP servers via any kind of push notification tokens, a new party called SimpleX Notification Server is introduced to act as a service for subscribing to SMP server queue notifications on behalf of clients and sending push notifications to them.

## Proposal

TCP service using the same TLS transport as SMP server, with the fixed size blocks (256 bytes?) and the following set of commands:

### Protocol

#### Create subscription

Command:

`%s"CREATE " ntfSmpQueueURI token subPublicKey`

Response:

`s%"ID " ntfSubscriptionId`

#### Check subscription status

Command:

`%s"CHECK " ntfSubscriptionId`

Response:

```abnf
statusResp = %s"STAT " status
status = %s"ERR AUTH" / "ERR SMP AUTH" / %s"ERR SMP TIMEOUT" / %s"ACTIVE" / %s"PENDING"
```

#### Update subscription device token

Command:

`%s"TOKEN " ntfSubscriptionId token`

Response:

`s%"OK" / %s"ERR"`

#### Delete subscription (e.g. when deleting the queue or moving to another notification server)

Command:

`%s"DELETE " SP ntfSubscriptionId`

Response:

`s%"OK" / %s"ERR"`

### Agent schema changes

See [migration](../src/Simplex/Messaging/Agent/Store/SQLite/Migrations/M20220322_notifications.hs)

### Agent code

```haskell
data NotificationOpts = NotificationOpts
  { ntfServer :: Server, -- same type as for SMP servers, probably will be renamed
    ntfToken :: ByteString,
    ntfInitialCheckDelay :: Int, -- initial check delay after subscription is created, seconds
    ntfPeriodicCheckInterval :: Int -- subscription check interval, seconds
  }

data AgentConfig = AgentConfig {
  -- ...
  notificationOpts :: TVar (Maybe NotificationOpts)
  -- ...
  }
```

A configuration parameter `notificationOpts :: TVar (Maybe NotificationOpts)` - if it is set or changes the agent would automatically manage subscriptions as SMP queues are subscribed/created/deleted and as the token or server changes.

There will be two loops - one to monitor the changes in the configuration parameters and another to manage subscriptions. Possibly, instead of the first look there would be a method to update it in which case AgentConfig would have the initial token/server and there would be a method to change them. Or possibly there should be no initial settings at all, as we don't know the token until we start? But we do know the server. Maybe they should be split into different types - initial configuration and token. The token will only be set once per application start and the server can change while the application is running.

All subscriptions will be managed in a separate subscription management loop, that would always take the earliest un-updated subscription that requires some action (ntf_sub_action column) and perform this action - the table of subscription would serve both as the table of existing subscriptions and required actions.

E.g. if the queue is subscribed and there is no notification subscription, it will be created in the table with "create" action, and the loop would create it and schedule "check" action on it.