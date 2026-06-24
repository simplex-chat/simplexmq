# Simplex.Messaging.Agent.Store.Interface

> CPP-conditional re-export of the active database backend (SQLite or PostgreSQL).

**Source**: [`Agent/Store/Interface.hs`](../../../../../../src/Simplex/Messaging/Agent/Store/Interface.hs)

No non-obvious behavior. See source. One of three CPP re-export wrappers (Interface, Common, DB) that select the active backend at compile time via `dbPostgres`.
