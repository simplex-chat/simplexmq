# iOS notifications delivery

## Problem

For iOS notifications to be delivered the client has to create credentials for notification subscription on SMP server using NKEY command and after that create a subscription on notification server using SNEW command. These two commands are sent in sequence, after the connections are created, and for it to happen the client needs to be online and in foreground.

iOS users tend to close the app when it is not used, and iOS has very limited permissions for background activities, so these notification subscriptions are created with a substantial delay, and notifications do not work.

This problem is distinct from and probably more common than other problems affecting notifications delivery described [here](./2024-07-06-ios-notifications.md).

## Solution

1. When the new connection is created, the client already knows if it needs to create notification subscription or not, based on the conversation setting (e.g., if the group is muted, the client will not create notification subscription as well.). We should extend NEW command to avoid the need to send additional NKEY command with an option to create notification subscription at the point where connection is created. NDEL would still be used to disable this notification, and NKEY will be used to re-enable it.

2. In the same way we stopped using SDEL command (NDEL sends notification DELD to subscribed notification server) to delete notificaiton subscriptions from notification server, we should delegate creating notification subscription on notification server to SMP servers. Clients could use keys agreed with ntf server for e2e encryption and for command authorization to encrypt and sign instruction to create notification subscription that will be forwarded to notification server using protocol similar to SMP proxies. This will avoid the need for clients to separately contact notification servers that won't happen until they are online.

3. Instead of making Ntf server trust DELD notifications, we could send deletion instructions signed by the client, which will only fail to send in case notification server is down (and they won't be sent later after server restart).

Cons:
- If SMP servers were to retain in the storage the information about which notification server is used for which queue, it would reduce metadata privacy. While currently it is not an issue, as all notification servers are known and operated by us, once there are other client apps, this can be used for app users fingerprinting, which would act as a deterrence from using new apps – but only if app users use servers of operators who are different from the app provider. To mitigate it, we could only store it in server memory and include notification instruction in subscription commands (SUB) and include notification subscription status in SUB responses. We don't need to mitigate the problem of server being able to store this information, as messaging servers can observe which notification servers connect to them anyway.
- If SMP server is restarted before the subscription request is forwared to the notification server, then it will have to be forwarded again, once the client subscribes. The problem here is that if the client is offline, it will neither subscribe to the queue to send notification subscription request, nor receive notifications from this queue. Storing notification server and subscription request would mitigate that, as in this case we could send all pending requests on server start, without depending on client subscriptions.
- "Small" agent will need to support connections to ntf servers and manage workers that retry sending pending subscription requests.
- Until the client learns the public keys of notification server, it will not be able to decrypt notifications. It potentially can be mitigated by using the public key of the server returned when token is created, in this way different client keys (per-queue) will be combined with the same ntf server key (per-token).

## Implementation details

1. NEW and NKEY commands will need to be extended to include notification subscription request. As the notifier ID needs to be sent to notification server, this notifier ID will have to be client-generated and supplied as part of NEW command.

now:

```haskell
NEW :: RcvPublicAuthKey -> RcvPublicDhKey -> Maybe BasicAuth -> SubscriptionMode -> SenderCanSecure -> Command Recipient
NKEY :: NtfPublicAuthKey -> RcvNtfPublicDhKey -> Command Recipient
```

extended:

```haskell
NEW :: RcvPublicAuthKey -> RcvPublicDhKey -> Maybe BasicAuth -> SubscriptionMode -> SenderCanSecure -> Maybe NtfRequest -> Command Recipient

data NtfRequest = NtfRequest NotifierId NtfPublicAuthKey RcvNtfPublicDhKey NtfServerRequest

data NtfServerRequest = NtfServerRequest NtfServer EncSingedNtfCmd

NKEY :: NtfPublicAuthKey -> RcvNtfPublicDhKey -> Maybe NtfServerRequest -> Command Recipient
-- NotifierID is passed in entity ID field of the transmission
```

Instead of client generating keys for request, SMP server could generate them itself before forwarding request to notifications server.

2. SMP server has to differentiate legacy queues and queues using new notifications protocol, for example by saving notifications server on queue record.

For sending notifications, subscriptions mechanism could be replaced with direct push to notifications protocol.

3. Notification server will need to support an additional command to receive "proxied" subscription commands, `SFWD`, that would include `NtfServerRequest`. This command can include both `SNEW` and `SDEL` commands.

Notifications server has to process NMSG in form of forwarded request from SMP server (in addition to processing it in subscriptions loop). Notifications "subscription" record in that case would be used only for bookkeeping, for example, finding token (not for making subscriptions to SMP server via NSUB).
