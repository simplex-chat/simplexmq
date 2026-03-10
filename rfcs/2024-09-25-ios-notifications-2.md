# iOS notifications delivery

## Problem

For iOS notifications to be delivered the client has to create credentials for notification subscription on SMP router using NKEY command and after that create a subscription on notification router using SNEW command. These two commands are sent in sequence, after the connections are created, and for it to happen the client needs to be online and in foreground.

iOS users tend to close the app when it is not used, and iOS has very limited permissions for background activities, so these notification subscriptions are created with a substantial delay, and notifications do not work.

This problem is distinct from and probably more common than other problems affecting notifications delivery described [here](./2024-07-06-ios-notifications.md).

## Solution

1. When the new connection is created, the client already knows if it needs to create notification subscription or not, based on the conversation setting (e.g., if the group is muted, the client will not create notification subscription as well.). We should extend NEW command to avoid the need to send additional NKEY command with an option to create notification subscription at the point where connection is created. NDEL would still be used to disable this notification, and NKEY will be used to re-enable it.

2. In the same way we stopped using SDEL command (NDEL sends notification DELD to subscribed notification router) to delete notificaiton subscriptions from notification router, we should delegate creating notification subscription on notification router to SMP routers. Clients could use keys agreed with ntf router for e2e encryption and for command authorization to encrypt and sign instruction to create notification subscription that will be forwarded to notification router using protocol similar to SMP proxies. This will avoid the need for clients to separately contact notification routers that won't happen until they are online.

3. Instead of making Ntf router trust DELD notifications, we could send deletion instructions signed by the client, which will only fail to send in case notification router is down (and they won't be sent later after router restart).

Cons:
- If SMP routers were to retain in the storage the information about which notification router is used for which queue, it would reduce metadata privacy. While currently it is not an issue, as all notification routers are known and operated by us, once there are other client apps, this can be used for app users fingerprinting, which would act as a deterrence from using new apps – but only if app users use routers of operators who are different from the app provider. To mitigate it, we could only store it in router memory and include notification instruction in subscription commands (SUB) and include notification subscription status in SUB responses. We don't need to mitigate the problem of router being able to store this information, as messaging routers can observe which notification routers connect to them anyway.
- If SMP router is restarted before the subscription request is forwared to the notification router, then it will have to be forwarded again, once the client subscribes. The problem here is that if the client is offline, it will neither subscribe to the queue to send notification subscription request, nor receive notifications from this queue. Storing notification router and subscription request would mitigate that, as in this case we could send all pending requests on router start, without depending on client subscriptions.
- "Small" agent will need to support connections to ntf routers and manage workers that retry sending pending subscription requests.
- Until the client learns the public keys of notification router, it will not be able to decrypt notifications. It potentially can be mitigated by using the public key of the router returned when token is created, in this way different client keys (per-queue) will be combined with the same ntf router key (per-token).

## Implementation details

1. NEW and NKEY commands will need to be extended to include notification subscription request. As the notifier ID needs to be sent to notification router, this notifier ID will have to be client-generated and supplied as part of NEW command.

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

2. Notification router will need to support an additional command to receive "proxied" subscription commands, `SFWD`, that would include `NtfServerRequest`. This command can include both `SNEW` and `SDEL` commands.
