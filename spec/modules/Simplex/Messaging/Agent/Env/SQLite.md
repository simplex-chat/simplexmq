# Simplex.Messaging.Agent.Env.SQLite

> Agent environment configuration, default values, and worker/supervisor record types.

**Source**: [`Agent/Env/SQLite.hs`](../../../../../../src/Simplex/Messaging/Agent/Env/SQLite.hs)

## mkUserServers — silent fallback on all-disabled

See comment on `mkUserServers`. If filtering servers by `enabled && role` yields an empty list, `fromMaybe srvs` falls back to *all* servers regardless of enabled/role status. This prevents a configuration where all servers are disabled from leaving the user with no servers — but means disabled servers can still be used if every server in a role is disabled.
