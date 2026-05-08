# Simplex.Messaging.Transport.Credentials

> Certificate generation for transport layer: Ed25519 key pairs, X.509 signing, TLS credential extraction.

**Source**: [`Transport/Credentials.hs`](../../../../../src/Simplex/Messaging/Transport/Credentials.hs)

## genCredentials — nanosecond stripping

`genCredentials` zeroes out nanoseconds from the current time before creating the certificate validity period: `todNSec = 0`. The source comment explains: "remove nanoseconds from time - certificate encoding/decoding removes them."

## tlsCredentials — root fingerprint from last credential

`tlsCredentials` extracts the SHA-256 fingerprint from `L.last credentials` (the root/CA certificate), and the private key from `L.head credentials` (the leaf). The returned `KeyHash` wraps this root fingerprint.
