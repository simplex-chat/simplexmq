# Simplex.Messaging.Server.CLI

> CLI argument parsing, INI configuration reading, X.509 certificate generation, and utility functions.

**Source**: [`CLI.hs`](../../../../../src/Simplex/Messaging/Server/CLI.hs)

## strictIni / iniOnOff — error semantics

`strictIni` calls `error` on missing INI keys — no structured error, no recovery. `readStrictIni` chains this with `read`, so both "key missing" and "key present but unparseable" produce exceptions indistinguishable by callers.

`iniOnOff` returns `Maybe Bool`: "on" → `Just True`, "off" → `Just False`, missing key → `Nothing`, any other value → `error` (not a parse failure). This tri-valued logic drives the implicit-default pattern in [Main.md](./Main.md#restore_messages--implicit-default-propagation).

## iniTransports — port reuse prevention

SMP ports are parsed first. When explicit WebSocket ports are provided, they are filtered to exclude already-used SMP ports (`ports ws \\ smpPorts`). However, when "websockets" is "on" with no explicit port, it defaults to `["80"]` without filtering against SMP ports. This means if SMP is also on port 80, the default WebSocket configuration would conflict.

## iniDBOptions — schema creation disabled at CLI

When reading database options from INI, `createSchema` is always set to `False` regardless of INI content. This enforces a security invariant: database schemas must be created manually or by migration, never automatically by the server.

## createServerX509_ — external tool dependency

Certificate generation shells out to `openssl` commands via `readCreateProcess`, which throws `IOError` on non-zero exit codes. Failures are thus detected but propagate as uncaught exceptions — no structured error handling wraps the certificate generation sequence.

## checkSavedFingerprint — startup invariant

Fingerprint is extracted from the CA certificate and saved during init. On every server start, the saved fingerprint is compared against the current certificate. Mismatch → startup failure. See [Main.md#initializeserver--fingerprint-invariant](./Main.md#initializeserver--fingerprint-invariant).

## genOnline — existing certificate dependency

When `signAlgorithm_` or `commonName_` are not provided, `genOnline` reads them from the existing certificate. This creates a hidden dependency on current certificate state that's not visible from the function signature. Expects exactly one certificate in the PEM file.
