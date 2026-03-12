# Simplex.Messaging.Server.Main

> Server CLI entry point: dispatches Init, Start, Delete, Journal, and Database commands.

**Source**: [`Main.hs`](../../../../../src/Simplex/Messaging/Server/Main.hs)

## Overview

This is the CLI dispatcher for the SMP server. It parses INI configuration, validates storage mode combinations, and dispatches to the appropriate command handler. The most complex logic is storage configuration validation and migration between storage modes.

## Storage mode compatibility — state machine

`checkMsgStoreMode` and `iniStoreCfg` implement a state machine of valid storage mode combinations. Valid: Memory+Memory, Memory+Journal (deprecated), Postgres+Journal, Postgres+Postgres (with flag). Invalid: Memory+Postgres (queue store doesn't support it), Postgres+Memory (messages can't be in-memory with DB queues). Error messages guide the user toward migration commands. The validity is also enforced at the type level via `SupportedStore` in [Env/STM.md](./Env/STM.md#supportedstore--compile-time-storage-validation).

## INI parsing — error context loss

`readIniFile` errors are coerced to `String` without structured error information. When INI keys are missing or unparseable, `strictIni` calls `error` (see [CLI.md](./CLI.md#strictini--inionoff--error-semantics)). No line numbers or parse context are preserved.

## restore_messages — implicit default propagation

The `restore_messages` INI setting has three-valued logic: explicit "on" → restore, explicit "off" → skip, missing → inherits from `enable_store_log`. This implicit default is not captured in the type system — callers see `Maybe Bool` that silently resolves against another setting.

## serverPublicInfo — validation with field dependencies

`sourceCode` is required if ANY `ServerPublicInfo` field is present (in line with AGPLv3 license). `operator_country` requires `operator` to be set. `hosting_country` requires `hosting`. These constraints are enforced at parse time, not by the type system — they can be violated by programmatic construction.

## initializeServer — fingerprint invariant

During init, the CA certificate fingerprint is saved to a file. On every subsequent start, `checkSavedFingerprint` (in CLI.hs) validates that the current CA certificate matches the saved fingerprint. If the certificate is replaced without updating the fingerprint file, startup fails. This prevents silent key rotation.

## Database import — non-atomic migration

`importStoreLogToDatabase` reads the store log into memory, writes to database, then renames the original file with `.bak` suffix. If the function fails after partial database writes, the original file is still present but the database has partial data. No transactional guarantee across the file→DB boundary.

## Journal store deprecation warning

`SSCMemoryJournal` initialization prints a deprecation warning (see `newEnv` in Env/STM.hs). Journal message stores will be removed — migration path is: journal export → database import.
