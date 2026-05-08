# Simplex.RemoteControl.Types

> Type definitions for the XRCP remote control protocol: pairing records, session state, hello messages, and error taxonomy.

**Source**: [`RemoteControl/Types.hs`](../../../../../../src/Simplex/RemoteControl/Types.hs)

## Overview

This module defines the data types for the XRCP (remote control) protocol, which connects a "host" (mobile device) to a "controller" (desktop). Key architectural point: the naming is from the **controller's perspective** — the controller connects to the host, so:
- `RCHostPairing` / `RCHostSession` are the controller-side records (connecting **to** the host)
- `RCCtrlPairing` / `RCCtrlSession` are the host-side records (connecting **from** the controller)

## Asymmetric pairing records

`RCHostPairing` (controller side) stores the CA key pair (private key + certificate), identity private key, and optionally a `KnownHostPairing` (fingerprint + last DH public key of the host). `RCCtrlPairing` (host side) stores the CA key pair, controller's fingerprint and identity public key, current DH private key, and `prevDhPrivKey` — the previous DH key retained so that announcements encrypted with the old key can still be decrypted during key rotation.

## Asymmetric session keys

`HostSessKeys` stores private keys (identity + session) — the controller needs to sign commands. `CtrlSessKeys` stores public keys (identity + session) — the host needs to verify commands. Both store `TSbChainKeys` for the symmetric session encryption, but note that the chain key direction is swapped between the two sides (see `prepareCtrlSession` in [Client.md](./Client.md)).

## RCCtrlEncHello — two variants

`RCCtrlEncHello` is a sum type with two variants: `RCCtrlEncHello` (success: KEM ciphertext + encrypted hello body) and `RCCtrlEncError` (failure: nonce + encrypted error message). The error variant uses the original DH shared key for encryption (not the KEM hybrid key), since the error occurs before KEM exchange completes.

## AnyError instance — TLS UnknownCa promotion

`fromSomeException` promotes TLS `Terminated` / `Error_Protocol` / `UnknownCa` to `RCEIdentity` rather than the generic `RCEException`. This maps a TLS-level certificate rejection (either side's CA not recognized by the peer) to a meaningful XRCP error.

## IpProbe — unused discovery type

`IpProbe` is defined with `Encoding` instance but not used anywhere in the current codebase. It appears to be a placeholder for a planned IP discovery mechanism.
