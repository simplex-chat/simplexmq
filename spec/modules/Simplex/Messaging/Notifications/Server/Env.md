# Simplex.Messaging.Notifications.Server.Env

> NTF server environment: configuration, subscriber state, and push provider management.

**Source**: [`Notifications/Server/Env.hs`](../../../../../../src/Simplex/Messaging/Notifications/Server/Env.hs)

## Non-obvious behavior

### 1. Service credentials are lazily generated

`mkDbService` in `newNtfServerEnv` generates service credentials on demand: when `getCredentials` is called for an SMP server, it first checks the database. If credentials exist, they are used. If not (`Nothing`), new credentials are generated via `genCredentials`, stored in the database, and returned. This happens per SMP server on first connection.

Service credentials are only used when `useServiceCreds` is enabled in the config.

### 2. PPApnsNull creates a no-op push client

`newPushClient` checks `apnsProviderHost` for the push provider. `PPApnsNull` returns `Nothing`, which creates a no-op client (`\_ _ -> pure ()`). Real providers create an actual APNS connection. This is the mechanism that allows `PPApnsNull` tokens to function without push infrastructure.

### 3. getPushClient lazy initialization

`getPushClient` looks up the push client by provider in `pushClients` TMap. If not found, it calls `newPushClient` to create and register one. Push provider connections are established on first use, not at server startup.
