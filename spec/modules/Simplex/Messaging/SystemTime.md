# Simplex.Messaging.SystemTime

> Type-level precision timestamps for date bucketing and expiration.

**Source**: [`SystemTime.hs`](../../../../src/Simplex/Messaging/SystemTime.hs)

## getRoundedSystemTime

Rounds **down** (truncation): `(seconds / precision) * precision`. A timestamp at 23:59:59 with `SystemDate` (precision 86400) rounds to the start of the current day, not the nearest day.

## roundedToUTCTime

Sets nanoseconds to 0. Any `RoundedSystemTime` converted to `UTCTime` and back to `SystemTime` will differ from the original `getSystemTime` value.
