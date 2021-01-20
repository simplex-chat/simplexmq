# Code organization proposal

Thoughts on reorganizing existing codebase:
- Move types and functions shared between SMP Server and SMP Agent to `Simplex/Messaging/Common`. Shared types are mostly types from `Server/Transmission` used in Agent and `Agent/Store`. Shared functions are SMP parsers. Maybe something else?
- Separate parsers and serializers from Transmission, moving them into separate modules, e.g. for agent related ones to `Simplex/Messaging/Agent/SerDe.hs`?
- For bigger modules decrease amount of functions per module, moving some inner (`where`) and reused functions to submodules, for example for Store utility methods to `Store/Utils.hs`, probably for Agent - to `Agent/Commands.hs`.
- Move modules under similarly named folders? E.g. `Store.hs` under `Simplex/Messaging/Store`, `SQLite.hs` under `Simplex/Messaging/Store/SQLite`, etc. Same for server modules.
- Minor, but rename `Simplex/Messaging` into `SMP`?
- Reorganize functions and types inside a module so that reading from top to bottom the first ones are the ones it wants to implement following with auxiliary ones, so that it then can be read from top to bottom without losing context about the latter? So kind "public" first, "private" after to go from general to specific? Also explicitly expose module members.

With proposed changes tree of the project looking close to the following:

    SMP
    ├── Agent
    │   ├── Env
    │   │   └── SQLite.hs
    │   ├── Store
    │   │   ├── SQLite
    │   │   │   ├── Schema.hs
    │   │   │   └── SQLite.hs
    │   │   └── Store.hs
    │   ├── SerDe.hs
    │   ├── Transmission.hs
    │   ├── Agent
    │   │   ├── Agent.hs
    │   │   └── Commands.hs
    │   ...
    │   └── ...
    │
    ├── Common
    │   ├── Types.hs
    │   ├── SerDe.hs
    │   ...
    │   └── ...
    │
    └── Server
        ├── ...
        ...
        └── ...

## Other concerns

- Possibly remove `Connection` types, instead operate only on queues and connection alias.
- Use naming convention to designate direction of communication in the function name, especially for agent functions? E.g. `sendMsgToServer`, `respondToClient`.
- TODO error types
