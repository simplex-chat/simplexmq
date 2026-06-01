# Simplex.Messaging.Version.Internal

> Exports the `Version` constructor for internal use.

**Source**: [`Version/Internal.hs`](../../../../../src/Simplex/Messaging/Version/Internal.hs)

This module exists solely to split the `Version` constructor export. `Version.hs` exports `Version` as an opaque type (no constructor); `Version/Internal.hs` exports the `Version` constructor for modules that need to fabricate version values (protocol constants, parsers, tests). Application code should not import this module.
