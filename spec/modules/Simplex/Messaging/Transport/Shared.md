# Simplex.Messaging.Transport.Shared

> Certificate chain parsing and X.509 validation utilities shared between client and server.

**Source**: [`Transport/Shared.hs`](../../../../../src/Simplex/Messaging/Transport/Shared.hs)

**Protocol spec**: [`protocol/simplex-messaging.md` — Router certificate](../../../../protocol/simplex-messaging.md#router-certificate) — certificate chain lengths and semantics.

## chainIdCaCerts — certificate chain semantics

`chainIdCaCerts` classifies TLS certificate chains (which are ordered leaf-first) by length:

| Length | Constructor | Code comment |
|--------|------------|--------------|
| 0 | `CCEmpty` | (no chain) |
| 1 | `CCSelf cert` | (self-signed) |
| 2 | `CCValid {leafCert, idCert=cert, caCert=cert}` | "current long-term online/offline certificates chain" |
| 3 | `CCValid {leafCert, idCert, caCert}` | "with additional operator certificate (preset in the client)" |
| 4 | `CCValid {leafCert, idCert, _, caCert}` | "with network certificate" |
| 5+ | `CCLong` | (rejected) |

The protocol spec defines supported chain lengths of 2, 3, and 4 certificates (see [Router certificate](../../../../protocol/simplex-messaging.md#router-certificate)). In all `CCValid` cases, `idCert` is the certificate whose fingerprint is compared against the server address key hash, and `caCert` is used as the X.509 trust anchor.

In the 4-cert case, index 2 is skipped (`_`) — it is present in the chain but not used as either the identity or the trust anchor.

## x509validate — FQHN check disabled

`x509validate` sets `checkFQHN = False`. The protocol spec identifies servers by certificate fingerprint (key hash in the server address), not by domain name. The validation uses a fresh `ValidationCache` (`ValidationCacheUnknown` for all lookups, no-op store) — each connection validates independently.
