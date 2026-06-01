# Simplex.Messaging.Version

> Version negotiation with proof-carrying compatibility checks.

**Source**: [`Version.hs`](../../../../src/Simplex/Messaging/Version.hs)

## Overview

The module's central design: `Compatible` and `VRange` constructors are not exported. The only way to obtain a `Compatible` value is through the negotiation functions, and the only way to construct a `VersionRange` is through `mkVersionRange` (which validates) or parsing. This makes "compatibility was checked" a compile-time guarantee — code that holds a `Compatible a` has proof that negotiation succeeded.

See [Simplex.Messaging.Version.Internal](./Version/Internal.md) for why the `Version` constructor is separated.

## mkVersionRange

Uses `error` if `min > max`. Safe only for compile-time constants. Runtime construction must use `safeVersionRange`, which returns `Nothing` on invalid input.

## compatibleVersion vs compatibleVRange

`compatibleVersion` selects a single version: `min(max1, max2)` — the highest mutually-supported version. `compatibleVRange` returns the full intersection range: `(max(min1,min2), min(max1,max2))`. The intersection is used when both sides need to remember the agreed range for future version-gated behavior, not just the single negotiated version.

## compatibleVRange'

Different from `compatibleVRange`: caps the range's *maximum* at a given version, rather than intersecting two ranges. Returns `Nothing` if the cap is below the range's minimum. Used when a peer reports a specific version and you need to constrain your range accordingly.

## VersionI / VersionRangeI typeclasses

Allow extension types that wrap `Version` or `VersionRange` (e.g., types carrying additional handshake parameters alongside the version) to participate in negotiation without unwrapping. The associated types (`VersionT`, `VersionRangeT`) map between the version and range forms of the extension type.
