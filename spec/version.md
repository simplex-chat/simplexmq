# Version Negotiation

> Version ranges and compatibility checking for protocol evolution.

**Source files**: [`Version.hs`](../src/Simplex/Messaging/Version.hs), [`Version/Internal.hs`](../src/Simplex/Messaging/Version/Internal.hs)

## Overview

All SimpleX protocols use version negotiation during handshake. Each party advertises a `VersionRange` (min..max supported), and negotiation produces a `Compatible` proof value if the ranges overlap — choosing the highest mutually-supported version.

The `Compatible` newtype can only be constructed internally (constructor is not exported), so the type system enforces that compatibility was actually checked.

## Types

### `Version v`

```haskell
newtype Version v = Version Word16
```

Phantom-typed version number. The phantom `v` distinguishes version spaces (e.g., SMP versions vs Agent versions vs XFTP versions) at the type level, preventing accidental comparison across protocols.

- `Encoding`: 2 bytes big-endian (via Word16 instance)
- `StrEncoding`: decimal string
- JSON: numeric value
- Derives: `Eq`, `Ord`, `Show`

The constructor is exported from `Version.Internal` but not from `Version`, so application code cannot fabricate versions — they must come from protocol constants or parsing.

### `VersionRange v`

```haskell
data VersionRange v = VRange
  { minVersion :: Version v
  , maxVersion :: Version v
  }
```

Invariant: `minVersion <= maxVersion` (enforced by smart constructors).

The `VRange` constructor is not exported — only the pattern synonym `VersionRange` (read-only) is public.

- `Encoding`: two Word16s concatenated (4 bytes total)
- `StrEncoding`: `"min-max"` or `"v"` if min == max
- JSON: `{"minVersion": n, "maxVersion": n}`

### `VersionScope v`

```haskell
class VersionScope v
```

Empty typeclass used as a constraint on version operations. Each protocol declares its version scope:

```haskell
instance VersionScope SMP
instance VersionScope Agent
```

This prevents accidentally mixing version ranges from different protocols in negotiation functions.

### `Compatible a`

```haskell
newtype Compatible a = Compatible_ a

pattern Compatible :: a -> Compatible a
pattern Compatible a <- Compatible_ a
```

Proof that compatibility was checked. The `Compatible_` constructor is not exported — `Compatible` is a read-only pattern synonym. The only way to obtain a `Compatible` value is through `compatibleVersion`, `compatibleVRange`, `proveCompatible`, or the internal `mkCompatibleIf`.

### `VersionI` / `VersionRangeI` type classes

Multi-param typeclasses with functional dependencies for generic version/range operations. Allow extension types that wrap `Version` or `VersionRange` to participate in negotiation:

```haskell
class VersionScope v => VersionI v a | a -> v where
  type VersionRangeT v a          -- associated type: range form
  version :: a -> Version v
  toVersionRangeT :: a -> VersionRange v -> VersionRangeT v a

class VersionScope v => VersionRangeI v a | a -> v where
  type VersionT v a               -- associated type: version form
  versionRange :: a -> VersionRange v
  toVersionRange :: a -> VersionRange v -> a
  toVersionT :: a -> Version v -> VersionT v a
```

Identity instances exist for `Version v` and `VersionRange v` themselves.

## Functions

### Construction

| Function | Signature | Purpose |
|----------|-----------|---------|
| `mkVersionRange` | `Version v -> Version v -> VersionRange v` | Construct range, `error` if min > max |
| `safeVersionRange` | `Version v -> Version v -> Maybe (VersionRange v)` | Safe construction, `Nothing` if invalid |
| `versionToRange` | `Version v -> VersionRange v` | Singleton range (min == max) |

### Compatibility checking

### isCompatible

**Purpose**: Check if a single version falls within a range.

```haskell
isCompatible :: VersionI v a => a -> VersionRange v -> Bool
```

### isCompatibleRange

**Purpose**: Check if two version ranges overlap: `min1 <= max2 && min2 <= max1`.

```haskell
isCompatibleRange :: VersionRangeI v a => a -> VersionRange v -> Bool
```

### proveCompatible

**Purpose**: If version is compatible, wrap in `Compatible` proof. Returns `Nothing` if out of range.

```haskell
proveCompatible :: VersionI v a => a -> VersionRange v -> Maybe (Compatible a)
```

### Negotiation

### compatibleVersion

**Purpose**: Negotiate a single version from two ranges. Returns `min(max1, max2)` — the highest mutually-supported version. Returns `Nothing` if ranges don't overlap.

```haskell
compatibleVersion :: VersionRangeI v a => a -> VersionRange v -> Maybe (Compatible (VersionT v a))
```

### compatibleVRange

**Purpose**: Compute the intersection of two version ranges: `(max(min1,min2), min(max1,max2))`. Returns `Nothing` if the intersection is empty.

```haskell
compatibleVRange :: VersionRangeI v a => a -> VersionRange v -> Maybe (Compatible a)
```

### compatibleVRange'

**Purpose**: Cap a version range's maximum at a given version. Returns `Nothing` if the cap is below the range's minimum.

```haskell
compatibleVRange' :: VersionRangeI v a => a -> Version v -> Maybe (Compatible a)
```

## Protocol version constants

Version constants for each protocol are defined in their respective Transport modules. For SMP, key gates include:

- `currentSMPAgentVersion`, `supportedSMPAgentVRange` — current negotiation range
- `serviceCertsSMPVersion = 16` — service certificate handshake
- `rcvServiceSMPVersion = 19` — service subscription commands

See [`transport.md`](transport.md) and [`rcv-services.md`](rcv-services.md) for protocol-specific version constants.

## Negotiation protocol

During handshake:
1. Client sends its `VersionRange` to server
2. Server computes `compatibleVRange clientRange serverRange`
3. If `Nothing` → reject connection (incompatible)
4. If `Just (Compatible agreedRange)` → use `maxVersion agreedRange` as the effective protocol version

The `Compatible` proof flows through the connection setup, ensuring all subsequent version-gated code paths have evidence that negotiation occurred.

## Security notes

- **No downgrade attack protection in negotiation itself** — an active MITM could modify the version range to force a lower version. Protection comes from the TLS layer (authentication prevents MITM) and from servers setting minimum version floors.
- **`mkVersionRange` uses `error`** — only safe for compile-time constants. Runtime construction must use `safeVersionRange`.
