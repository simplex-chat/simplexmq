# SQLite database migrations

These migrations are [embedded](../src/Simplex/Messaging/Agent/Store/SQLite/Migrations.hs) into the executable and run when SMP agent starts (as a separate executable or as a part of [simplex-chat](https://github.com/simplex-chat/simplex-chat) app).

Migration file names must have a format `YYYYMMDD-name.sql` - they will be executed in the order or lexicographic sorting of the names, the files with any other extension than `.sql` are ignored.

The proposed approach is to minimize the number of migrations and merge them together when possible, to align with the agent releases.

**Please note**: Adding or editing migrations will NOT update the migrations embedded into the executable, unless the [Migrations](../src/Simplex/Messaging/Agent/Store/SQLite/Migrations.hs) module is rebuilt - use `stack build --force-dirty` (in addition to edited files it seems to rebuild the files with TH splices and their dependencies, not all files as with `stack clean`).
